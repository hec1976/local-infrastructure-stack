#!/bin/bash
# Regressionstest: Zone bleibt direkt verwaltbar; eingebaute Zonen werden geschuetzt.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
UI="$ROOT/config-manager-standalone/public/firewall.php"
FW="$ROOT/config-agent/lib/Firewall.pm"
fail(){ echo "FAIL: $1" >&2; exit 1; }

grep -q "sub _fw_host_interfaces" "$FW" || fail "Interfaceliste fehlt"
grep -q -- "--change-interface" "$FW" || fail "Interface kann nicht verschoben werden"
grep -q "zoneNicAdd" "$UI" || fail "Interface-Zuweisung fehlt"
grep -q "data-selected-nic-remove" "$UI" || fail "Interface kann nicht entfernt werden"
grep -q "filterConfigured" "$UI" || fail "Filter fuer verwendete Zonen fehlt"
grep -q "filterAll" "$UI" || fail "Filter fuer alle Systemzonen fehlt"
grep -q "Systemzone" "$UI" || fail "Systemzonen sind nicht gekennzeichnet"
grep -q "data-zone-del" "$UI" || fail "eigene Zonen koennen nicht geloescht werden"
php -l "$UI" >/dev/null || fail "PHP-Syntaxfehler"
echo PASS
