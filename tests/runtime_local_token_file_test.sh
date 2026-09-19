#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/bin/teko-sync-auth.sh"
grep -q 'MANAGER_LOCAL_TOKEN_FILE' "$S"
grep -q 'MANAGER_TOKEN_DIR=.*/opt/service/config-manager/tokens' "$S"
grep -q 'MANAGER_LOCAL_SERVER_NAME' "$S"
grep -q "srv\['token_file'\] = local_token_file" "$S"
grep -q 'Finale Authentifizierungs-Synchronisierung' "$ROOT/setup_teko_local.sh"

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/env" "$t/cm" "$t/runtime" "$t/state"
TOKEN='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
printf 'CONFIG_AGENT_API_TOKEN=%s\n' "$TOKEN" > "$t/env/config-agent.env"
printf 'CONFIG_MANAGER_API_TOKEN=OLD_OLD_OLD_OLD_OLD_OLD_OLD_1234567890\nCONFIG_MANAGER_SERVER_REGISTRY_FILE=%s\n' "$t/state/servers.json" > "$t/cm/config-manager.env"
cat > "$t/state/servers.json" <<JSON
{"schema_version":1,"servers":[{"name":"teko","url":"https://127.0.0.1:5008","token_file":"/tmp/stale.token"}]}
JSON
# Minimal runtime files copied from product
cp "$ROOT/config-manager-standalone/config/config.php" "$t/runtime/config.php"
mkdir -p "$t/standalone" "$t/lib"
cp "$ROOT/config-manager-standalone/standalone/env.php" "$t/standalone/env.php"
cp "$ROOT/config-manager-standalone/lib/config_manager_runtime.php" "$t/lib/config_manager_runtime.php"
# config.php relative env path requires expected layout
mkdir -p "$t/app/config" "$t/app/standalone" "$t/app/lib"
cp "$ROOT/config-manager-standalone/config/config.php" "$t/app/config/config.php"
cp "$ROOT/config-manager-standalone/standalone/env.php" "$t/app/standalone/env.php"
cp "$ROOT/config-manager-standalone/lib/config_manager_runtime.php" "$t/app/lib/config_manager_runtime.php"
TEKO_AGENT_ENV="$t/env/config-agent.env" \
TEKO_AGENT_TOKEN_HANDOFF="$t/env/handoff" \
TEKO_MANAGER_ENV="$t/cm/config-manager.env" \
TEKO_MANAGER_REGISTRY="$t/state/servers.json" \
TEKO_MANAGER_LOCAL_TOKEN_FILE="$t/state/tokens/teko.token" \
TEKO_MANAGER_WEB_GROUP="$(id -gn)" \
TEKO_MANAGER_CONFIG_PHP="$t/app/config/config.php" \
TEKO_MANAGER_RUNTIME_PHP="$t/app/lib/config_manager_runtime.php" \
TEKO_AGENT_URL='https://127.0.0.1:5008' \
TEKO_TOKEN_SYNC_NO_RESTART=1 TEKO_TOKEN_SYNC_NO_LIVE_TEST=1 \
/bin/bash "$S" >/tmp/teko-runtime-local-token-test.out
[[ "$(cat "$t/state/tokens/teko.token")" == "$TOKEN" ]]
python3 - "$t/state/servers.json" "$t/state/tokens/teko.token" <<'PY'
import json,sys
p,t=sys.argv[1:]
d=json.load(open(p))
s=d['servers'][0]
assert s.get('token_file')==t,s
assert 'token' not in s
PY
CONFIG_MANAGER_ENV_FILE="$t/cm/config-manager.env" php -r '
require_once $argv[2]; $s=cm_load_config_manager_servers($argv[1]); if(($s[0]["token"]??"")!==$argv[3]) exit(9);
' "$t/app/config/config.php" "$t/app/lib/config_manager_runtime.php" "$TOKEN"
echo PASS
