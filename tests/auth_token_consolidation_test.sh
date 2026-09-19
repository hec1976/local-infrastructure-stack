#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
S="$ROOT/bin/teko-sync-auth.sh"
[[ -x "$S" ]]
grep -q 'CONFIG_AGENT_API_TOKEN' "$S"
grep -q 'CONFIG_MANAGER_API_TOKEN' "$S"
grep -q 'X-API-Token:' "$S"
grep -q '/git_deployments' "$S"
grep -q 'Forgejo-Token darf NICHT identisch' "$S"
grep -q 'teko-sync-auth.sh' "$ROOT/setup_teko_local.sh"

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/env" "$t/cm"
TOKEN='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
FORGE='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
printf 'CONFIG_AGENT_API_TOKEN=%s\n' "$TOKEN" > "$t/env/config-agent.env"
printf 'CONFIG_MANAGER_API_TOKEN=OLD_TOKEN_THAT_MUST_BE_REPLACED_123456789\nX=1\n' > "$t/cm/config-manager.env"
printf '%s' "$FORGE" > "$t/env/forgejo-api.token"
TEKO_AGENT_ENV="$t/env/config-agent.env" \
TEKO_AGENT_TOKEN_HANDOFF="$t/env/.config-agent-token" \
TEKO_MANAGER_ENV="$t/cm/config-manager.env" \
TEKO_MANAGER_TOKEN_DIR="$t/cm/tokens" \
TEKO_MANAGER_LOCAL_TOKEN_FILE="$t/cm/tokens/local.token" \
TEKO_MANAGER_REGISTRY="$t/cm/servers.json" \
TEKO_MANAGER_WEB_GROUP=root \
TEKO_FORGEJO_TOKEN_FILE="$t/env/forgejo-api.token" \
TEKO_TOKEN_SYNC_NO_RESTART=1 TEKO_TOKEN_SYNC_NO_LIVE_TEST=1 \
  "$S" >/dev/null
[[ "$(sed -n 's/^CONFIG_MANAGER_API_TOKEN=//p' "$t/cm/config-manager.env")" == "$TOKEN" ]]
[[ "$(cat "$t/env/.config-agent-token")" == "$TOKEN" ]]
[[ "$(cat "$t/cm/tokens/local.token")" == "$TOKEN" ]]
[[ "$(grep -c '^CONFIG_MANAGER_API_TOKEN=' "$t/cm/config-manager.env")" == 1 ]]
echo 'PASS: auth token consolidation v2.4.1'
