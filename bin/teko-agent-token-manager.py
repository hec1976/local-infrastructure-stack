#!/usr/bin/python3
import hashlib, json, os, re, ssl, stat, subprocess, sys, tempfile, urllib.parse, urllib.request, urllib.error, pwd, grp, socket, shlex

REGISTRY='/opt/service/config-manager/servers.json'
KNOWN_HOSTS='/opt/service/env/enrollment/known_hosts'
TOKEN_ROOT='/opt/service/config-manager/tokens/'
CA_ROOT='/opt/service/config-manager/ca/'
REPAIR_BUNDLE='/opt/service/config-manager/agent-repair-bundle.tar.gz'
OBS_AUTH_SYNC='/usr/local/libexec/teko-observability-auth-sync.py'
LEGACY_TOKEN_ROOTS=('/opt/service/env/agents/','/opt/service/config-manager/')
NAME_RE=re.compile(r'^[A-Za-z0-9._:-]{1,128}$')
HOST_RE=re.compile(r'^[A-Za-z0-9._:-]{1,253}$')
USER_RE=re.compile(r'^[A-Za-z0-9._-]{1,64}$')

def die(msg, code=2):
    print(json.dumps({'ok':False,'error':str(msg)}, ensure_ascii=False))
    raise SystemExit(code)

def load_request():
    raw=sys.stdin.read(65537)
    if len(raw)>65536: die('Request zu gross')
    try: j=json.loads(raw)
    except Exception as e: die('Ungueltiges JSON: %s' % e)
    if not isinstance(j,dict): die('Request muss ein JSON-Objekt sein')
    return j

def load_server(name):
    if not NAME_RE.match(name or ''): die('Ungueltiger Servername')
    try:
        with open(REGISTRY,encoding='utf-8') as f: reg=json.load(f)
    except Exception as e: die('Server-Registry nicht lesbar: %s' % e)
    for s in reg.get('servers',[]):
        if isinstance(s,dict) and str(s.get('name','')).lower()==name.lower(): return s
    die('Server nicht gefunden: %s' % name)

def safe_token_name(name):
    name=str(name or '').strip()
    if not NAME_RE.match(name): die('Ungueltiger Servername')
    return re.sub(r'[^A-Za-z0-9._-]', '_', name) + '.token'

def canonical_token_path(server):
    return os.path.join(TOKEN_ROOT, safe_token_name(server.get('name','')))

def token_path(server):
    # Es gibt genau einen kanonischen Manager-Speicherort. Alte Registry-Pfade
    # werden nur noch als Migrationsquelle akzeptiert und nie als Ziel benutzt.
    return canonical_token_path(server)

def legacy_token_path(server):
    path=str(server.get('token_file','')).strip()
    if not path or not path.startswith('/') or '\x00' in path:
        return ''
    real=os.path.realpath(path) if os.path.exists(path) else os.path.abspath(path)
    for root in LEGACY_TOKEN_ROOTS:
        rr=os.path.realpath(root)
        if real == rr or real.startswith(rr.rstrip('/')+'/'):
            return path
    return ''

def ensure_canonical_token(server):
    dst=canonical_token_path(server)
    if os.path.isfile(dst) and not os.path.islink(dst):
        return dst
    src=legacy_token_path(server)
    if src and os.path.isfile(src) and not os.path.islink(src):
        try:
            tok=read_token(src)
            write_token(dst,tok)
        except Exception:
            pass
    return dst


def canonical_ca_path(server):
    name=str(server.get('name','')).strip()
    if not NAME_RE.match(name): die('Ungueltiger Servername')
    safe=re.sub(r'[^A-Za-z0-9._-]', '_', name)
    return os.path.join(CA_ROOT, safe + '.crt')

def write_ca(path, pem):
    pem=str(pem or '').strip()+'\n'
    if '-----BEGIN CERTIFICATE-----' not in pem or '-----END CERTIFICATE-----' not in pem:
        raise RuntimeError('Remote-Agent lieferte kein gueltiges TLS-Zertifikat')
    try:
        ssl.PEM_cert_to_DER_cert(pem)
    except Exception as e:
        raise RuntimeError('Remote-Agent TLS-Zertifikat ist ungueltig: %s' % e)
    d=os.path.dirname(path); os.makedirs(d,mode=0o750,exist_ok=True)
    try: gid=grp.getgrnam('www').gr_gid
    except KeyError: gid=os.stat(d).st_gid
    try: os.chown(d,0,gid)
    except Exception: pass
    try: os.chmod(d,0o750)
    except Exception: pass
    fd,tmp=tempfile.mkstemp(prefix='.agent-ca.',dir=d)
    try:
        with os.fdopen(fd,'w') as f:
            f.write(pem); f.flush(); os.fsync(f.fileno())
        os.chown(tmp,0,gid); os.chmod(tmp,0o640); os.replace(tmp,path)
        dfd=os.open(d,os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
        sync_observability_auth()
    finally:
        try:
            if os.path.exists(tmp): os.unlink(tmp)
        except Exception: pass

def update_registry_tls(server_name, ca_path):
    with open(REGISTRY,encoding='utf-8') as f: reg=json.load(f)
    changed=False
    for srv in reg.get('servers',[]):
        if isinstance(srv,dict) and str(srv.get('name','')).lower()==str(server_name).lower():
            wanted={'verify':True,'verify_host':True,'ca_file':ca_path}
            if srv.get('tls') != wanted:
                srv['tls']=wanted; changed=True
    if changed:
        d=os.path.dirname(REGISTRY) or '.'
        fd,tmp=tempfile.mkstemp(prefix='.servers.',dir=d)
        try:
            with os.fdopen(fd,'w') as f:
                json.dump(reg,f,indent=2,ensure_ascii=False); f.write('\n'); f.flush(); os.fsync(f.fileno())
            st=os.stat(REGISTRY)
            os.chown(tmp,st.st_uid,st.st_gid); os.chmod(tmp,stat.S_IMODE(st.st_mode)); os.replace(tmp,REGISTRY)
        finally:
            try:
                if os.path.exists(tmp): os.unlink(tmp)
            except Exception: pass

def sync_remote_identity(req, server):
    token=run_ssh(req,READ_SCRIPT,30).strip().splitlines()[-1].strip()
    if len(token)<32 or re.search(r'\s',token): raise RuntimeError('Ungueltiger Token vom Agent')
    cert=run_ssh(req,READ_CERT_SCRIPT,30)
    ca_path=canonical_ca_path(server)
    write_ca(ca_path,cert)
    update_registry_tls(server.get('name',''),ca_path)
    # load_server erneut verwenden, damit api_check den eben normalisierten TLS-Pfad sieht.
    refreshed=load_server(str(server.get('name','')))
    return token, refreshed, ca_path

def token_info(path):
    out={'path':path,'exists':False,'secure':False,'readable':False,'fingerprint':'','size':0}
    try: st=os.lstat(path)
    except FileNotFoundError: return out
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode): return out
    out['exists']=True; out['size']=st.st_size
    mode=stat.S_IMODE(st.st_mode)
    out['mode']='%04o' % mode
    try: out['owner']=pwd.getpwuid(st.st_uid).pw_name; out['group']=grp.getgrgid(st.st_gid).gr_name
    except Exception: out['owner']=str(st.st_uid); out['group']=str(st.st_gid)
    out['secure']=(mode & 0o007)==0 and (mode & 0o020)==0
    try:
        with open(path,'rb') as f: raw=f.read(4097)
        if len(raw)<=4096:
            tok=raw.decode('utf-8','strict').strip()
            out['readable']=len(tok)>=32 and not bool(re.search(r'\s',tok))
            if out['readable']: out['fingerprint']=hashlib.sha256(tok.encode()).hexdigest()[:16]
    except Exception: pass
    return out

def read_token(path):
    with open(path,encoding='utf-8') as f: token=f.read(4097).strip()
    if len(token)<32 or re.search(r'\s',token): raise RuntimeError('Token-Datei enthaelt keinen gueltigen Token')
    return token

def sync_observability_auth():
    if not os.path.isfile(OBS_AUTH_SYNC):
        return
    p=subprocess.run(['/usr/bin/python3',OBS_AUTH_SYNC],stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True)
    if p.returncode != 0:
        raise RuntimeError('Observability Apache-Auth konnte nicht synchronisiert werden: '+(p.stderr or p.stdout).strip()[-800:])

def write_token(path, token):
    if len(token)<32 or re.search(r'\s',token): raise RuntimeError('Remote-Agent lieferte keinen gueltigen Token')
    d=os.path.dirname(path); os.makedirs(d,mode=0o750,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.agent-token.',dir=d)
    try:
        with os.fdopen(fd,'w') as f:
            f.write(token+'\n'); f.flush(); os.fsync(f.fileno())
        try: gid=grp.getgrnam('www').gr_gid
        except KeyError: gid=os.stat(d).st_gid
        os.chown(tmp,0,gid); os.chmod(tmp,0o640); os.replace(tmp,path)
        dfd=os.open(d,os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        try:
            if os.path.exists(tmp): os.unlink(tmp)
        except Exception: pass

def api_check(server, token):
    url=str(server.get('url','')).rstrip('/')+'/health'
    tls=server.get('tls') if isinstance(server.get('tls'),dict) else {}
    verify=tls.get('verify',True) is not False
    if verify:
        ca=str(tls.get('ca_file','')).strip()
        if ca:
            if not os.path.isfile(ca): raise RuntimeError('CA-Datei fehlt: '+ca)
            ctx=ssl.create_default_context(cafile=ca)
        else: ctx=ssl.create_default_context()
        if tls.get('verify_host',True) is False: ctx.check_hostname=False
    else:
        ctx=ssl._create_unverified_context()
    req=urllib.request.Request(url,headers={'X-API-Token':token,'Accept':'application/json'})
    try:
        with urllib.request.urlopen(req,context=ctx,timeout=8) as r:
            body=r.read(16384).decode('utf-8','replace')
            return {'ok':200<=r.status<300,'http_status':r.status,'body':body[:4000],'authenticated':True}
    except urllib.error.HTTPError as e:
        # 401/403 sind Auth-Fehler. Ein 503 von /health bedeutet dagegen:
        # API und Auth funktionieren, aber der Agent meldet einen degradierten
        # Health-Zustand. Den JSON-Body fuer die GUI erhalten.
        try:
            body=e.read(16384).decode('utf-8','replace')
        except Exception:
            body=''
        return {'ok':False,'http_status':int(e.code),'body':body[:4000],
                'authenticated': int(e.code) not in (401,403), 'error':str(e)}
    except Exception as e:
        return {'ok':False,'error':str(e)}

def ssh_args(req):
    host=str(req.get('ssh_host','')).strip(); user=str(req.get('ssh_user','root')).strip(); port=int(req.get('ssh_port',22))
    if not HOST_RE.match(host): die('Ungueltiger SSH Host')
    if not USER_RE.match(user): die('Ungueltiger SSH Benutzer')
    if port<1 or port>65535: die('Ungueltiger SSH Port')
    if not os.path.isfile(KNOWN_HOSTS): die('SSH known_hosts fehlt. Agent zuerst enrolen oder Host-Key hinterlegen.')
    base=['ssh','-p',str(port),'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+KNOWN_HOSTS,'-o','ConnectTimeout=10']
    mode=str(req.get('ssh_auth','password'))
    password=None
    if mode=='password':
        password=str(req.get('ssh_password',''))
        if not password: die('SSH-Passwort fehlt')
        base[base.index('-o'):] # no-op
        base=['sshpass','-d','3','ssh','-p',str(port),'-o','BatchMode=no','-o','PubkeyAuthentication=no','-o','PasswordAuthentication=yes','-o','KbdInteractiveAuthentication=no','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+KNOWN_HOSTS,'-o','ConnectTimeout=10']
    elif mode=='key':
        key=str(req.get('ssh_key_file','')).strip()
        if not key.startswith('/') or not os.path.isfile(key) or os.path.islink(key): die('SSH-Key-Datei fehlt/ist ungueltig')
        base+=['-i',key,'-o','BatchMode=yes']
    else: die('Unbekannte SSH-Authentifizierung')
    base.append(user+'@'+host)
    return base,password

def run_ssh_command(req, command, input_bytes=b'', timeout=120):
    args,password=ssh_args(req)
    args.append(command)
    if password is None:
        p=subprocess.run(args,input=input_bytes,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    else:
        r,w=os.pipe()
        try:
            os.write(w,(password+'\n').encode()); os.close(w); w=-1
            full=list(args); full[2]=str(r)
            p=subprocess.run(full,input=input_bytes,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout,pass_fds=(r,))
        finally:
            try: os.close(r)
            except OSError: pass
            if w>=0:
                try: os.close(w)
                except OSError: pass
    out=p.stdout.decode('utf-8','replace'); err=p.stderr.decode('utf-8','replace')
    if p.returncode!=0:
        detail=(err or out).strip()
        raise RuntimeError('SSH-Repair-Befehl fehlgeschlagen (rc=%d): %s' % (p.returncode,detail[-3000:]))
    return out

def manager_source_ip(req):
    host=str(req.get('ssh_host','')).strip(); port=int(req.get('ssh_port',22))
    try:
        sock=socket.create_connection((host,port),5)
        try: return str(sock.getsockname()[0])
        finally: sock.close()
    except Exception as e:
        raise RuntimeError('Manager-IP fuer Remote-Repair konnte nicht bestimmt werden: %s' % e)

def repair_agent(req, server):
    if not os.path.isfile(REPAIR_BUNDLE) or os.path.islink(REPAIR_BUNDLE):
        raise RuntimeError('Remote-Agent Repair-Bundle fehlt: '+REPAIR_BUNDLE)
    with open(REPAIR_BUNDLE,'rb') as f:
        bundle=f.read()
    if len(bundle)<1024 or len(bundle)>128*1024*1024:
        raise RuntimeError('Remote-Agent Repair-Bundle hat unplausible Groesse')
    remote_bundle='/tmp/teko-agent-repair-%d.tar.gz' % os.getpid()
    run_ssh_command(req, 'umask 077; cat > '+shlex.quote(remote_bundle), bundle, 120)
    forgejo_token_file='/opt/service/env/forgejo-api.token'
    if not os.path.isfile(forgejo_token_file) or os.path.islink(forgejo_token_file):
        raise RuntimeError('Forgejo Service-Token fehlt: '+forgejo_token_file)
    with open(forgejo_token_file,'rb') as f:
        forgejo_token=f.read()
    if len(forgejo_token)<16 or len(forgejo_token)>16384:
        raise RuntimeError('Forgejo Service-Token hat unplausible Groesse')
    remote_forgejo_token='/tmp/teko-agent-repair-forgejo-%d.token' % os.getpid()
    run_ssh_command(req, 'umask 077; cat > '+shlex.quote(remote_forgejo_token), forgejo_token, 30)

    manager_ip=manager_source_ip(req)
    parsed=urllib.parse.urlparse(str(server.get('url','')))
    api_port=parsed.port or 5008
    url_host=parsed.hostname or ''
    bind_ip=url_host if re.match(r'^\d{1,3}(?:\.\d{1,3}){3}$',url_host) else ''
    fqdn=str(server.get('name','')).strip() or url_host
    force=bool(req.get('force',False))
    remote_script = '''set -eu
bundle=__BUNDLE__
work=$(mktemp -d /tmp/teko-agent-repair.XXXXXX)
forgejo_token=__FORGEJO_TOKEN__
cleanup(){ rm -rf "$work" "$bundle" "$forgejo_token"; }
trap cleanup EXIT

tar -xzf "$bundle" -C "$work"
root="$work/teko-agent-bundle"
for required in setup_remote_config_agent.sh setup_config_agent.sh teko-stack.conf config-agent/VERSION; do
  [ -f "$root/$required" ] || { echo "Repair-Bundle unvollstaendig: $required fehlt" >&2; exit 22; }
done
chmod +x "$root/setup_remote_config_agent.sh" "$root/setup_config_agent.sh"

bind=__BIND__
if [ -z "$bind" ] && [ -r /opt/service/config-agent/global.json ]; then
  bind=$(python3 - <<'PYBIND'
import json
try:
    with open('/opt/service/config-agent/global.json') as f: c=json.load(f)
    listen=str(c.get('listen',''))
    if listen.startswith('['): print(listen.split(']')[0][1:])
    else: print(listen.rsplit(':',1)[0] if ':' in listen else listen)
except Exception: print('')
PYBIND
)
fi
[ -n "$bind" ] || { echo 'Agent Bind-IP konnte nicht bestimmt werden' >&2; exit 21; }

CONFIG_MANAGER_IP=__MANAGER__ \
CONFIG_AGENT_BIND_IP="$bind" \
CONFIG_AGENT_FQDN=__FQDN__ \
CONFIG_AGENT_PORT=__PORT__ \
CONFIG_AGENT_REMOTE_MODE=1 \
CONFIG_AGENT_FORGEJO_TOKEN_FILE="$forgejo_token" \
CONFIG_AGENT_REMOTE_PROFILE_RESET=__PROFILE_RESET__ \
TEKO_FORCE=__FORCE__ \
bash "$root/setup_remote_config_agent.sh"
'''
    remote_script=remote_script.replace('__BUNDLE__',shlex.quote(remote_bundle)).replace('__BIND__',shlex.quote(bind_ip)).replace('__MANAGER__',shlex.quote(manager_ip)).replace('__FQDN__',shlex.quote(fqdn)).replace('__PORT__',shlex.quote(str(api_port))).replace('__FORCE__',shlex.quote('1' if force else '0')).replace('__PROFILE_RESET__',shlex.quote('1' if force else '0')).replace('__FORGEJO_TOKEN__',shlex.quote(remote_forgejo_token))
    return run_ssh(req,remote_script,300)

def run_ssh(req, script, timeout=30):
    args,password=ssh_args(req)
    sudo=bool(req.get('use_sudo',False)) and str(req.get('ssh_user','root'))!='root'
    remote=['sudo','-n','bash','-s'] if sudo else ['bash','-s']
    args+=remote
    if password is None:
        p=subprocess.run(args,input=script.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    else:
        r,w=os.pipe()
        try:
            os.write(w,(password+'\n').encode()); os.close(w); w=-1
            full=list(args); full[2]=str(r)
            p=subprocess.run(full,input=script.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout,pass_fds=(r,))
        finally:
            try: os.close(r)
            except OSError: pass
            if w>=0:
                try: os.close(w)
                except OSError: pass
    out=p.stdout.decode('utf-8','replace'); err=p.stderr.decode('utf-8','replace')
    if p.returncode!=0: raise RuntimeError('SSH-Befehl fehlgeschlagen (rc=%d): %s' % (p.returncode,(err or out).strip()[-1200:]))
    return out

READ_SCRIPT=r'''set -eu
f=/opt/service/env/config-agent.env
[ -r "$f" ] || { echo "config-agent.env fehlt/nicht lesbar" >&2; exit 11; }
t=$(sed -n 's/^CONFIG_AGENT_API_TOKEN=//p' "$f" | tail -n1)
[ ${#t} -ge 32 ] || { echo "CONFIG_AGENT_API_TOKEN fehlt/ist zu kurz" >&2; exit 12; }
printf '%s\n' "$t"
'''
READ_CERT_SCRIPT=r'''set -eu
f=/opt/service/ssl/agent.local.crt
[ -r "$f" ] || { echo "Agent TLS-Zertifikat fehlt/nicht lesbar" >&2; exit 14; }
cat "$f"
'''
ROTATE_SCRIPT=r'''set -eu
f=/opt/service/env/config-agent.env
[ -r "$f" ] || { echo "config-agent.env fehlt/nicht lesbar" >&2; exit 11; }
old=$(sed -n 's/^CONFIG_AGENT_API_TOKEN=//p' "$f" | tail -n1)
[ ${#old} -ge 32 ] || { echo "alter CONFIG_AGENT_API_TOKEN fehlt/ist zu kurz" >&2; exit 12; }
new=$(openssl rand -hex 32)
tmp=$(mktemp /opt/service/env/.config-agent.env.XXXXXX)
awk -v n="$new" 'BEGIN{done=0} /^CONFIG_AGENT_API_TOKEN=/{print "CONFIG_AGENT_API_TOKEN=" n; done=1; next} {print} END{if(!done) print "CONFIG_AGENT_API_TOKEN=" n}' "$f" > "$tmp"
chown --reference="$f" "$tmp" 2>/dev/null || true
chmod --reference="$f" "$tmp" 2>/dev/null || chmod 600 "$tmp"
mv -f "$tmp" "$f"
systemctl restart config-agent.service
sleep 1
systemctl is-active --quiet config-agent.service || { echo "Config-Agent nach Rotation nicht aktiv" >&2; exit 13; }
printf 'OLD=%s\nNEW=%s\n' "$old" "$new"
'''

def restore_remote(req, old):
    script=r'''set -eu
f=/opt/service/env/config-agent.env
old=%s
tmp=$(mktemp /opt/service/env/.config-agent.env.XXXXXX)
awk -v n="$old" 'BEGIN{done=0} /^CONFIG_AGENT_API_TOKEN=/{print "CONFIG_AGENT_API_TOKEN=" n; done=1; next} {print} END{if(!done) print "CONFIG_AGENT_API_TOKEN=" n}' "$f" > "$tmp"
chown --reference="$f" "$tmp" 2>/dev/null || true
chmod --reference="$f" "$tmp" 2>/dev/null || chmod 600 "$tmp"
mv -f "$tmp" "$f"
systemctl restart config-agent.service
''' % json.dumps(old)
    run_ssh(req,script,30)

def main():
    req=load_request(); action=str(req.get('action','status')); name=str(req.get('server',''))
    srv=load_server(name); path=ensure_canonical_token(srv); info=token_info(path)
    if action=='status':
        api={'ok':False,'error':'Token-Datei fehlt oder ungueltig'}
        if info.get('readable'):
            try: api=api_check(srv,read_token(path))
            except Exception as e: api={'ok':False,'error':str(e)}
        print(json.dumps({'ok':True,'server':name,'token':info,'api':api},ensure_ascii=False)); return
    if action=='sync':
        tok,srv,ca_path=sync_remote_identity(req,srv)
        write_token(path,tok); api=api_check(srv,tok)
        if not api.get('ok') and not api.get('authenticated'):
            die('Token synchronisiert, aber Authentifizierung/API-Verbindung fehlgeschlagen: '+str(api.get('error') or api.get('http_status')))
        msg='Token via SSH synchronisiert.' if api.get('ok') else 'Token via SSH synchronisiert; Agent Health ist degradiert.'
        print(json.dumps({'ok':True,'message':msg,'token':token_info(path),'api':api},ensure_ascii=False)); return
    if action=='repair':
        repair_out=repair_agent(req,srv)
        try:
            tok,srv,ca_path=sync_remote_identity(req,srv)
        except Exception as e:
            die('Agent-Repair abgeschlossen, aber Token/TLS-Identitaet konnte nicht synchronisiert werden: '+str(e))
        write_token(path,tok)
        api=api_check(srv,tok)
        if api.get('ok'):
            msg='Agent repariert/aktualisiert; Token synchronisiert, Authentifizierung und Health sind OK.'
        elif api.get('authenticated') is True:
            msg='Agent repariert/aktualisiert; Token synchronisiert und Authentifizierung ist OK, Agent Health ist degradiert.'
        elif api.get('authenticated') is False:
            msg='Agent repariert/aktualisiert; Token synchronisiert, aber die Agent-Authentifizierung ist fehlgeschlagen.'
        else:
            msg='Agent repariert/aktualisiert; Token synchronisiert, aber die Agent-API konnte nicht verifiziert werden.'
        print(json.dumps({'ok':True,'message':msg,'token':token_info(path),'api':api,'repair_output':repair_out[-4000:]},ensure_ascii=False)); return
    if action=='rotate':
        old_local=None
        try: old_local=read_token(path)
        except Exception: pass
        out=run_ssh(req,ROTATE_SCRIPT,45)
        vals={}
        for line in out.splitlines():
            if '=' in line:
                k,v=line.split('=',1)
                if k in ('OLD','NEW'): vals[k]=v.strip()
        old=vals.get('OLD',''); new=vals.get('NEW','')
        if len(old)<32 or len(new)<32: die('Rotation lieferte keine gueltigen Tokenwerte')
        write_token(path,new)
        try:
            cert=run_ssh(req,READ_CERT_SCRIPT,30)
            ca_path=canonical_ca_path(srv); write_ca(ca_path,cert); update_registry_tls(name,ca_path); srv=load_server(name)
        except Exception as e:
            try: restore_remote(req,old)
            except Exception: pass
            try: write_token(path,old_local or old)
            except Exception: pass
            die('Token rotiert, aber Agent TLS-Identitaet konnte nicht synchronisiert werden; Rollback wurde versucht: '+str(e))
        api=api_check(srv,new)
        if not api.get('ok') and not api.get('authenticated'):
            try: restore_remote(req,old)
            except Exception: pass
            try: write_token(path,old_local or old)
            except Exception: pass
            die('Neuer Token wurde vom Agent nicht akzeptiert; Rollback wurde versucht: '+str(api.get('error') or api.get('http_status')))
        if api.get('ok'):
            msg='Token rotiert; Authentifizierung und Agent Health sind OK.'
        elif api.get('authenticated') is True:
            msg='Token rotiert; Authentifizierung ist OK, Agent Health ist degradiert.'
        elif api.get('authenticated') is False:
            msg='Token rotiert, aber die Agent-Authentifizierung ist fehlgeschlagen.'
        else:
            msg='Token rotiert, aber die Agent-API konnte nicht verifiziert werden.'
        print(json.dumps({'ok':True,'message':msg,'token':token_info(path),'api':api},ensure_ascii=False)); return
    die('Unbekannte Aktion')

if __name__=='__main__':
    try: main()
    except subprocess.TimeoutExpired: die('SSH/API Aktion hat das Zeitlimit ueberschritten')
    except Exception as e: die(str(e))
