#!/bin/bash
# Regressionstest 3.18.16: Firewall-Verwaltung Portal <-> Agent
# Deckt die vier Fehlerbilder ab, die in 3.18.15 zu nicht anwendbaren oder
# nicht loeschbaren Firewall-Regeln gefuehrt haben.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FW="$ROOT/config-agent/lib/Firewall.pm"
SVC="$ROOT/config-manager-standalone/Service/ConfigManagerService.php"
REPO="$ROOT/config-manager-standalone/Repository/ConfigManagerRepository.php"
CTRL="$ROOT/config-manager-standalone/Controller/ConfigManagerController.php"
UI="$ROOT/config-manager-standalone/public/firewall.php"
CA="$ROOT/setup_config_agent.sh"
CM="$ROOT/setup_config_manager.sh"
RA="$ROOT/setup_remote_config_agent.sh"

fail(){ echo "FAIL: $1" >&2; exit 1; }

# 1) Regeltyp source_port muss durch alle Schichten freigegeben sein.
grep -q "'port','service','source','source_port','rich_rule'" "$SVC" \
  || fail "source_port fehlt in der Service-Whitelist"
grep -q "source_port" "$UI" || fail "source_port fehlt in der GUI"
grep -q "source_port|rich_rule" "$FW" || fail "source_port fehlt im Agenten"
grep -q "sub _fw_plan_change" "$FW" || fail "Regelplanung fehlt"

# 2) Portbereiche muessen erlaubt sein, aufsteigend und im gueltigen Bereich.
grep -q "sub _fw_check_port_spec" "$FW" || fail "gemeinsame Portpruefung fehlt"
grep -q 'Portbereich muss aufsteigend sein' "$FW" || fail "Bereichsvalidierung fehlt"
grep -q '\[1-9\]\\d{0,4})(?:-(\[1-9\]\\d{0,4}))?' "$FW" || fail "Bereichs-Regex fehlt"

# 3) Regelaenderungen muessen firewalld bei Bedarf starten.
grep -q "sub _fw_ensure_running" "$FW" || fail "_fw_ensure_running fehlt"
grep -q "_fw_ensure_running()" "$FW" || fail "Regelpfad stellt firewalld nicht sicher"
grep -q "ALREADY_ENABLED" "$FW" || fail "ALREADY_ENABLED wird nicht toleriert"
grep -q "NOT_ENABLED" "$FW" || fail "NOT_ENABLED wird nicht toleriert"

# 4) Dienststeuerung als eigener Endpunkt, inklusive Portal-Anbindung und Audit.
grep -q "post '/firewall/service'" "$FW" || fail "Endpunkt /firewall/service fehlt"
grep -q "controlFirewallService" "$SVC" || fail "Service-Methode fehlt"
grep -q "controlFirewallService" "$REPO" || fail "Repository-Methode fehlt"
grep -q "firewall_service" "$CTRL" || fail "Audit-Eintrag firewall_service fehlt"
grep -q "svcStart" "$UI" || fail "Dienst-Buttons fehlen in der GUI"

# 5) Alle Zonen statt nur der aktiven, plus Drift-Erkennung.
grep -q -- "--list-all-zones" "$FW" || fail "Zonenliste nutzt weiterhin nur aktive Zonen"
grep -q "sub _fw_parse_zones" "$FW" || fail "Zonenparser fehlt"
grep -q "sub _fw_zone_drift" "$FW" || fail "Drift-Erkennung fehlt"
grep -q "default_zone" "$FW" || fail "Standardzone wird nicht gemeldet"

# 6) Pflicht-Scopes werden bei Bestandsagenten nachgezogen.
grep -q "MERGED_TOKEN_SCOPES" "$CA" || fail "Scope-Merge fehlt"
grep -q "REQUIRED_TOKEN_SCOPES" "$CA" || fail "Pflicht-Scopes nicht definiert"

# 7) Trust-Anchor fail closed in Bundle-Bau und Remote-Repair.
grep -q "Ohne dieses Zertifikat kann kein gueltiges Agent-Repair-Bundle gebaut werden" "$CM" \
  || fail "Bundle-Bau ohne Zertifikat bricht nicht ab"
grep -q "FEHLER: Repair/Enrollment-Bundle enthaelt keinen Config-Manager Trust-Anchor" "$RA" \
  || fail "Remote-Repair meldet fehlenden Trust-Anchor weiterhin nur als Warnung"

echo PASS
