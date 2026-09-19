#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/baseline-repository/SOURCES/configure-observability-client.sh"
SPEC="$ROOT/baseline-repository/SPECS/client-baseline.spec"
BOOT="$ROOT/bin/forgejo-bootstrap-teko.sh"
grep -q 'Version:        1.2.8' "$SPEC"
grep -q 'ALLOY_USER="$(resolve_unit_value User)"' "$CFG"
grep -q '\[\[ -n "$ALLOY_USER" \]\] || ALLOY_USER="alloy"' "$CFG"
grep -q 'getent passwd "$ALLOY_USER"' "$CFG"
grep -q 'systemctl reset-failed alloy.service' "$CFG"
grep -q 'ensure_alloy_service_account' "$BOOT"
grep -q '\[\[ -n "$au" \]\] || au="alloy"' "$BOOT"
# RPM must no longer restart Alloy during transaction; runtime belongs to install.sh.
! grep -q '^%systemd_post alloy.service' "$SPEC"
! grep -q '^%systemd_postun_with_restart alloy.service' "$SPEC"
echo 'PASS alloy service account 3.18.9'
