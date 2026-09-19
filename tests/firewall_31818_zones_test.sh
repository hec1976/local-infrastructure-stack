#!/bin/bash
# Regressionstest: Backend-Zonenverwaltung, Interfaceverwaltung und Agent-Kompatibilitaet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FW="$ROOT/config-agent/lib/Firewall.pm"
SVC="$ROOT/config-manager-standalone/Service/ConfigManagerService.php"
REPO="$ROOT/config-manager-standalone/Repository/ConfigManagerRepository.php"
CTRL="$ROOT/config-manager-standalone/Controller/ConfigManagerController.php"
UI="$ROOT/config-manager-standalone/public/firewall.php"
fail(){ echo "FAIL: $1" >&2; exit 1; }

grep -q "sub _fw_host_interfaces" "$FW" || fail "Interfaceliste fehlt"
grep -q -- "--change-interface" "$FW" || fail "Interfacezuordnung fehlt"
grep -q "interfaces=>_fw_host_interfaces" "$FW" || fail "Interfaces fehlen in der Statusantwort"
grep -q "zoneNicPick" "$UI" || fail "Interfacezuordnung fehlt in der GUI"

grep -q "sub _fw_zone_admin" "$FW" || fail "Zonenverwaltung fehlt"
grep -q "sub _fw_builtin_zone" "$FW" || fail "Schutz eingebauter Zonen fehlt"
grep -q "Standardzone .* kann nicht geloescht werden" "$FW" || fail "Standardzone ist nicht geschuetzt"
grep -q "post '/firewall/zone'" "$FW" || fail "Endpunkt /firewall/zone fehlt"
grep -q "administerFirewallZone" "$SVC" || fail "Service-Methode fehlt"
grep -q "administerFirewallZone" "$REPO" || fail "Repository-Methode fehlt"
grep -q "firewall_zone" "$CTRL" || fail "Audit-Eintrag firewall_zone fehlt"
grep -q "createZone" "$UI" || fail "Zonenanlage fehlt in der GUI"

grep -q "function zoneConfigured" "$UI" || fail "Zonenfilter fehlt"
grep -q "function cleanTarget" "$UI" || fail "Target-Bereinigung fehlt"
grep -q "filterAll" "$UI" || fail "Umschalter fuer Systemzonen fehlt"
grep -q "INFO?.config_source||(INFO?.service?.active?'runtime'" "$UI" || fail "fehlendes config_source wird nicht abgefangen"
php -l "$UI" >/dev/null || fail "PHP-Syntaxfehler"
echo PASS
