#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SB="${TEKO_TEST_DIR:-$(mktemp -d /tmp/teko-stack-test.XXXXXX)}"
KEEP="${TEKO_TEST_KEEP:-0}"
PASS=0
SKIP=0

cleanup() {
  if [[ "$KEEP" != "1" ]]; then rm -rf "$SB"; else echo "Sandbox behalten: $SB"; fi
}
trap cleanup EXIT

ok(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
skip(){ echo "[SKIP] $*"; SKIP=$((SKIP+1)); }
fail(){ echo "[FAIL] $*" >&2; exit 1; }

mkdir -p "$SB"

echo "=== TEKO Stack Sandbox Test ==="
echo "Root: $ROOT"
echo "Sandbox: $SB"

# 1. Syntax ---------------------------------------------------------------
while IFS= read -r -d '' f; do
  bash -n "$f" || fail "Shell syntax: $f"
done < <(find "$ROOT" -type f -name '*.sh' -print0)
ok "Alle Shell-Skripte syntaktisch gueltig"

if command -v php >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    php -l "$f" >/dev/null || fail "PHP syntax: $f"
  done < <(find "$ROOT/config-manager-standalone" -type f -name '*.php' -print0)
  ok "Alle PHP-Dateien syntaktisch gueltig"
else
  skip "PHP nicht vorhanden"
fi

python3 -m py_compile "$ROOT/observability/loki-importer.py"
ok "Loki Importer Python-Syntax"

python3 - "$ROOT" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
files=list(root.rglob('*.json.example')) + [root/'observability/grafana/dashboards/teko-config-manager-audit.json']
for p in files:
    json.loads(p.read_text(encoding='utf-8'))
print(len(files))
PY
ok "JSON-Beispiele und Dashboard gueltig"

# 2. IP detection ---------------------------------------------------------
AUTO_IP="$(SERVER_IP=auto bash -c 'source "$1/teko-stack.conf"; printf "%s" "$SERVER_IP"' _ "$ROOT")"
python3 - "$AUTO_IP" <<'PY'
import ipaddress,sys
ipaddress.IPv4Address(sys.argv[1])
PY
ok "Automatische IPv4-Erkennung: $AUTO_IP"

OVERRIDE="$(SERVER_IP=192.0.2.20 bash -c 'source "$1/teko-stack.conf"; printf "%s" "$SERVER_IP"' _ "$ROOT")"
[[ "$OVERRIDE" == "192.0.2.20" ]] || fail "SERVER_IP Override"
ok "Expliziter SERVER_IP Override"

# 3. hosts file sandbox ---------------------------------------------------
mkdir -p "$SB/etc"
cat > "$SB/etc/hosts" <<'H'
127.0.0.1 localhost
127.0.1.1 teko
192.168.121.99 git.local git
192.168.121.88 config-manager.local config-manager
192.168.121.77 grafana.local grafana
10.0.0.1 unrelated.local unrelated
H
SERVER_IP=192.0.2.20 TEKO_TEST_MODE=1 TEKO_HOSTS_FILE="$SB/etc/hosts" TEKO_SKIP_HOSTNAMECTL=1 \
  "$ROOT/bin/teko-hosts.sh" >/dev/null

grep -qx '127.0.0.1 localhost' "$SB/etc/hosts" || fail "localhost verloren"
grep -qx '10.0.0.1 unrelated.local unrelated' "$SB/etc/hosts" || fail "unrelated host verloren"
EXPECTED='192.0.2.20  teko.local teko git.local git config-manager.local config-manager grafana.local grafana'
grep -qx "$EXPECTED" "$SB/etc/hosts" || fail "managed hosts line falsch"
[[ "$(grep -Ec 'teko.local|git.local|config-manager.local|grafana.local' "$SB/etc/hosts")" -eq 1 ]] || fail "alte Host-Zeilen nicht bereinigt"
compgen -G "$SB/etc/hosts.bak.*" >/dev/null || fail "hosts backup fehlt"
ok "Hosts-Update ist atomar/konsistent und erhaelt fremde Eintraege"

HOSTS_HASH_1="$(sha256sum "$SB/etc/hosts" | awk '{print $1}')"
SERVER_IP=192.0.2.20 TEKO_TEST_MODE=1 TEKO_HOSTS_FILE="$SB/etc/hosts" TEKO_SKIP_HOSTNAMECTL=1 \
  "$ROOT/bin/teko-hosts.sh" >/dev/null
HOSTS_HASH_2="$(sha256sum "$SB/etc/hosts" | awk '{print $1}')"
[[ "$HOSTS_HASH_1" == "$HOSTS_HASH_2" ]] || fail "hosts update is not idempotent"
ok "Hosts-Update ist idempotent"


# 4. Apache listen.conf sandbox ------------------------------------------
mkdir -p "$SB/apache/conf.d"
cat > "$SB/apache/listen.conf" <<'A'
Listen 80
<IfDefine SSL>
    <IfModule mod_ssl.c>
        Listen 443
    </IfModule>
</IfDefine>
A
SERVER_IP=192.0.2.20 TEKO_TEST_MODE=1 TEKO_APACHE_ETC_DIR="$SB/apache" TEKO_SKIP_APACHE_SERVICE=1 \
  "$ROOT/bin/teko-apache-https.sh" >/dev/null
[[ "$(grep -Ec '^[[:space:]]*Listen[[:space:]]+443([[:space:]]|$)' "$SB/apache/listen.conf")" -eq 1 ]] || fail "unconditional Listen 443 fehlt/dupliziert"
grep -q '# Listen 443 (TEKO: unconditional listener below)' "$SB/apache/listen.conf" || fail "IfDefine Listen 443 nicht deaktiviert"
grep -qx 'ServerName teko.local' "$SB/apache/conf.d/teko-servername.conf" || fail "global ServerName"
compgen -G "$SB/apache/listen.conf.bak.*" >/dev/null || fail "listen.conf backup fehlt"
ok "openSUSE Apache Listen-443-Transformation"

APACHE_HASH_1="$(sha256sum "$SB/apache/listen.conf" | awk '{print $1}')"
SERVER_IP=192.0.2.20 TEKO_TEST_MODE=1 TEKO_APACHE_ETC_DIR="$SB/apache" TEKO_SKIP_APACHE_SERVICE=1 \
  "$ROOT/bin/teko-apache-https.sh" >/dev/null
APACHE_HASH_2="$(sha256sum "$SB/apache/listen.conf" | awk '{print $1}')"
[[ "$APACHE_HASH_1" == "$APACHE_HASH_2" ]] || fail "Apache listen transform is not idempotent"
[[ "$(grep -Ec '^[[:space:]]*Listen[[:space:]]+443([[:space:]]|$)' "$SB/apache/listen.conf")" -eq 1 ]] || fail "Listen 443 duplicate after second run"
ok "Apache Listen-443-Transformation ist idempotent"


# 5. Static integration assertions --------------------------------------
grep -q 'GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:13.2.0}"' "$ROOT/teko-stack.conf" || fail "Grafana image"
grep -q 'PublishPort=127.0.0.1:${LOKI_HTTP_PORT}:3100' "$ROOT/setup_observability.sh" || fail "Loki bind not localhost"
grep -q 'PublishPort=127.0.0.1:${GRAFANA_HTTP_PORT}:3000' "$ROOT/setup_observability.sh" || fail "Grafana bind not localhost"
grep -q 'Volume=${GRAFANA_PROVISIONING}:/etc/grafana/provisioning:ro' "$ROOT/setup_observability.sh" || fail "Grafana provisioning volume"
grep -q 'Volume=${GRAFANA_DASHBOARDS}:/var/lib/grafana/dashboards:ro' "$ROOT/setup_observability.sh" || fail "Grafana dashboard volume"
grep -q 'Require local' "$ROOT/setup_config_manager.sh" || fail "Audit REST local restriction"
grep -q 'token_file.*forgejo-api.token' "$ROOT/config-agent/example/global.json.example" || fail "Forgejo token file"
! grep -Rqs 'git.internal.local:3000' "$ROOT/config-agent/example" || fail "stale Forgejo URL in active examples"
ok "Statische Ein-Server-Integration (Ports, Volumes, URLs, REST-Schutz)"

# 5b. Postfix/Monit/Managed-Config integration ---------------------------
grep -q 'zypper --non-interactive install postfix monit' "$ROOT/setup_postfix_monit.sh" || fail "Postfix/Monit package install missing"
grep -q 'systemctl enable postfix.service' "$ROOT/setup_postfix_monit.sh" || fail "Postfix not enabled"
grep -q 'systemctl enable monit.service' "$ROOT/setup_postfix_monit.sh" || fail "Monit not enabled"
grep -q 'inet_interfaces = loopback-only' "$ROOT/setup_postfix_monit.sh" || fail "Postfix not loopback-only"
grep -q 'reject_unauth_destination' "$ROOT/setup_postfix_monit.sh" || fail "Postfix relay protection missing"
grep -q 'postconf -h setgid_group' "$ROOT/setup_postfix_monit.sh" || fail "Postfix SUSE setgid_group preservation missing"
grep -q 'postconf -e' "$ROOT/setup_postfix_monit.sh" || fail "Postfix incremental config missing"
! grep -q '^cat > /etc/postfix/main.cf <<EOF' "$ROOT/setup_postfix_monit.sh" || fail "Postfix main.cf must not be replaced wholesale"
grep -q 'main.cf.teko-original' "$ROOT/setup_postfix_monit.sh" || fail "Postfix original restore path missing"
grep -q 'systemctl restart grafana.service' "$ROOT/setup_observability.sh" || fail "Grafana controlled restart missing"
grep -q 'wait_http "Grafana"' "$ROOT/setup_observability.sh" || fail "Grafana health wait missing"
grep -q 'journalctl -u grafana.service -n 120' "$ROOT/setup_observability.sh" || fail "Grafana failure diagnostics missing"
grep -q 'MONIT_STACK="$MONIT_DIR/teko-stack.monitrc"' "$ROOT/setup_postfix_monit.sh" || fail "Single Monit stack file missing"
grep -q 'include /etc/monit.d/\*.monitrc' "$ROOT/setup_postfix_monit.sh" || fail "Monit include missing"
grep -q 'MONIT_TMPFILES="/etc/tmpfiles.d/teko-monit.conf"' "$ROOT/setup_postfix_monit.sh" || fail "Monit tmpfiles rule missing"
grep -q 'd /run/monit 0755 root root -' "$ROOT/setup_postfix_monit.sh" || fail "Monit runtime directory rule missing"
grep -q 'systemd-tmpfiles --create' "$ROOT/setup_postfix_monit.sh" || fail "Monit runtime directory not created through tmpfiles"
grep -q 'install -d -o root -g root -m 0755 /run/monit' "$ROOT/setup_postfix_monit.sh" || fail "Monit immediate runtime directory creation missing"

python3 - "$ROOT/config-agent/example/managed_configs.json.example" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
required={
 "config-agent-global","config-agent-git-deploy",
 "apache-listen","apache-config-manager-vhost","apache-forgejo-vhost","apache-grafana-vhost",
 "postfix-main","postfix-master","monit-teko-stack",
 "loki-config","grafana-loki-datasource","grafana-dashboard-provider"
}
assert required.issubset(d), sorted(required-set(d))
assert d["monit-teko-stack"]["path"] == "/etc/monit.d/teko-stack.monitrc"
assert d["postfix-main"]["path"] == "/etc/postfix/main.cf"
assert d["postfix-master"]["path"] == "/etc/postfix/master.cf"
PY
ok "Postfix/Monit und zentraler Managed-Config-Katalog konsistent"



# 5c. Fresh-install and web-security assertions --------------------------
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json,sys,re
r=Path(sys.argv[1])

agent=(r/"setup_config_agent.sh").read_text()
assert "./_install.sh --no-start" in agent
assert agent.index("./_install.sh --no-start") < agent.index('CURRENT_SECRET="$(')
assert agent.index('CURRENT_API_TOKEN="$(') < agent.index("systemctl restart config-agent.service")
assert "systemctl enable config-agent.service" in agent

g=json.loads((r/"config-agent/example/global.json.example").read_text())
assert g["listen"] == "127.0.0.1:5008"
assert g["allowed_ips"] == ["192.168.121.20/32", "127.0.0.1/32"]

mgr=(r/"setup_config_manager.sh").read_text()
http=mgr.split("<VirtualHost *:80>",1)[1].split("</VirtualHost>",1)[0]
assert "Redirect permanent / https://${CONFIG_MANAGER_FQDN}/" in http
assert "DocumentRoot" not in http
assert 'chown -R "root:$APACHE_GROUP" "$TARGET_DIR"' in mgr
assert 'chown -R "$APACHE_USER:$APACHE_GROUP" "$TARGET_DIR/standalone/data"' in mgr

boot=(r/"config-manager-standalone/standalone/bootstrap.php").read_text()
login=(r/"config-manager-standalone/public/login.php").read_text()
nav=(r/"config-manager-standalone/standalone/layout/navigation.php").read_text()
for text in (boot, login):
    for setting in ("session.use_strict_mode","session.use_only_cookies","session.cookie_httponly","session.cookie_secure","session.cookie_samesite"):
        assert setting in text
assert "str_starts_with($redirect, '//')" in login
assert "isset($_POST['logout'])" in login
assert 'name="csrf_token"' in nav and 'name="logout"' in nav
assert "login.php?logout=1" not in nav

master=(r/"setup_teko_local.sh").read_text()
assert '"$ROOT/bin/teko-health.sh" || true' not in master
assert '"$ROOT/bin/teko-postinstall-test.sh"' in master
posttest=(r/"bin/teko-postinstall-test.sh").read_text()
for required in (
    "Audit REST ohne Token -> 401",
    "Config Manager -> Config-Agent API/Token",
    "PHP pdo_sqlite Modul",
    "Postfix inet_interfaces=loopback-only",
    "PHP Session Cookie: Secure + HttpOnly + SameSite=Strict",
):
    assert required in posttest
PY
ok "Fresh-Install-Reihenfolge und Web-Security-Härtung"

if command -v node >/dev/null 2>&1; then
  for t in "$ROOT"/config-manager-standalone/tests/*.js; do
    node "$t" >/dev/null || fail "Node UI-Test: $t"
  done
  ok "Alle mitgelieferten Config-Manager UI/Logic-Tests"
else
  skip "Node fehlt für UI/Logic-Tests"
fi

# 6. Audit REST auth behavior --------------------------------------------
if command -v php >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  TOKEN='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  mkdir -p "$SB/rest"
  cat > "$SB/rest/config-manager.env" <<E
CONFIG_MANAGER_LOKI_EXPORT_TOKEN=$TOKEN
LOG_DB_PATH=$SB/rest/audit.sqlite
E
  CONFIG_MANAGER_ENV_FILE="$SB/rest/config-manager.env" php -S 127.0.0.1:18080 -t "$ROOT/config-manager-standalone/public" >"$SB/rest/php.log" 2>&1 &
  PHP_PID=$!
  sleep .3
  STATUS="$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:18080/api/audit_export.php?after_id=0&limit=10' || true)"
  kill "$PHP_PID" 2>/dev/null || true
  wait "$PHP_PID" 2>/dev/null || true
  [[ "$STATUS" == "401" ]] || fail "Audit REST unauth expected 401, got $STATUS"
  ok "Audit REST verweigert Request ohne Bearer Token (401)"
else
  skip "PHP/curl fehlen fuer REST-Auth-Test"
fi

# 7. Real SQLite -> PHP REST if pdo_sqlite available ---------------------
if command -v php >/dev/null 2>&1 && php -m | grep -qi '^pdo_sqlite$'; then
  TOKEN='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  mkdir -p "$SB/sqlite"
  cat > "$SB/sqlite/config-manager.env" <<E
CONFIG_MANAGER_LOKI_EXPORT_TOKEN=$TOKEN
LOG_DB_PATH=$SB/sqlite/audit.sqlite
E
  CONFIG_MANAGER_ENV_FILE="$SB/sqlite/config-manager.env" php -r \
    'require $argv[1]; mmbb_audit_write("save","postfix_main",["changed"=>true],"config.save","success"); mmbb_audit_write("deploy","postfix_main",["target"=>"teko"],"deploy.run","success");' \
    "$ROOT/config-manager-standalone/standalone/audit.php"
  CONFIG_MANAGER_ENV_FILE="$SB/sqlite/config-manager.env" php -S 127.0.0.1:18081 -t "$ROOT/config-manager-standalone/public" >"$SB/sqlite/php.log" 2>&1 &
  PHP_PID=$!; sleep .3
  curl -fsS -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:18081/api/audit_export.php?after_id=0&limit=10' > "$SB/sqlite/export.json"
  kill "$PHP_PID" 2>/dev/null || true; wait "$PHP_PID" 2>/dev/null || true
  python3 - "$SB/sqlite/export.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); assert p['ok'] and p['count']==2 and p['last_id']>=2
PY
  ok "SQLite -> echter PHP Audit-REST-Endpunkt"
else
  skip "PDO SQLite im Sandbox-PHP nicht installiert (Zielsetup installiert php8-sqlite)"
fi

# 8. REST -> Loki importer functional test -------------------------------
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$SB/importer"
  TOKEN='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  printf '%s' "$TOKEN" > "$SB/importer/token"; chmod 600 "$SB/importer/token"
  cat > "$SB/importer/fake.py" <<PY
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from pathlib import Path
import json, threading, time
TOKEN='$TOKEN'
EVENTS=[
 {'id':1,'ts':'2026-08-28T12:00:00Z','module':'config-manager-standalone','user':'admin','action':'save','identity':'postfix_main','function':'config.save','result':'success','payload':'{}'},
 {'id':2,'ts':'2026-08-28T12:01:00Z','module':'config-manager-standalone','user':'admin','action':'deploy','identity':'postfix_main','function':'deploy.run','result':'success','payload':'{}'}]
class Audit(BaseHTTPRequestHandler):
 def do_GET(self):
  if self.headers.get('Authorization') != 'Bearer '+TOKEN: self.send_response(401); self.end_headers(); return
  after=int(parse_qs(urlparse(self.path).query).get('after_id',['0'])[0]); ev=[e for e in EVENTS if e['id']>after]
  b=json.dumps({'ok':True,'after_id':after,'last_id':ev[-1]['id'] if ev else after,'count':len(ev),'events':ev}).encode()
  self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
 def log_message(self,*a): pass
class Loki(BaseHTTPRequestHandler):
 def do_POST(self):
  n=int(self.headers.get('Content-Length','0')); Path('$SB/importer/push.json').write_bytes(self.rfile.read(n)); self.send_response(204); self.end_headers()
 def log_message(self,*a): pass
servers=[HTTPServer(('127.0.0.1',18082),Audit),HTTPServer(('127.0.0.1',18102),Loki)]
for s in servers: threading.Thread(target=s.serve_forever,daemon=True).start()
Path('$SB/importer/ready').write_text('1')
while True: time.sleep(1)
PY
  python3 "$SB/importer/fake.py" >"$SB/importer/fake.log" 2>&1 & FAKE_PID=$!
  for _ in $(seq 1 30); do [[ -f "$SB/importer/ready" ]] && break; sleep .1; done
  TEKO_AUDIT_EXPORT_URL='http://127.0.0.1:18082/api/audit_export.php' \
  TEKO_LOKI_PUSH_URL='http://127.0.0.1:18102/loki/api/v1/push' \
  TEKO_AUDIT_EXPORT_TOKEN_FILE="$SB/importer/token" \
  TEKO_LOKI_STATE_FILE="$SB/importer/state.json" TEKO_LOKI_ONESHOT=1 \
    python3 "$ROOT/observability/loki-importer.py" >"$SB/importer/importer.log"
  python3 - "$SB/importer/push.json" "$SB/importer/state.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); vals=sum((s['values'] for s in p['streams']),[]); assert len(vals)==2
assert all(s['stream']['job']=='config-manager-audit' for s in p['streams'])
st=json.load(open(sys.argv[2])); assert st['last_id']==2
PY
  rm -f "$SB/importer/push.json"
  TEKO_AUDIT_EXPORT_URL='http://127.0.0.1:18082/api/audit_export.php' \
  TEKO_LOKI_PUSH_URL='http://127.0.0.1:18199/loki/api/v1/push' \
  TEKO_AUDIT_EXPORT_TOKEN_FILE="$SB/importer/token" \
  TEKO_LOKI_STATE_FILE="$SB/importer/state.json" TEKO_LOKI_ONESHOT=1 \
    python3 "$ROOT/observability/loki-importer.py" >"$SB/importer/importer2.log"
  [[ ! -e "$SB/importer/push.json" ]] || fail "Importer duplicated events"
  kill "$FAKE_PID" 2>/dev/null || true; wait "$FAKE_PID" 2>/dev/null || true
  ok "REST -> Loki Push + Cursor gegen Doppelimport funktional"
else
  skip "Python fehlt fuer Importer-Test"
fi

echo

python3 "$ROOT/tests/offline_frontend_test.py" >/dev/null || fail "Offline frontend dependencies"
ok "Frontend ist vollstaendig lokal (keine CDN-/Google-Font-Laufzeitreferenzen)"

python3 "$ROOT/tests/git_deploy_feature_test.py" >/dev/null || fail "Git Deploy feature assertions"
ok "Git Deploy: Commit/Tag, Ref-Schutz, Rollback und Audit verdrahtet"

python3 "$ROOT/tests/git_deploy_hardening_test.py" >/dev/null || fail "Git Deploy hardening assertions"
ok "Git Deploy Hardening: Preview-Bindung, Integritaet, Request-Token und Fail-Closed-Validierung"

python3 "$ROOT/tests/git_upload_hardening_test.py" >/dev/null || fail "Git Upload hardening assertions"
python3 "$ROOT/tests/git_upload_empty_repo_branches_test.py" >/dev/null || fail "Git Upload empty-repository branch handling"
ok "Git Repository Integration: read-only Deploy-Browser, Upload-Trennung und sichere Symlinks"

python3 "$ROOT/tests/git_deploy_gui_backend_test.py" >/dev/null || fail "Git Deploy GUI/backend regression"
ok "Git Deploy GUI/Backend Regression"

"$ROOT/tests/git_deploy_allowed_root_regression_test.sh" >/dev/null || fail "Git Deploy allowed-roots regression"
ok "Git Deploy allowed_roots Regression"

"$ROOT/tests/git_deploy_versioned_integration.sh" >/dev/null || fail "Versioned Git deployment integration"
ok "Git Deploy Integration: v1 -> v2 mit neuem Skript -> Rollback + Tag/Ref-Pruefung"

if command -v php >/dev/null 2>&1; then
  php -d zend.assertions=1 -d assert.exception=1 "$ROOT/tests/desired_state_logic_test.php" "$ROOT" >/dev/null || fail "Desired State logic test"
  ok "Desired State: Policy-Validierung, Selektoren, Tag-Aufloesung und Compliance"

  php -d zend.assertions=1 -d assert.exception=1 "$ROOT/tests/fleet_registry_test.php" "$ROOT" >/dev/null || fail "Fleet registry test"
  ok "Fleet Registry: Multi-Server, Gruppen/Labels und per-Server Token-Datei"
else
  skip "PHP fehlt fuer Fleet/Desired-State Tests"
fi

python3 "$ROOT/tests/fleet_desired_state_feature_test.py" >/dev/null || fail "Fleet/Desired State feature assertions"
ok "Fleet / Desired State GUI, Audit, Limits und Setup verdrahtet"

python3 "$ROOT/tests/multisource_desired_state_test.py" >/dev/null || fail "Multi-source Desired State assertions"
ok "Desired State: Git + Config Manager als getrennte Quellen"

python3 "$ROOT/tests/remote_canary_feature_test.py" >/dev/null || fail "Remote Agent + Canary Rollout assertions"
ok "Remote Agent + Canary Rollout Security/GUI/Schema"

python3 "$ROOT/tests/agent_enrollment_feature_test.py" >/dev/null || fail "Agent Enrollment Manager assertions"
ok "Agent Enrollment Manager GUI/Worker/SSH-Security"

python3 "$ROOT/tests/package_management_feature_test.py" >/dev/null || fail "Package Management Suite assertions"
ok "Package Management Suite zypper/apt/dnf + Fleet GUI"


python3 "$ROOT/tests/modsecurity_feature_test.py" >/dev/null || fail "ModSecurity/OWASP CRS feature assertions"
"$ROOT/tests/modsecurity_runtime_test.sh" "$ROOT" >/dev/null || fail "ModSecurity structured config runtime"
"$ROOT/tests/modsecurity_reload_regression_test.sh" "$ROOT" >/dev/null || fail "ModSecurity reload stderr/rollback regression"
"$ROOT/tests/modsecurity_install_rollback_regression_test.sh" "$ROOT" >/dev/null || fail "ModSecurity install transaction rollback regression"
ok "ModSecurity/OWASP CRS GUI/Agent/Validation/Rollback"

python3 - "$ROOT/tests/config_manager_distribution_integration.sh" <<'PY' >/dev/null || fail "Distribution harness standalone audit bootstrap"
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
a=s.index("standalone/standalone/audit.php")
b=s.index("config-manager-standalone/autoloader.php")
assert a < b
PY
ok "Config Manager Distribution Harness Bootstrap Regression"

python3 "$ROOT/tests/monit_exporter_feature_test.py" >/dev/null || fail "Monit Go Exporter feature assertions"
ok "Monit Go Exporter: 9 Service-Typen, Security und Grafana-Dashboard"

if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/monit-exporter" && go test ./... >/dev/null) || fail "Monit Go Exporter unit tests"
  ok "Monit Go Exporter Unit Tests"
else
  skip "Go fehlt fuer Exporter Unit Tests"
fi

if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  "$ROOT/monit-exporter/test_integration.sh" >/dev/null || fail "Monit Exporter HTTP Integration"
  ok "Monit Exporter HTTP Integration mit allen 9 Typen"
else
  skip "curl/python3 fehlen fuer Exporter Integration"
fi

if command -v php >/dev/null 2>&1 && php -m | grep -qi '^curl$' && command -v python3 >/dev/null 2>&1; then
  "$ROOT/tests/config_manager_distribution_integration.sh" "$ROOT" >/dev/null || fail "Config Manager Distribution Integration"
  ok "Config Manager: Referenzdatei -> Drift -> Verteilung -> SHA-256 identisch"
else
  skip "PHP curl fehlt fuer echten Config-Manager-Verteilungstest"
fi

if python3 "$ROOT/tests/forgejo_repo_create_auth_test.py" >/dev/null; then
  ok "Forgejo Repository Create: Service-User, Token-Scope und Capability-Probe verdrahtet"
else
  fail "Forgejo Repository Create Regression"
fi

echo "=== RESULT: PASS ($PASS passed, $SKIP skipped) ==="
