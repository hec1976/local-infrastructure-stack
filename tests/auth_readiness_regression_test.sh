#!/bin/bash
set -euo pipefail
F="$(cd "$(dirname "$0")/.." && pwd)/bin/teko-sync-auth.sh"
grep -q 'wait_for_agent()' "$F"
grep -q 'TEKO_AGENT_READY_TIMEOUT' "$F"
grep -q 'journalctl -u config-agent.service -n 80' "$F"
grep -q "ss -ltnp" "$F"
grep -q 'wait_for_agent || die' "$F"
echo 'AUTH READINESS REGRESSION: PASS'
