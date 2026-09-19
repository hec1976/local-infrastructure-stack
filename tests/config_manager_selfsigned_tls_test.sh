#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SETUP="$ROOT/setup_config_manager.sh"
grep -q 'upsert_env_key CONFIG_MANAGER_TLS_VERIFY ' "$SETUP"
grep -q 'upsert_env_key CONFIG_MANAGER_TLS_VERIFY_HOST ' "$SETUP"
grep -q 'upsert_env_key CONFIG_MANAGER_TLS_CA_FILE ' "$SETUP"
grep -q 'TLS_VERIFY_VALUE="${CONFIG_MANAGER_TLS_VERIFY:-false}"' "$SETUP"
grep -q 'https://127.0.0.1:5008' "$SETUP"
grep -q 'srv\["tls"\] = wanted' "$SETUP"
echo "PASS config_manager_selfsigned_tls_test"
