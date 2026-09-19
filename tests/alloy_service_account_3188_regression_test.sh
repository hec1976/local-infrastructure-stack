#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/baseline-repository/SOURCES/configure-observability-client.sh"
SPEC="$ROOT/baseline-repository/SPECS/client-baseline.spec"
grep -q 'status=217/USER' "$CFG"
grep -q 'groupadd --system' "$CFG"
grep -q 'useradd --system' "$CFG"
grep -q 'install -d -o "$ALLOY_USER" -g "$ALLOY_GROUP" -m 0750 /var/lib/alloy /var/lib/alloy/data' "$CFG"
grep -q 'Version:        1.2.8' "$SPEC"
! grep -q '\[\[ -n "$ALLOY_USER" \]\] || ALLOY_USER="alloy"' "$CFG"
echo PASS
