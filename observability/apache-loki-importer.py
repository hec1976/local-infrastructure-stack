#!/usr/bin/env python3
import glob, json, os, time, urllib.request
from pathlib import Path

LOKI_URL=os.environ.get('TEKO_LOKI_PUSH_URL','http://127.0.0.1:3100/loki/api/v1/push')
STATE=Path(os.environ.get('TEKO_APACHE_LOKI_STATE_FILE','/var/lib/teko-apache-loki-importer/state.json'))
POLL=max(1,int(os.environ.get('TEKO_APACHE_LOKI_POLL_SECONDS','2')))
PATTERNS=[p for p in os.environ.get('TEKO_APACHE_LOG_GLOBS','/var/log/apache2/*access*.log:/var/log/apache2/*error*.log:/var/log/apache2/access_log:/var/log/apache2/error_log:/var/log/apache2/modsec_audit.log').split(':') if p]
MAX_LINES=max(10,min(5000,int(os.environ.get('TEKO_APACHE_LOKI_BATCH','500'))))

def load_state():
    try:return json.loads(STATE.read_text())
    except Exception:return {}
def save_state(s):
    STATE.parent.mkdir(parents=True,exist_ok=True);t=STATE.with_suffix('.tmp');t.write_text(json.dumps(s)+'\n');os.chmod(t,0o600);os.replace(t,STATE)
def log_job(path):
    n=Path(path).name.lower()
    if 'modsec' in n:
        return 'modsecurity'
    if n.startswith('config-manager_') or n.startswith('config-manager-'):
        return 'config-manager'
    return 'apache'

def log_type(path):
    n=Path(path).name.lower()
    if 'modsec' in n:return 'modsecurity-audit'
    if 'error' in n:return 'error'
    return 'access'
def push(path,lines):
    if not lines:return
    vals=[]
    now=int(time.time() * 1_000_000_000)
    for i,line in enumerate(lines): vals.append([str(now+i),line.rstrip('\r\n')])
    job=log_job(path)
    payload={'streams':[{'stream':{'job':job,'service':job,'log_type':log_type(path),'source':Path(path).name},'values':vals}]}
    req=urllib.request.Request(LOKI_URL,data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'},method='POST')
    with urllib.request.urlopen(req,timeout=10) as r:
        if r.status not in (200,204): raise RuntimeError(f'Loki HTTP {r.status}')
def files():
    out=[]
    for pat in PATTERNS:out.extend(glob.glob(pat))
    return sorted({p for p in out if os.path.isfile(p)})
def cycle(st):
    for p in files():
        try:
            stat=os.stat(p); key=p; cur=st.get(key,{})
            inode=int(stat.st_ino); off=int(cur.get('offset',stat.st_size)) if int(cur.get('inode',inode))==inode else 0
            if off>stat.st_size:off=0
            lines=[]
            with open(p,'r',encoding='utf-8',errors='replace') as f:
                f.seek(off)
                for _ in range(MAX_LINES):
                    line=f.readline()
                    if not line:break
                    lines.append(line)
                newoff=f.tell()
            if lines:push(p,lines)
            st[key]={'inode':inode,'offset':newoff}
        except (FileNotFoundError,PermissionError):pass
    save_state(st)
def main():
    st=load_state()
    while True:
        try:cycle(st)
        except Exception as e:print(f'ERROR: {e}',flush=True)
        time.sleep(POLL)
if __name__=='__main__':main()
