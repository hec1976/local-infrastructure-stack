#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
S="$ROOT/bin/teko-access-summary.sh"
M="$ROOT/setup_teko_local.sh"
C="$ROOT/setup_config_manager.sh"
CONF="$ROOT/teko-stack.conf"
[[ -x "$S" ]]
grep -q 'Config Manager:' "$S"
grep -q 'Forgejo:' "$S"
grep -q 'Grafana:' "$S"
grep -q 'Config-Agent API:' "$S"
grep -q 'Loki (lokal):' "$S"
grep -q 'Monit (lokal):' "$S"
grep -q 'Monit Exporter:' "$S"
grep -q -- '--show-secrets' "$S"
grep -q -- '--show-secrets' "$M"
grep -q 'CONFIG_MANAGER_ADMIN_ENV_FILE' "$CONF"
grep -q 'CONFIG_MANAGER_ADMIN_PASSWORD' "$C"
grep -q 'chmod 0600' "$C"
echo 'PASS: access summary v2.9.4'
