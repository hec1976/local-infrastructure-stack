#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC1090
source "$ROOT/teko-stack.conf"

DATA_DIR="${CONFIG_MANAGER_DATA_DIR:-/srv/www/config-manager-standalone/standalone/data}"
CONFIG_MANAGER_RUNTIME_USER="${CONFIG_MANAGER_RUNTIME_USER:-wwwrun}"
CONFIG_MANAGER_RUNTIME_GROUP="${CONFIG_MANAGER_RUNTIME_GROUP:-www}"
FILE="$DATA_DIR/deploy_profiles.json"
FORGEJO_URL="${FORGEJO_PUBLIC_URL:-https://git.local}"
ORG="${FORGEJO_ORG:-teko}"
REPO="${FORGEJO_OBSERVABILITY_REPO:-observability-client}"

install -d -o "$CONFIG_MANAGER_RUNTIME_USER" -g "$CONFIG_MANAGER_RUNTIME_GROUP" -m 0770 "$DATA_DIR"
python3 - "$FILE" "$FORGEJO_URL" "$ORG" "$REPO" <<'PY'
import json, os, sys, tempfile
path, base, org, repo = sys.argv[1:]
try:
    with open(path, encoding='utf-8') as f:
        doc=json.load(f)
except Exception:
    doc={'schema_version':2,'profiles':{}}
if not isinstance(doc,dict): doc={'schema_version':2,'profiles':{}}
profiles=doc.get('profiles')
if not isinstance(profiles,dict): profiles={}
profiles['observability-client']={
    'enabled': True,
    'repository': base.rstrip('/')+'/'+org+'/'+repo+'.git',
    'branch': 'main',
    'target': '/opt/service/observability-client',
    'owner': 'root',
    'group': 'root',
    'preserve': [],
    'allow_repository_package_plan': False,
    'post_deploy': {
        'script': 'install.sh',
        'timeout': 900,
        'run_on_rollback': True
    },
    'require_diff_preview': True,
    'allow_symlinks': False,
    'reject_hardlinks': True,
    'reject_lfs_pointers': True,
    'daemon_reload': True
}
doc['schema_version']=2
doc['profiles']=profiles
os.makedirs(os.path.dirname(path), exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix='.deploy-profiles.',dir=os.path.dirname(path))
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(doc,f,indent=2,ensure_ascii=False)
        f.write('\n')
        f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o640)
    os.replace(tmp,path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
print('Deploy-Profil bereit: observability-client')
print('Repository: '+profiles['observability-client']['repository'])
PY
chown "$CONFIG_MANAGER_RUNTIME_USER:$CONFIG_MANAGER_RUNTIME_GROUP" "$FILE"
chmod 0640 "$FILE"
