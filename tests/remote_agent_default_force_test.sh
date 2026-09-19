#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RS="$ROOT/setup_remote_config_agent.sh"
WK="$ROOT/bin/teko-agent-enrollment-worker.py"
TM="$ROOT/bin/teko-agent-token-manager.py"
SM="$ROOT/config-manager-standalone/public/server_management.php"
grep -q 'out={"config-agent-global": e}' "$RS"
grep -q 'REMOTE_PROFILE_RESET' "$RS"
grep -q 'CONFIG_AGENT_REMOTE_PROFILE_RESET":"1"' "$WK"
grep -q "force=bool(req.get('force',False))" "$TM"
grep -q 'TEKO_FORCE=__FORCE__' "$TM"
grep -q 'CONFIG_AGENT_REMOTE_PROFILE_RESET=__PROFILE_RESET__' "$TM"
grep -q 'Agent Lifecycle' "$SM"
grep -q "mode==='reset'" "$SM"
grep -q "req\['force'\]" "$SM"
echo 'remote_agent_default_force_test: PASS'
