#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CM="$ROOT/setup_config_manager.sh"
TM="$ROOT/bin/teko-agent-token-manager.py"
grep -Fq '"$SCRIPT_ROOT/teko-stack.conf" "$REPAIR_TMP_DIR/teko-agent-bundle/"' "$CM"
grep -Fq 'teko-agent-bundle/teko-stack.conf' "$CM"
grep -Fq 'setup_remote_config_agent.sh setup_config_agent.sh teko-stack.conf config-agent/VERSION' "$TM"
echo 'remote_agent_repair_bundle_completeness_test: PASS'
