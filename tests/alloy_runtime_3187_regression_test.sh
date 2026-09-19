#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CFG="$ROOT/baseline-repository/SOURCES/configure-observability-client.sh"
SPEC="$ROOT/baseline-repository/SPECS/client-baseline.spec"
grep -q 'systemctl show -p "\$key" --value alloy.service' "$CFG"
grep -q 'chown root:root "\$ALLOY_CONFIG"' "$CFG"
grep -q 'chmod 0644 "\$ALLOY_CONFIG"' "$CFG"
! grep -q 'runuser -u "\$ALLOY_USER"' "$CFG"
grep -q 'alloy validate "\$ALLOY_TMP"' "$CFG"
grep -q 'systemctl restart alloy.service' "$CFG"
grep -q 'alloy.service aktiv und stabil' "$CFG"
grep -q 'Version:        1.2.8' "$SPEC"
! grep -q '^%{_libexecdir}/client-baseline/configure-observability-client || :$' "$SPEC"
echo PASS
