#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
S="$ROOT/setup_config_manager.sh"
grep -q 'LOCAL_AGENT_TOKEN_FILE=' "$S"
grep -q 'CURRENT_MANAGER_TOKEN=' "$S"
grep -q 'chmod 0640 "$LOCAL_TOKEN_TMP"' "$S"
grep -q 'chown root:"$APACHE_GROUP" "$LOCAL_TOKEN_TMP"' "$S"
grep -q 'Lokaler Runtime-Token synchronisiert' "$S"
echo 'config_manager_local_token_setup_test: PASS'
