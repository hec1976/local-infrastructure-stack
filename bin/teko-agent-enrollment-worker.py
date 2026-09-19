#!/usr/bin/env python3
"""
TEKO Agent Enrollment Worker
Root-only worker. Consumes validated JSON jobs created by the Config Manager GUI.

Security properties:
- SSH key or short-lived password authentication
- passwords never enter job JSON/status/audit and are consumed via sshpass file descriptor
- no arbitrary command/SSH option from jobs
- SSH host key fingerprint is mandatory for key auth; password auth may use explicit TOFU pinning
- fixed bootstrap payload and fixed remote command structure
- per-agent API token and CA installed on manager
- fleet registry update protected by flock + atomic replace
"""
import base64, fcntl, grp, hashlib, ipaddress, json, os, re, shlex, shutil, ssl
import stat, subprocess, sys, tempfile, time, urllib.request, hashlib
from pathlib import Path

CFG=Path("/opt/service/config-manager/enrollment.json")
SAFE_NAME=re.compile(r"^[A-Za-z0-9._-]{1,128}$")
SAFE_USER=re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
SAFE_GROUP=re.compile(r"^[A-Za-z0-9._-]{1,64}$")
SAFE_LABEL_KEY=SAFE_GROUP
SAFE_LABEL_VALUE=re.compile(r"^[A-Za-z0-9._:@/-]{1,128}$")
SAFE_FQDN=re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
FP_RE=re.compile(r"^SHA256:[A-Za-z0-9+/]{43}=?$")



ANSI_RE=re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
ERROR_WORD_RE=re.compile(r"(?:error|fehler|failed|failure|fatal|not found|no such file|permission denied|denied|cannot|can't|unable|missing|invalid|syntax|traceback|command not found|nicht gefunden|fehlgeschlagen|konnte nicht|kann nicht|verweigert)", re.I)
NOISE_INFO_RE=re.compile(r"(?:vorhandene .* gesichert:|backup(?:[- ]datei)? .* (?:gesichert|erstellt)|sicherung .* erstellt)", re.I)
PUNCT_ONLY_RE=re.compile(r"^[\s.+'#=:_\-|/\\<>*]+$")

def _clean_output_lines(text):
    text=ANSI_RE.sub('', str(text or '')).replace('\r','\n')
    out=[]
    for raw in text.splitlines():
        line=raw.replace('\b','').strip()
        if not line:
            continue
        if line in {'STDOUT:','STDERR:'}:
            continue
        if re.match(r'^Kommando fehlgeschlagen \(rc=\d+\):', line):
            continue
        if re.match(r'^command failed rc=', line, re.I):
            continue
        if NOISE_INFO_RE.search(line):
            continue
        if len(line) >= 8 and PUNCT_ONLY_RE.fullmatch(line):
            continue
        # Fortschrittsausgaben bestehen oft fast nur aus Satz-/Balkenzeichen.
        alnum=sum(1 for c in line if c.isalnum())
        if len(line) >= 20 and alnum/max(1,len(line)) < 0.12:
            continue
        out.append(line)
    return out

def summarize_error(error):
    lines=_clean_output_lines(error)
    if not lines:
        return 'Enrollment fehlgeschlagen. Technische Details anzeigen.'
    flagged=[line for line in lines if ERROR_WORD_RE.search(line)]
    # Die letzte konkrete Fehlermeldung ist bei Installationsskripten meist die Ursache;
    # reine Vorbereitungs-/Backupmeldungen stehen davor.
    chosen=(flagged[-1] if flagged else lines[-1]).strip()
    if len(chosen)>420:
        chosen=chosen[:417]+'...'
    return chosen

STAGE_DEFS=[
    ("queued","Job angenommen",0),
    ("hostkey","SSH Host-Key",10),
    ("ssh_auth","SSH Anmeldung",20),
    ("remote_prepare","Ziel vorbereiten",32),
    ("bundle_transfer","Bundle uebertragen",45),
    ("agent_install","Agent installieren",62),
    ("registration_fetch","Registrierung abrufen",75),
    ("registration_import","Registrierung importieren",87),
    ("health_check","Health-Check",95),
]
STAGE_POS={name:i for i,(name,_,_) in enumerate(STAGE_DEFS)}

def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())

def write_status(status,cfg):
    sp=status_path(cfg,status["id"])
    atomic_json(sp,status)
    chown_web(sp,cfg)

def make_steps():
    return [{"id":name,"label":label,"state":"pending","at":""} for name,label,_ in STAGE_DEFS]

def set_progress(status,cfg,stage,message,*,level="info"):
    if stage not in STAGE_POS:
        raise ValueError(f"unknown enrollment stage: {stage}")
    idx=STAGE_POS[stage]
    now=utc_now()
    steps=status.setdefault("steps",make_steps())
    for pos,step in enumerate(steps):
        if pos < idx and step.get("state") not in {"failed"}:
            step["state"]="completed"
            if not step.get("at"): step["at"]=now
        elif pos == idx:
            step["state"]="running"
            if not step.get("at"): step["at"]=now
        elif step.get("state") not in {"failed","completed"}:
            step["state"]="pending"
    status["state"]="running"
    status["stage"]=stage
    status["stage_message"]=message
    status["progress_percent"]=STAGE_DEFS[idx][2]
    events=status.setdefault("events",[])
    event={"at":now,"stage":stage,"level":level,"message":message}
    if not events or events[-1].get("stage")!=stage or events[-1].get("message")!=message:
        events.append(event)
        del events[:-40]
    write_status(status,cfg)

def fail_progress(status,cfg,error):
    now=utc_now()
    current=str(status.get("stage") or "queued")
    idx=STAGE_POS.get(current,0)
    steps=status.setdefault("steps",make_steps())
    if 0 <= idx < len(steps):
        steps[idx]["state"]="failed"
        steps[idx]["at"]=steps[idx].get("at") or now
    raw_error=str(error)[-12000:]
    summary=summarize_error(raw_error)
    status.update({
        "state":"failed",
        "completed_at":now,
        "stage_message":"Enrollment fehlgeschlagen.",
        "error_summary":summary,
        "error":raw_error,
    })
    events=status.setdefault("events",[])
    events.append({"at":now,"stage":current,"level":"error","message":summary})
    del events[:-40]
    write_status(status,cfg)

def complete_progress(status,cfg,registered_url):
    now=utc_now()
    steps=status.setdefault("steps",make_steps())
    for step in steps:
        step["state"]="completed"
        if not step.get("at"): step["at"]=now
    status.update({
        "state":"completed",
        "stage":"completed",
        "stage_message":"Agent erfolgreich installiert, registriert und geprueft.",
        "progress_percent":100,
        "completed_at":now,
        "registered_url":registered_url,
        "error":"",
    })
    events=status.setdefault("events",[])
    events.append({"at":now,"stage":"completed","level":"success","message":"Enrollment erfolgreich abgeschlossen."})
    del events[:-40]
    write_status(status,cfg)

def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))

def atomic_json(path: Path, data, mode=0o640):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=path.name+".tmp.",dir=str(path.parent))
    try:
        with os.fdopen(fd,"w",encoding="utf-8") as f:
            json.dump(data,f,indent=2,ensure_ascii=False); f.write("\n")
            f.flush(); os.fsync(f.fileno())
        os.chmod(tmp,mode)
        os.replace(tmp,path)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass

def chown_web(path: Path, cfg):
    gid=grp.getgrnam(str(cfg["web_group"])).gr_gid
    os.chown(path,0,gid)

def valid_ip(value: str) -> str:
    return str(ipaddress.ip_address(value))

def valid_host(value: str) -> str:
    value=value.strip()
    try: return valid_ip(value)
    except ValueError: pass
    if not SAFE_FQDN.fullmatch(value): raise ValueError("invalid ssh_host")
    return value

def validate_job(j):
    required=["id","ssh_host","ssh_port","ssh_user",
              "bind_ip","fqdn","groups","labels","manager_ip"]
    for k in required:
        if k not in j: raise ValueError(f"missing {k}")
    if not SAFE_NAME.fullmatch(str(j["id"])): raise ValueError("invalid id")
    j["ssh_host"]=valid_host(str(j["ssh_host"]))
    j["ssh_port"]=int(j["ssh_port"])
    if not 1 <= j["ssh_port"] <= 65535: raise ValueError("invalid ssh_port")
    if not SAFE_USER.fullmatch(str(j["ssh_user"])): raise ValueError("invalid ssh_user")
    j["auth_mode"]=str(j.get("auth_mode","key")).lower()
    if j["auth_mode"] not in {"key","password"}: raise ValueError("invalid auth_mode")
    fp=str(j.get("expected_host_key_sha256","")).strip()
    if j["auth_mode"]=="key" and not FP_RE.fullmatch(fp):
        raise ValueError("fingerprint required for key auth")
    if j["auth_mode"]=="password" and fp and not FP_RE.fullmatch(fp):
        raise ValueError("invalid optional fingerprint")
    j["expected_host_key_sha256"]=fp
    j["bind_ip"]=valid_ip(str(j["bind_ip"]))
    j["manager_ip"]=valid_ip(str(j["manager_ip"]))
    if not SAFE_FQDN.fullmatch(str(j["fqdn"])): raise ValueError("invalid fqdn")
    j["groups"]=list(dict.fromkeys(str(x) for x in j.get("groups",[])))
    if not j["groups"] or any(not SAFE_GROUP.fullmatch(x) for x in j["groups"]): raise ValueError("invalid groups")
    labels={}
    for k,v in dict(j.get("labels",{})).items():
        k=str(k); v=str(v)
        if not SAFE_LABEL_KEY.fullmatch(k) or not SAFE_LABEL_VALUE.fullmatch(v): raise ValueError("invalid labels")
        labels[k]=v
    j["labels"]=labels
    j["use_sudo"]=bool(j.get("use_sudo",False))
    if j["ssh_user"]=="root": j["use_sudo"]=False
    return j

def run(args, *, input_bytes=None, timeout=1800, check=True, pass_fds=()):
    p=subprocess.run(
        args,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        pass_fds=tuple(pass_fds)
    )
    if check and p.returncode:
        stdout=p.stdout.decode("utf-8","replace")[-3500:].strip()
        stderr=p.stderr.decode("utf-8","replace")[-3500:].strip()
        details=[]
        if stdout: details.append("STDOUT:\n"+stdout)
        if stderr: details.append("STDERR:\n"+stderr)
        detail="\n\n".join(details) or "Keine Ausgabe vom fehlgeschlagenen Kommando."
        raise RuntimeError(
            f"Kommando fehlgeschlagen (rc={p.returncode}): {' '.join(map(shlex.quote,args))}\n"
            +detail
        )
    return p

def scan_and_verify_hostkey(job,cfg):
    scan=run(["ssh-keyscan","-p",str(job["ssh_port"]),"-T","8",job["ssh_host"]],timeout=20)
    lines=[x for x in scan.stdout.decode().splitlines() if x and not x.startswith("#")]
    if not lines: raise RuntimeError("ssh-keyscan returned no host key")
    expected=str(job.get("expected_host_key_sha256","")).strip()
    matched=[]
    observed=[]
    for line in lines:
        parts=line.split()
        if len(parts)<3: continue
        key_blob=base64.b64decode(parts[2].encode(),validate=True)
        fp="SHA256:"+base64.b64encode(hashlib.sha256(key_blob).digest()).decode().rstrip("=")
        observed.append(fp)
        if not expected or fp==expected:
            matched.append(line)
    if expected and not matched:
        raise RuntimeError("SSH host key fingerprint mismatch")
    if not expected:
        if job.get("auth_mode") != "password":
            raise RuntimeError("SSH host key fingerprint required")
        # Explicit demo/bootstrap TOFU: pin the keys discovered before the password is sent.
        # StrictHostKeyChecking remains enabled for all subsequent SSH/SCP connections.
        matched=lines
    kh=Path(cfg["known_hosts"])
    kh.parent.mkdir(parents=True,exist_ok=True)
    with kh.open("a+",encoding="utf-8") as f:
        fcntl.flock(f,fcntl.LOCK_EX)
        f.seek(0); existing=f.read()
        for line in matched:
            if line not in existing: f.write(line+"\n")
        f.flush(); os.fsync(f.fileno())
    os.chmod(kh,0o600)
    return list(dict.fromkeys(observed))

def ssh_base(job,cfg):
    common=[
        "-o","StrictHostKeyChecking=yes","-o",f"UserKnownHostsFile={cfg['known_hosts']}",
        "-o","ConnectTimeout=10"
    ]
    if job.get("auth_mode","key")=="password":
        return [
            "ssh","-p",str(job["ssh_port"]),
            "-o","BatchMode=no","-o","PubkeyAuthentication=no",
            "-o","PasswordAuthentication=yes","-o","KbdInteractiveAuthentication=no",
            *common,f"{job['ssh_user']}@{job['ssh_host']}"
        ]
    return [
        "ssh","-i",cfg["ssh_key"],"-p",str(job["ssh_port"]),
        "-o","BatchMode=yes","-o","PasswordAuthentication=no",
        "-o","KbdInteractiveAuthentication=no","-o","IdentitiesOnly=yes",
        *common,f"{job['ssh_user']}@{job['ssh_host']}"
    ]

def scp_base(job,cfg):
    common=[
        "-o","StrictHostKeyChecking=yes","-o",f"UserKnownHostsFile={cfg['known_hosts']}",
        "-o","ConnectTimeout=10"
    ]
    if job.get("auth_mode","key")=="password":
        return [
            "scp","-P",str(job["ssh_port"]),
            "-o","BatchMode=no","-o","PubkeyAuthentication=no",
            "-o","PasswordAuthentication=yes","-o","KbdInteractiveAuthentication=no",
            *common
        ]
    return [
        "scp","-i",cfg["ssh_key"],"-P",str(job["ssh_port"]),
        "-o","BatchMode=yes","-o","PasswordAuthentication=no",
        "-o","KbdInteractiveAuthentication=no","-o","IdentitiesOnly=yes",
        *common
    ]

def secret_path(job,cfg):
    return Path(cfg["secret_dir"])/(str(job["id"])+".secret")

def delete_secret(cfg,jobid):
    if not SAFE_NAME.fullmatch(str(jobid)): return
    try: (Path(cfg["secret_dir"])/(str(jobid)+".secret")).unlink()
    except FileNotFoundError: pass

def run_remote(job,cfg,args,*,timeout=1800,check=True):
    if job.get("auth_mode","key")!="password":
        return run(args,timeout=timeout,check=check)
    if not shutil.which("sshpass"):
        raise RuntimeError("sshpass ist fuer Passwort-Enrollment nicht installiert")
    sp=secret_path(job,cfg)
    flags=os.O_RDONLY | getattr(os,"O_NOFOLLOW",0) | getattr(os,"O_CLOEXEC",0)
    try:
        fd=os.open(sp,flags)
    except FileNotFoundError:
        raise RuntimeError("Enrollment-Passwort fehlt oder wurde bereits verworfen")
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size < 1 or st.st_size > 1024:
            raise RuntimeError("Enrollment-Passwortdatei ist ungueltig")
        return run(["sshpass","-d",str(fd),*args],timeout=timeout,check=check,pass_fds=(fd,))
    finally:
        os.close(fd)

def remote_bootstrap(job,cfg,progress):
    remote=f"/tmp/teko-agent-enroll-{job['id']}"
    ssh=ssh_base(job,cfg)
    scp=scp_base(job,cfg)
    progress("remote_prepare","Remote-Arbeitsverzeichnis wird vorbereitet.")
    run_remote(job,cfg,ssh+["mkdir -m 700 "+shlex.quote(remote)])
    progress("bundle_transfer","Bootstrap-Bundle wird auf das Zielsystem uebertragen.")
    run_remote(job,cfg,scp+[cfg["bundle"],f"{job['ssh_user']}@{job['ssh_host']}:{remote}/bundle.tar.gz"])
    # Forgejo-Service-Token separat ueber den bereits gepinnten SSH-Kanal
    # uebertragen. Niemals in das web-lesbare Bootstrap-Bundle einbetten.
    forgejo_token=Path(str(cfg.get("forgejo_token_file") or "/opt/service/env/forgejo-api.token"))
    if not forgejo_token.is_file():
        raise RuntimeError(f"Forgejo Service-Token fehlt: {forgejo_token}")
    run_remote(job,cfg,scp+[str(forgejo_token),f"{job['ssh_user']}@{job['ssh_host']}:{remote}/forgejo-api.token"])
    prefix="sudo -n " if job["use_sudo"] else ""
    if not job["use_sudo"] and job["ssh_user"]!="root":
        raise RuntimeError("non-root enrollment requires sudo -n")
    env={
        "CONFIG_MANAGER_IP":job["manager_ip"],
        "CONFIG_AGENT_BIND_IP":job["bind_ip"],
        "CONFIG_AGENT_FQDN":job["fqdn"],
        "CONFIG_AGENT_PORT":str(cfg.get("agent_port",5008)),
        "CONFIG_AGENT_HOST_ID":str(job.get("host_id") or ("host-"+hashlib.sha256(job["fqdn"].lower().encode()).hexdigest()[:16])),
        "CONFIG_AGENT_LABELS_JSON":json.dumps(job.get("labels") or {},separators=(",",":")),
        "CONFIG_AGENT_GROUPS_JSON":json.dumps(job.get("groups") or [],separators=(",",":")),
        "FORGEJO_FQDN":str(cfg.get("forgejo_fqdn","git.local")),
        "CONFIG_MANAGER_FQDN":str(cfg.get("config_manager_fqdn","config-manager.local")),
        "GRAFANA_FQDN":str(cfg.get("grafana_fqdn","grafana.local")),
        "CONFIG_AGENT_FORGEJO_TOKEN_FILE":remote+"/forgejo-api.token",
        "CONFIG_AGENT_REMOTE_PROFILE_RESET":"1",
    }
    exports=" ".join(f"{k}={shlex.quote(v)}" for k,v in env.items())
    cmd=(
        f"set -e; cd {shlex.quote(remote)}; "
        f"tar -xzf bundle.tar.gz; "
        f"{prefix}env {exports} bash teko-agent-bundle/setup_remote_config_agent.sh; "
        f"{prefix}tar -C /root/teko-agent-registration -czf {shlex.quote(remote+'/registration.tgz')} "
        "agent-ca.crt api-token server-registry-entry.json; "
    )
    if job["use_sudo"]:
        cmd += f"{prefix}chown {shlex.quote(job['ssh_user'])} {shlex.quote(remote+'/registration.tgz')}; "
    progress("agent_install","Config-Agent wird auf dem Zielsystem installiert und gestartet.")
    run_remote(job,cfg,ssh+[cmd],timeout=2400)
    local=Path(cfg["state_dir"])/("registration-"+job["id"]+".tgz")
    progress("registration_fetch","Registrierungsdaten werden vom Zielsystem abgerufen.")
    run_remote(job,cfg,scp+[f"{job['ssh_user']}@{job['ssh_host']}:{remote}/registration.tgz",str(local)])
    run_remote(job,cfg,ssh+[f"rm -rf {shlex.quote(remote)}"],check=False,timeout=30)
    return local
def install_registration(job,cfg,tgz:Path,progress):
    tmp=Path(tempfile.mkdtemp(prefix="teko-enroll-reg."))
    try:
        progress("registration_import","Zertifikat, API-Token und Server-Registry werden auf dem Manager importiert.")
        run(["tar","-xzf",str(tgz),"-C",str(tmp)])
        cert=tmp/"agent-ca.crt"; token=tmp/"api-token"
        if not cert.is_file() or not token.is_file(): raise RuntimeError("registration bundle incomplete")
        token_value=token.read_text().strip()
        if len(token_value)<32 or re.search(r"\s",token_value): raise RuntimeError("invalid API token")

        safe=job["fqdn"]
        ca_dir=Path(cfg["ca_dir"]); tok_dir=Path(cfg["token_dir"])
        ca_dir.mkdir(parents=True,exist_ok=True); tok_dir.mkdir(parents=True,exist_ok=True)
        ca_path=ca_dir/(safe+".crt"); tok_path=tok_dir/(safe+".token")
        shutil.copyfile(cert,ca_path); shutil.copyfile(token,tok_path)
        os.chmod(ca_path,0o640); os.chmod(tok_path,0o640)
        chown_web(ca_path,cfg); chown_web(tok_path,cfg)

        registry=Path(cfg["registry"])
        lock=registry.with_suffix(registry.suffix+".lock")
        lock.parent.mkdir(parents=True,exist_ok=True)
        with lock.open("a+") as lf:
            fcntl.flock(lf,fcntl.LOCK_EX)
            data=load_json(registry) if registry.exists() else {"schema_version":1,"servers":[]}
            servers=list(data.get("servers",[]))
            entry={
                "name":job["fqdn"],
                "host_id":str(job.get("host_id") or ("host-"+hashlib.sha256(job["fqdn"].lower().encode()).hexdigest()[:16])),
                "url":f"https://{job['bind_ip']}:{int(cfg.get('agent_port',5008))}",
                "groups":job["groups"],
                "labels":job["labels"],
                "token_file":str(tok_path),
                "tls":{"verify":True,"verify_host":True,"ca_file":str(ca_path)},
            }
            servers=[x for x in servers if str(x.get("name","")).lower()!=job["fqdn"].lower()]
            servers.append(entry)
            data={"schema_version":1,"servers":servers}
            atomic_json(registry,data,0o640)
            chown_web(registry,cfg)
            obs_sync=Path('/usr/local/libexec/teko-observability-auth-sync.py')
            if obs_sync.is_file():
                cp=subprocess.run(['/usr/bin/python3',str(obs_sync)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True)
                if cp.returncode != 0:
                    raise RuntimeError('Observability Apache-Auth Sync fehlgeschlagen: '+(cp.stderr or cp.stdout).strip())

        # Final API/TLS check using the actual imported cert/token.
        progress("health_check","TLS- und API-Health-Check des neuen Agents wird ausgefuehrt.")
        ctx=ssl.create_default_context(cafile=str(ca_path))
        req=urllib.request.Request(entry["url"]+"/",headers={"X-API-Token":token_value})
        with urllib.request.urlopen(req,context=ctx,timeout=8) as r:
            if r.status < 200 or r.status >= 300: raise RuntimeError(f"agent health HTTP {r.status}")
        return entry
    finally:
        shutil.rmtree(tmp,ignore_errors=True)
        try: tgz.unlink()
        except FileNotFoundError: pass

def status_path(cfg,jobid):
    return Path(cfg["status_dir"])/(jobid+".json")

def _safe_unlink(path):
    try:
        Path(path).unlink()
    except FileNotFoundError:
        pass

def process_control_requests(cfg):
    control=Path(cfg.get("control_dir") or (Path(cfg["queue_dir"]).parent/"control"))
    control.mkdir(parents=True,exist_ok=True)
    for req in sorted(control.glob("delete-*.json")):
        try:
            data=load_json(req)
            jid=str(data.get("job_id") or "").strip()
            if not SAFE_NAME.fullmatch(jid):
                raise ValueError("invalid delete job id")
            sp=status_path(cfg,jid)
            if sp.exists():
                st=load_json(sp)
                if str(st.get("state") or "") == "running":
                    # Keep the request; a later timer run can delete it once finished.
                    continue
            _safe_unlink(Path(cfg["queue_dir"])/(jid+".json"))
            _safe_unlink(sp)
            _safe_unlink(Path(cfg.get("secret_dir", ""))/(jid+".secret"))
            state_dir=Path(cfg.get("state_dir") or "")
            if str(state_dir):
                _safe_unlink(state_dir/("registration-"+jid+".tgz"))
            _safe_unlink(req)
        except Exception as e:
            # Bad control requests are quarantined instead of killing the worker.
            bad=req.with_suffix(req.suffix+".failed")
            try:
                req.replace(bad)
                bad.with_suffix(bad.suffix+".error").write_text(str(e)+"\n",encoding="utf-8")
            except Exception:
                pass

def process(path:Path,cfg):
    raw=load_json(path)
    job=validate_job(raw)
    configured_manager_ip=valid_ip(str(cfg["manager_ip"]))
    if job["manager_ip"] != configured_manager_ip:
        raise ValueError("manager_ip does not match root-owned enrollment config")
    job["manager_ip"]=configured_manager_ip
    status={
        **job,
        "state":"running",
        "stage":"queued",
        "stage_message":"Enrollment-Worker hat den Job uebernommen.",
        "progress_percent":2,
        "started_at":utc_now(),
        "steps":make_steps(),
        "events":[],
    }
    status.pop("expected_host_key_sha256",None)
    progress=lambda stage,message: set_progress(status,cfg,stage,message)
    try:
        progress("hostkey","SSH Host-Key wird erfasst und geprueft.")
        observed_host_keys=scan_and_verify_hostkey(job,cfg)
        status["observed_host_key_sha256"]=observed_host_keys
        progress("ssh_auth","SSH-Anmeldung am Zielsystem wird geprueft.")
        run_remote(job,cfg,ssh_base(job,cfg)+["true"],timeout=30)
        reg=remote_bootstrap(job,cfg,progress)
        entry=install_registration(job,cfg,reg,progress)
        complete_progress(status,cfg,entry["url"])
    except Exception as e:
        fail_progress(status,cfg,e)
    finally:
        delete_secret(cfg,job["id"])
    try:
        path.unlink()
    except FileNotFoundError:
        pass

def main():
    if os.geteuid()!=0:
        raise SystemExit("worker must run as root")
    cfg=load_json(CFG)
    process_control_requests(cfg)
    q=Path(cfg["queue_dir"]); q.mkdir(parents=True,exist_ok=True)
    for path in sorted(q.glob("*.json")):
        try: process(path,cfg)
        except Exception as e:
            # Malformed files get quarantined as failed status.
            jid=path.stem if SAFE_NAME.fullmatch(path.stem) else "invalid-"+str(int(time.time()))
            sp=status_path(cfg,jid); atomic_json(sp,{"id":jid,"state":"failed","error":str(e),"completed_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}); chown_web(sp,cfg)
            delete_secret(cfg,jid)
            try:
                path.unlink()
            except FileNotFoundError:
                pass
    process_control_requests(cfg)

if __name__=="__main__":
    main()
