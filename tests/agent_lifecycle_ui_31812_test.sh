#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/config-manager-standalone/public/server_management.php"
grep -q 'Agent Lifecycle' "$F"
grep -q 'id="lcUpdate"' "$F"
grep -q 'id="lcRepair"' "$F"
grep -q 'id="lcReset"' "$F"
grep -q "lifecycleAction('reset')" "$F"
grep -q "mode.*reset" "$F"
! grep -q 'id="tmForce"' "$F"
! grep -q 'id="tmRepair"' "$F"
echo 'agent_lifecycle_ui_31812_test: PASS'
