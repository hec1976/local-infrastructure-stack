#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/bin/teko-sync-auth.sh"
grep -q 'MANAGER_REGISTRY' "$S"
grep -q 'token_file' "$S"
grep -q 'cm_load_config_manager_servers' "$S"
grep -q 'Runtime Token Fingerprint' "$S"
echo 'PASS auth runtime registry override v2.4.3'
