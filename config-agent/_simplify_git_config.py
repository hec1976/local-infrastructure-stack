#!/usr/bin/env python3
from __future__ import annotations
import json, os, shutil, tempfile
from pathlib import Path
from datetime import datetime, timezone
from urllib.parse import urlparse

BASE = Path(__file__).resolve().parent
GLOBAL = BASE / 'global.json'
PROFILES = BASE / 'git_deploy.json'
STAMP = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')


def load(path: Path) -> dict:
    with path.open('r', encoding='utf-8') as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise SystemExit(f'{path} muss ein JSON-Objekt enthalten')
    return data


def atomic_write(path: Path, data: dict) -> None:
    st = path.stat()
    fd, tmp = tempfile.mkstemp(prefix=path.name + '.tmp.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write('\n')
            fh.flush(); os.fsync(fh.fileno())
        os.chmod(tmp, st.st_mode & 0o7777)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def simple_preserve(items):
    out=[]
    for raw in items or []:
        if isinstance(raw,str): out.append(raw); continue
        if not isinstance(raw,dict): out.append(raw); continue
        item={'path':raw.get('path','')}
        if raw.get('policy','preserve_existing') != 'preserve_existing': item['policy']=raw['policy']
        if raw.get('required',False): item['required']=True
        if raw.get('user'): item['owner']=raw['user']
        if raw.get('group'): item['group']=raw['group']
        if raw.get('mode') is not None:
            mode=raw['mode']
            item['mode']=format(mode,'04o') if isinstance(mode,int) else str(mode)
        if list(item)==['path']: out.append(item['path'])
        else: out.append(item)
    return out


def simplify_profile(pid, p):
    if not isinstance(p,dict): return p
    repo=p.get('repository',p.get('git_url',''))
    target=p.get('target',p.get('target_path',''))
    ref=p.get('allowed_ref','')
    branch=p.get('branch') or (ref[11:] if ref.startswith('refs/heads/') else ref)
    out={}
    if p.get('enabled',True) is False: out['enabled']=False
    out['repository']=repo
    out['branch']=branch or 'main'
    out['target']=target
    owner=p.get('owner',p.get('user'))
    if owner: out['owner']=owner
    if p.get('group'): out['group']=p['group']
    service=p.get('service',p.get('restart_service'))
    if service: out['service']=service
    preserve=p.get('preserve',p.get('preserve_paths'))
    if preserve: out['preserve']=simple_preserve(preserve)
    pre=p.get('preflight')
    if isinstance(pre,dict) and isinstance(pre.get('argv'),list):
        if pre.get('cwd','{release}') == '{release}' and int(pre.get('timeout',30)) == 30:
            out['preflight']=pre['argv']
        else: out['preflight']=pre
    elif pre: out['preflight']=pre
    advanced={}
    derived_release=''
    if target:
        derived_release=str(Path(target).parent / '.git-deploy' / pid / 'releases')
    checks={
      'deploy_mode':('directory_swap',p.get('deploy_mode','directory_swap')),
      'ref_policy':('ancestor',p.get('ref_policy','ancestor')),
      'releases_dir':(derived_release,p.get('releases_dir',derived_release)),
      'daemon_reload':(False,p.get('daemon_reload',False)),
      'immutable_permissions':(True,p.get('immutable_permissions',True)),
      'allow_symlinks':(True,p.get('allow_symlinks',True)),
      'reject_hardlinks':(True,p.get('reject_hardlinks',True)),
      'reject_lfs_pointers':(True,p.get('reject_lfs_pointers',True)),
      'require_signed_commit':(False,p.get('require_signed_commit',False)),
    }
    for key,(default,value) in checks.items():
        if value != default: advanced[key]=value
    if 'keep_releases' in p and p['keep_releases'] != 5: advanced['keep_releases']=p['keep_releases']
    for key in ('auth_scheme','deploy_user','ca_info','max_files','max_bytes','max_tree_listing_bytes','healthcheck'):
        if key in p: advanced[key]=p[key]
    known=set(['enabled','repository','git_url','branch','allowed_ref','target','target_path','owner','user','group','service','restart_service','preserve','preserve_paths','preflight','keep_releases','auth_scheme','deploy_user','ca_info','max_files','max_bytes','max_tree_listing_bytes','healthcheck']+list(checks))
    for key,value in p.items():
        if key not in known and key not in ('format','advanced','tag','ref'):
            advanced[key]=value
    if advanced: out['advanced']=advanced
    return out


def main():
    if not GLOBAL.exists() or not PROFILES.exists():
        raise SystemExit('global.json oder git_deploy.json fehlt')
    g=load(GLOBAL); p=load(PROFILES)
    shutil.copy2(GLOBAL, GLOBAL.with_name(GLOBAL.name + '.bak.simple.' + STAMP))
    shutil.copy2(PROFILES, PROFILES.with_name(PROFILES.name + '.bak.simple.' + STAMP))
    gd=g.get('git_deploy') if isinstance(g.get('git_deploy'),dict) else {}
    gu=g.get('git_upload') if isinstance(g.get('git_upload'),dict) else {}
    shared=g.get('forgejo') if isinstance(g.get('forgejo'),dict) else {}
    url=gu.get('api_base_url') or gu.get('base_url') or shared.get('api_base_url') or shared.get('url') or shared.get('base_url')
    token=shared.get('token_file') or gu.get('token_file') or gd.get('deploy_token_file') or '/opt/service/env/forgejo-api.token'
    verify=False if isinstance(url,str) and url.lower().startswith('http://') else shared.get('verify_tls',gd.get('verify_tls',gu.get('verify_tls',True)))
    g['forgejo']={'url':url,'token_file':token,'verify_tls':bool(verify)}
    g['git_deploy']={'enabled':bool(gd.get('enabled',False)),'allowed_roots':gd.get('allowed_roots',[])}
    compact_upload={'enabled':bool(gu.get('enabled',False))}
    for key,default in [('allowed_owners',[]),('allow_mirror',False),('allow_default_branch',True),('commit_name','Service Repository Upload'),('commit_email','git-upload@service.internal')]:
        if key in gu and gu[key] != default: compact_upload[key]=gu[key]
    g['git_upload']=compact_upload
    profiles=p.get('profiles') if isinstance(p.get('profiles'),dict) else {}
    p={'schema_version':2,'profiles':{pid:simplify_profile(pid,profile) for pid,profile in profiles.items()}}
    atomic_write(GLOBAL,g); atomic_write(PROFILES,p)
    print(f'Vereinfacht: {GLOBAL}')
    print(f'Vereinfacht: {PROFILES}')
    print(f'Backups mit Zeitstempel {STAMP} wurden angelegt.')

if __name__ == '__main__': main()
