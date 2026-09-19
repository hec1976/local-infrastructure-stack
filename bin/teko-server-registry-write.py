#!/usr/bin/python3
import json, os, re, sys, tempfile, urllib.parse, subprocess

PATH = '/opt/service/config-manager/servers.json'
NAME_RE = re.compile(r'^[A-Za-z0-9._:-]{1,128}$')
GROUP_RE = re.compile(r'^[A-Za-z0-9._-]{1,64}$')
LABEL_KEY_RE = re.compile(r'^[A-Za-z0-9._-]{1,64}$')
LABEL_VAL_RE = re.compile(r'^[A-Za-z0-9._:@/-]{1,128}$')
HOST_ID_RE = re.compile(r'^[A-Za-z0-9._:-]{1,128}$')

def fail(msg):
    print(msg, file=sys.stderr)
    raise SystemExit(2)

def validate(data):
    if not isinstance(data, dict): fail('Registry muss ein JSON-Objekt sein')
    if data.get('schema_version', 1) != 1: fail('Nur schema_version 1 wird unterstuetzt')
    servers = data.get('servers')
    if not isinstance(servers, list): fail('servers muss eine Liste sein')
    names, urls = set(), set()
    for i, s in enumerate(servers):
        if not isinstance(s, dict): fail(f'Server #{i+1} ist kein Objekt')
        name = str(s.get('name', '')).strip()
        url = str(s.get('url', '')).strip()
        host_id = str(s.get('host_id', '')).strip()
        if host_id and not HOST_ID_RE.fullmatch(host_id): fail(f'Ungueltige host_id bei {name}: {host_id}')
        if not NAME_RE.fullmatch(name): fail(f'Ungueltiger Servername: {name}')
        p = urllib.parse.urlparse(url)
        if p.scheme not in ('http','https') or not p.hostname: fail(f'Ungueltige Server-URL: {url}')
        nk, uk = name.lower(), url.rstrip('/').lower()
        if nk in names: fail(f'Doppelter Servername: {name}')
        if uk in urls: fail(f'Doppelte Server-URL: {url}')
        names.add(nk); urls.add(uk)
        groups = s.get('groups', [])
        if not isinstance(groups, list): fail(f'groups muss eine Liste sein bei {name}')
        seen_groups = set()
        for g in groups:
            g = str(g).strip()
            if not GROUP_RE.fullmatch(g): fail(f'Ungueltige Gruppe bei {name}: {g}')
            if g.lower() in seen_groups: fail(f'Doppelte Gruppe bei {name}: {g}')
            seen_groups.add(g.lower())
        labels = s.get('labels', {})
        if not isinstance(labels, dict): fail(f'labels muss ein Objekt sein bei {name}')
        for k, v in labels.items():
            k, v = str(k).strip(), str(v).strip()
            if not LABEL_KEY_RE.fullmatch(k) or not LABEL_VAL_RE.fullmatch(v):
                fail(f'Ungueltiges Label bei {name}: {k}={v}')
        if 'enabled' in s and not isinstance(s['enabled'], bool): fail(f'enabled muss boolean sein bei {name}')
        tf = str(s.get('token_file', '')).strip()
        if tf and (not tf.startswith('/') or '\x00' in tf): fail(f'Ungueltiger token_file Pfad bei {name}')
    data['schema_version'] = 1
    return data

def main():
    raw = sys.stdin.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024: fail('Registry zu gross')
    try: data = json.loads(raw)
    except Exception as e: fail(f'Ungueltiges JSON: {e}')
    data = validate(data)
    directory = os.path.dirname(PATH)
    if not os.path.isdir(directory): fail(f'Verzeichnis fehlt: {directory}')
    old_stat = os.stat(PATH) if os.path.exists(PATH) else None
    fd, tmp = tempfile.mkstemp(prefix='.servers.json.', dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write('\n'); f.flush(); os.fsync(f.fileno())
        if old_stat:
            os.chown(tmp, old_stat.st_uid, old_stat.st_gid)
            os.chmod(tmp, old_stat.st_mode & 0o777)
        else:
            os.chmod(tmp, 0o640)
        os.replace(tmp, PATH)
        sync='/usr/local/libexec/teko-observability-auth-sync.py'
        if os.path.isfile(sync):
            p=subprocess.run(['/usr/bin/python3',sync],stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True)
            if p.returncode != 0:
                fail('Observability Apache-Auth Sync fehlgeschlagen: '+(p.stderr or p.stdout).strip())
        dfd = os.open(directory, os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
    print('ok')

if __name__ == '__main__': main()
