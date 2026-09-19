#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CM="$ROOT/setup_config_manager.sh"
RA="$ROOT/setup_remote_config_agent.sh"
CA="$ROOT/setup_config_agent.sh"
FG="$ROOT/bin/forgejo-bootstrap-teko.sh"
grep -q 'config-manager-ca.crt' "$CM"
grep -q 'infrastructure-config-manager.crt' "$RA"
grep -q 'update-ca-certificates' "$RA"
grep -q 'zypper lr -E' "$CA"
grep -q 'mr -d infrastructure-baseline' "$CA"
grep -q 'Erwartet: /etc/pki/trust/anchors/infrastructure-config-manager.crt' "$FG"
echo PASS
