#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/setup_teko_local.sh"
# No direct execution of ROOT shell helpers in master installer.
if grep -nE '^\s*"\$ROOT/.*\.sh"' "$S"; then
  echo "FAIL: direct helper execution remains"
  exit 1
fi
grep -q '/bin/bash "$ROOT/bin/teko-sync-auth.sh"' "$S"
grep -q 'chmod 0755 "$ROOT/bin/teko-sync-auth.sh"' "$S"
echo "PASS: master setup invokes shell helpers through /bin/bash"
