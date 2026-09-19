#!/usr/bin/env bash
set -euo pipefail
F="$(cd "$(dirname "$0")/.." && pwd)/config-manager-standalone/public/modsecurity.php"
grep -q 'Erweitert: Bulk-Ausnahmen' "$F"
grep -q 'Im Normalfall Regeln direkt im Tab' "$F"
! grep -q '<label class="form-label">Globale Rule-Ausnahmen</label>' "$F"
grep -q 'id="ids"' "$F"
grep -q 'SecRuleRemoveById' "$(cd "$(dirname "$0")/.." && pwd)/config-agent/lib/ModSecurity.pm"
echo "[PASS] Globale Rule-Ausnahmen aus Hauptansicht entfernt; Bulk-Funktion bleibt unter Erweitert"
