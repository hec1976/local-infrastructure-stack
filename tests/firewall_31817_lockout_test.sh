#!/bin/bash
# Regressionstest 3.18.17: Lockout-Schutz, Sichtbarkeit der permanenten
# Konfiguration und Sammelanwendung von Firewall-Regeln.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FW="$ROOT/config-agent/lib/Firewall.pm"
SVC="$ROOT/config-manager-standalone/Service/ConfigManagerService.php"
REPO="$ROOT/config-manager-standalone/Repository/ConfigManagerRepository.php"
CTRL="$ROOT/config-manager-standalone/Controller/ConfigManagerController.php"
UI="$ROOT/config-manager-standalone/public/firewall.php"

fail(){ echo "FAIL: $1" >&2; exit 1; }

# 1) firewalld darf nie ohne vorherige Selbstschutzregeln gestartet werden.
grep -q "sub _fw_self_protect" "$FW" || fail "Selbstschutz fehlt"
grep -q "firewall-offline-cmd" "$FW" || fail "Offline-Pfad fehlt"
grep -q "sub _fw_agent_port" "$FW" || fail "Agent-Port wird nicht ermittelt"
python3 - "$FW" <<'PY'
import re,sys
src=open(sys.argv[1],encoding='utf-8').read()
body=src[src.index('sub _fw_ensure_running'):]
body=body[:body.index('\nsub ',1)]
prot=body.index('_fw_self_protect(')
start=body.index("'enable','--now','firewalld.service'")
if not prot < start:
    print("FAIL: firewalld wird vor dem Selbstschutz gestartet"); sys.exit(1)
if 'unless $prot->{ok}' not in body:
    print("FAIL: fehlgeschlagener Selbstschutz bricht den Start nicht ab"); sys.exit(1)
PY

# 2) Aussperrschutz beim Entfernen von Agent-Port und ssh.
grep -q "wuerde den Management-Zugang zu diesem Host entfernen" "$FW" \
  || fail "Aussperrschutz fehlt"
grep -q "confirm_lockout" "$FW" || fail "Bestaetigungspfad fehlt im Agenten"
grep -q "confirm_lockout" "$REPO" || fail "Bestaetigungspfad fehlt im Repository"

# 3) Permanente Konfiguration bei gestopptem Dienst.
grep -q "config_source" "$FW" || fail "Herkunft der Konfiguration wird nicht gemeldet"
grep -q "config_source" "$UI" || fail "GUI kennzeichnet die Herkunft nicht"
grep -q '\$source=.permanent.' "$FW" || fail "permanenter Lesepfad fehlt"

# 4) Sammelanwendung mit Vorabvalidierung und einem Reload.
grep -q "sub _fw_changes" "$FW" || fail "Sammelanwendung fehlt im Agenten"
grep -q "post '/firewall/changes'" "$FW" || fail "Endpunkt /firewall/changes fehlt"
grep -q "changeFirewallRules" "$SVC" || fail "Service-Methode fehlt"
grep -q "changeFirewallRules" "$REPO" || fail "Repository-Methode fehlt"
grep -q "firewall_rules" "$CTRL" || fail "Audit-Eintrag firewall_rules fehlt"
grep -q "stageApply" "$UI" || fail "Vormerkliste fehlt in der GUI"
python3 - "$FW" <<'PY'
import sys
src=open(sys.argv[1],encoding='utf-8').read()
body=src[src.index('sub _fw_changes'):]
body=body[:body.index('\nsub ',1)]
if body.count("'--reload'")!=1:
    print("FAIL: Sammelanwendung reloadet nicht genau einmal"); sys.exit(1)
if body.index('map { _fw_plan_change') > body.index('_fw_ensure_running'):
    print("FAIL: Validierung laeuft nicht vor der Ausfuehrung"); sys.exit(1)
PY

# 5) Duplikaterkennung in der Oberflaeche.
grep -q "function alreadySet" "$UI" || fail "Duplikaterkennung fehlt"
grep -q "Bereits in Zone" "$UI" || fail "Hinweis auf bestehende Regel fehlt"

echo PASS
