#!/bin/bash
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/teko-common.sh"

[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

PASS=0
FAIL=0
SKIP=0

ok(){ printf '[PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '[FAIL] %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
skip(){ printf '[SKIP] %s\n' "$*"; SKIP=$((SKIP+1)); }

echo "============================================================"
echo " Zielsystem End-to-End Test"
echo "============================================================"

# 1. Host / names ---------------------------------------------------------
[[ "$(teko_hostname)" == "$SERVER_SHORTNAME" ]] && ok "Hostname $SERVER_SHORTNAME" || bad "Hostname $(teko_hostname), erwartet $SERVER_SHORTNAME"

for n in "$SERVER_FQDN" "$FORGEJO_FQDN" "$CONFIG_MANAGER_FQDN" "$GRAFANA_FQDN"; do
    ip="$(getent ahostsv4 "$n" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "$ip" == "$SERVER_IP" ]] && ok "$n -> $SERVER_IP" || bad "$n -> ${ip:-nicht aufgeloest}"
done

# 2. Services -------------------------------------------------------------
for svc in apache2 forgejo.service config-agent.service loki.service prometheus.service grafana.service alloy.service teko-loki-importer.service teko-apache-loki-importer.service teko-system-loki-importer.service postfix.service monit.service monit-prometheus-exporter.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then ok "$svc active"; else bad "$svc nicht active"; fi
done
for svc in apache2 config-agent.service prometheus.service alloy.service postfix.service monit.service monit-prometheus-exporter.service; do
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then ok "$svc enabled"; else bad "$svc nicht enabled"; fi
done

# 3. Internal/external port exposure -------------------------------------
check_local_only_port() {
    local port="$1" label="$2" listeners external
    listeners="$(ss -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ (p "$") {print $4}')"
    [[ -n "$listeners" ]] || { bad "$label TCP/$port lauscht nicht"; return; }
    external="$(printf '%s\n' "$listeners" | grep -Ev '^(127\.0\.0\.1|\[::1\]|::1):' || true)"
    [[ -z "$external" ]] && ok "$label TCP/$port nur loopback" || bad "$label TCP/$port extern exponiert: $external"
}

check_local_only_port "$CONFIG_AGENT_PORT" "Config-Agent"
check_local_only_port "$FORGEJO_HTTP_PORT" "Forgejo HTTP Backend"
check_local_only_port "$GRAFANA_HTTP_PORT" "Grafana Backend"
check_local_only_port "$LOKI_HTTP_PORT" "Loki"
check_local_only_port 9108 "Monit Exporter"

curl -fsS --max-time 5 http://127.0.0.1:9108/metrics | grep -q '^monit_up 1$' && ok "Monit XML -> Prometheus Exporter" || bad "Monit XML -> Prometheus Exporter"

smtp_external="$(ss -lnt 2>/dev/null | awk '$4 ~ /:25$/ {print $4}' | grep -Ev '^(127\.0\.0\.1|\[::1\]|::1):25$' || true)"
[[ -z "$smtp_external" ]] && ok "Postfix TCP/25 nicht extern exponiert" || bad "Postfix TCP/25 extern: $smtp_external"

ss -lnt 2>/dev/null | grep -qE ':443[[:space:]]' && ok "Apache TCP/443 lauscht" || bad "Apache TCP/443 fehlt"
ss -lnt 2>/dev/null | grep -qE ":${FORGEJO_SSH_PORT}[[:space:]]" && ok "Forgejo SSH TCP/${FORGEJO_SSH_PORT} lauscht" || bad "Forgejo SSH TCP/${FORGEJO_SSH_PORT} fehlt"

# 4. HTTP / HTTPS ---------------------------------------------------------
http_headers="$(curl -sSI --max-time 10 "http://${CONFIG_MANAGER_FQDN}/" 2>/dev/null || true)"
http_code="$(printf '%s\n' "$http_headers" | awk 'NR==1{print $2}')"
http_location="$(printf '%s\n' "$http_headers" | awk 'BEGIN{IGNORECASE=1} /^Location:/ {gsub("\r",""); print $2; exit}')"
if [[ "$http_code" =~ ^30[12378]$ && "$http_location" == "https://${CONFIG_MANAGER_FQDN}/" ]]; then
    ok "Config Manager HTTP -> HTTPS Redirect"
else
    bad "Config Manager HTTP Redirect: code=${http_code:-?} location=${http_location:-?}"
fi

curl -kfsS --max-time 10 "https://${CONFIG_MANAGER_FQDN}/login.php" >/dev/null 2>&1 \
    && ok "Config Manager HTTPS" || bad "Config Manager HTTPS"

curl -kfsS --max-time 10 "https://${FORGEJO_FQDN}/" >/dev/null 2>&1 \
    && ok "Forgejo HTTPS" || bad "Forgejo HTTPS"

grafana_https_ok=0
grafana_https_body=""
for _i in $(seq 1 20); do
    grafana_https_body="$(curl -kfsS --max-time 8 --resolve "${GRAFANA_FQDN}:443:127.0.0.1" \
        "https://${GRAFANA_FQDN}/api/health" 2>/dev/null || true)"
    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); raise SystemExit(0 if str(d.get("database","")).lower()=="ok" else 1)' \
        <<<"$grafana_https_body" 2>/dev/null; then
        grafana_https_ok=1
        break
    fi
    sleep 1
done
if [[ "$grafana_https_ok" == "1" ]]; then
    ok "Grafana HTTPS -> Apache/SNI/Proxy/API health"
else
    bad "Grafana HTTPS API health"
    backend_body="$(curl -fsS --max-time 5 "http://127.0.0.1:${GRAFANA_HTTP_PORT}/api/health" 2>/dev/null || true)"
    printf '      HTTPS=%s\n      Backend=%s\n' "${grafana_https_body:-leer}" "${backend_body:-leer}" >&2
fi

curl -fsS --max-time 10 "http://127.0.0.1:${LOKI_HTTP_PORT}/ready" >/dev/null 2>&1 \
    && ok "Loki ready" || bad "Loki not ready"

curl -fsS --max-time 10 "http://127.0.0.1:${PROMETHEUS_HTTP_PORT}/-/ready" >/dev/null 2>&1 \
    && ok "Prometheus ready" || bad "Prometheus not ready"

OBS_AUTH_FILE="/opt/service/config-manager/observability.htpasswd"
if [[ -s "$OBS_AUTH_FILE" ]]; then
    ok "Apache Observability Auth-Datei vorhanden"
else
    bad "Apache Observability Auth-Datei fehlt/leer"
fi
if systemctl list-unit-files observability-ingest.service >/dev/null 2>&1 && systemctl is-enabled --quiet observability-ingest.service 2>/dev/null; then
    bad "Legacy observability-ingest.service ist noch enabled"
else
    ok "Legacy observability-ingest.service entfernt/deaktiviert"
fi

if systemctl is-active --quiet alloy.service 2>/dev/null; then
    ok "Grafana Alloy active"
else
    bad "Grafana Alloy nicht active"
fi

# Importers must be running. Postfix/Monit streams only appear after a matching
# journal event, so do not falsely require a label value on a quiet fresh host.
if systemctl is-active --quiet teko-system-loki-importer.service 2>/dev/null; then
    ok "Postfix/Monit Loki importer active"
else
    bad "Postfix/Monit Loki importer nicht active"
fi

# Secure session cookie flags.
cookie_headers="$(curl -ksSI --max-time 10 "https://${CONFIG_MANAGER_FQDN}/login.php" 2>/dev/null || true)"
cookie_line="$(printf '%s\n' "$cookie_headers" | grep -i '^Set-Cookie: PHPSESSID=' | head -n1 || true)"
if [[ -n "$cookie_line" ]] \
   && grep -qi 'secure' <<<"$cookie_line" \
   && grep -qi 'httponly' <<<"$cookie_line" \
   && grep -qi 'samesite=strict' <<<"$cookie_line"; then
    ok "PHP Session Cookie: Secure + HttpOnly + SameSite=Strict"
else
    bad "PHP Session Cookie Flags unvollstaendig"
fi

# 5. Config-Agent auth ----------------------------------------------------
AGENT_ENV="/opt/service/env/config-agent.env"
if [[ -r "$AGENT_ENV" ]]; then
    agent_secret="$(sed -n 's/^CONFIG_AGENT_SECRET=//p' "$AGENT_ENV" | tail -n1)"
    agent_token="$(sed -n 's/^CONFIG_AGENT_API_TOKEN=//p' "$AGENT_ENV" | tail -n1)"
    [[ ${#agent_secret} -ge 32 ]] && ok "CONFIG_AGENT_SECRET gesetzt" || bad "CONFIG_AGENT_SECRET fehlt/zu kurz"
    [[ ${#agent_token} -ge 32 ]] && ok "CONFIG_AGENT_API_TOKEN gesetzt" || bad "CONFIG_AGENT_API_TOKEN fehlt/zu kurz"

    agent_code="$(curl -ksS -o /tmp/teko-agent-api.$$ -w '%{http_code}' \
        -H "X-API-Token: ${agent_token}" \
        --max-time 10 "https://127.0.0.1:${CONFIG_AGENT_PORT}/" || true)"
    if [[ "$agent_code" == "200" ]] && python3 - /tmp/teko-agent-api.$$ <<'PY' >/dev/null 2>&1
import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d,dict)
PY
    then
        ok "Config Manager -> Config-Agent API/Token"
    else
        bad "Config-Agent API Test HTTP ${agent_code:-?}"
    fi
    rm -f /tmp/teko-agent-api.$$

    git_code="$(curl -ksS -o /tmp/teko-git-deploy-api.$$ -w '%{http_code}' \
        -H "X-API-Token: ${agent_token}" --max-time 10 \
        "https://127.0.0.1:${CONFIG_AGENT_PORT}/git_deployments" || true)"
    if [[ "$git_code" == "200" ]] && python3 - /tmp/teko-git-deploy-api.$$ <<'PY' >/dev/null 2>&1
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") in (1, True)
assert d.get("config_valid") is True
assert d.get("degraded") is False
assert d.get("enabled") is True
profiles=d.get("profiles")
assert isinstance(profiles,list) and len(profiles)>=1
PY
    then
        ok "Git Deploy API -> 200/config_valid/enabled"
    else
        bad "Git Deploy API nicht bereit (HTTP ${git_code:-?})"
        [[ ! -s /tmp/teko-git-deploy-api.$$ ]] || sed 's/^/      /' /tmp/teko-git-deploy-api.$$ >&2
    fi
    rm -f /tmp/teko-git-deploy-api.$$

    upload_code="$(curl -ksS -o /tmp/teko-git-upload-api.$$ -w '%{http_code}' \
        -H "X-API-Token: ${agent_token}" --max-time 10 \
        "https://127.0.0.1:${CONFIG_AGENT_PORT}/git_upload/info" || true)"
    if [[ "$upload_code" == "200" ]] && python3 - /tmp/teko-git-upload-api.$$ <<'PY' >/dev/null 2>&1
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") in (1, True)
assert d.get("enabled") is True
assert d.get("valid") is True
assert d.get("degraded") is False
PY
    then
        ok "Git Repository Upload API -> 200/valid/enabled"
    else
        bad "Git Repository Upload API nicht bereit (HTTP ${upload_code:-?})"
        [[ ! -s /tmp/teko-git-upload-api.$$ ]] || sed 's/^/      /' /tmp/teko-git-upload-api.$$ >&2
    fi
    rm -f /tmp/teko-git-upload-api.$$

    monit_code="$(curl -ksS -o /tmp/teko-monit-status-api.$$ -w '%{http_code}' \
        -H "X-API-Token: ${agent_token}" --max-time 10 \
        "https://127.0.0.1:${CONFIG_AGENT_PORT}/monit/status" || true)"
    if [[ "$monit_code" == "200" ]] && python3 - /tmp/teko-monit-status-api.$$ <<'PYMON' >/dev/null 2>&1
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") in (1, True)
s=d.get("summary") or {}
assert isinstance(d.get("services"),list)
assert isinstance(s.get("total"),int) and s.get("total") >= 1
assert s.get("overall") in ("ok","warning","failed")
PYMON
    then
        ok "Monit Status API -> XML gelesen/normalisiert"
    else
        bad "Monit Status API nicht bereit (HTTP ${monit_code:-?})"
        [[ ! -s /tmp/teko-monit-status-api.$$ ]] || sed 's/^/      /' /tmp/teko-monit-status-api.$$ >&2
    fi
    rm -f /tmp/teko-monit-status-api.$$

    # Derselbe Runtime-Pfad wie die Git-Deploy-GUI: Registry -> token_file ->
    # ConfigManagerRepository -> /git_deployments. Damit reicht ein direkter
    # curl-Erfolg allein nicht mehr fuer ein erfolgreiches Gesamtsetup.
    CM_ROOT="/srv/www/config-manager-standalone"
    PHP_BIN_RUNTIME="$(command -v php8 || command -v php || true)"
    if [[ -n "$PHP_BIN_RUNTIME" && -d "$CM_ROOT" && -x "$(command -v runuser || true)" ]]; then
        runtime_probe="/tmp/teko-gui-backend-probe.$$.php"
        cat > "$runtime_probe" <<'PHP'
<?php
require_once '/srv/www/config-manager-standalone/standalone/env.php';
require_once '/srv/www/config-manager-standalone/Repository/ConfigManagerRepository.php';
require_once '/srv/www/config-manager-standalone/Service/ConfigManagerService.php';
require_once '/srv/www/config-manager-standalone/lib/config_manager_runtime.php';
use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;
try {
    $servers = cm_load_config_manager_servers('/srv/www/config-manager-standalone/config/config.php');
    if (!$servers) { throw new RuntimeException('keine Server'); }
    $svc = new ConfigManagerService(new ConfigManagerRepository($servers[0]));
    $d = $svc->getGitDeployments();
    $u = $svc->getGitUploadInfo();
    $a = $svc->getAgentOverview();
    $h = $svc->getAgentHealth();
    $deployOk = !empty($d['enabled']) && empty($d['degraded']) && (!array_key_exists('config_valid',$d) || !empty($d['config_valid']));
    $uploadOk = !empty($u['enabled']) && !empty($u['valid']) && empty($u['degraded']);
    $overviewOk = (int)($a['http_code'] ?? 0) === 200 && !empty($a['response']) && is_array($a['response']);
    $healthCode = (int)($h['http_code'] ?? 0);
    $healthOk = in_array($healthCode, [200,503], true) && is_array($h['response'] ?? null) && array_key_exists('ok', $h['response']);
    $ok = $deployOk && $uploadOk && $overviewOk && $healthOk;
    echo json_encode([
        'ok'=>$ok,
        'git_deploy'=>['enabled'=>!empty($d['enabled']),'degraded'=>!empty($d['degraded']),'config_valid'=>$d['config_valid'] ?? true],
        'git_upload'=>['enabled'=>!empty($u['enabled']),'valid'=>!empty($u['valid']),'degraded'=>!empty($u['degraded'])],
        'agent_overview'=>['http_code'=>$a['http_code'] ?? 0],
        'agent_health'=>['http_code'=>$healthCode,'ok'=>$h['response']['ok'] ?? null]
    ]);
    exit($ok ? 0 : 2);
} catch (Throwable $e) {
    fwrite(STDERR, $e->getMessage()."\n");
    exit(3);
}
PHP
        chmod 0644 "$runtime_probe"
        if runuser -u wwwrun -- "$PHP_BIN_RUNTIME" "$runtime_probe" >/tmp/teko-gui-backend.$$ 2>/tmp/teko-gui-backend.err.$$; then
            ok "Config-Manager GUI-Backend -> Git Deploy, Repository Upload + Health bereit"
        else
            bad "Config-Manager GUI-Backend Git Deploy/Repository Upload/Health nicht bereit"
            [[ ! -s /tmp/teko-gui-backend.$$ ]] || sed 's/^/      /' /tmp/teko-gui-backend.$$ >&2
            [[ ! -s /tmp/teko-gui-backend.err.$$ ]] || sed 's/^/      /' /tmp/teko-gui-backend.err.$$ >&2
        fi
        rm -f "$runtime_probe" /tmp/teko-gui-backend.$$ /tmp/teko-gui-backend.err.$$
    else
        bad "Config-Manager GUI-Backend Runtime-Test nicht ausfuehrbar"
    fi
else
    bad "$AGENT_ENV fehlt/nicht lesbar"
fi

# 6. Audit REST auth ------------------------------------------------------
audit_noauth="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 \
    "https://${CONFIG_MANAGER_FQDN}/api/audit_export.php?after_id=0&limit=1" || true)"
[[ "$audit_noauth" == "401" ]] && ok "Audit REST ohne Token -> 401" || bad "Audit REST ohne Token -> HTTP ${audit_noauth:-?}"

AUDIT_TOKEN_FILE="/opt/service/env/loki-export.token"
if [[ -r "$AUDIT_TOKEN_FILE" ]]; then
    audit_token="$(tr -d '\r\n' < "$AUDIT_TOKEN_FILE")"
    [[ ${#audit_token} -ge 32 ]] && ok "Audit Export Token gesetzt" || bad "Audit Export Token fehlt/zu kurz"
    audit_code="$(curl -ksS -o /tmp/teko-audit-api.$$ -w '%{http_code}' \
        -H "Authorization: Bearer ${audit_token}" --max-time 10 \
        "https://${CONFIG_MANAGER_FQDN}/api/audit_export.php?after_id=0&limit=1" || true)"
    if [[ "$audit_code" == "200" ]] && python3 - /tmp/teko-audit-api.$$ <<'PY' >/dev/null 2>&1
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True
assert isinstance(d.get("events"),list)
PY
    then
        ok "Audit REST mit Bearer Token -> 200/JSON"
    else
        bad "Audit REST mit Token -> HTTP ${audit_code:-?}"
    fi
    rm -f /tmp/teko-audit-api.$$
else
    bad "$AUDIT_TOKEN_FILE fehlt/nicht lesbar"
fi

# 7. PHP modules ----------------------------------------------------------
PHP_BIN="$(command -v php8 || command -v php || true)"
if [[ -n "$PHP_BIN" ]]; then
    modules="$("$PHP_BIN" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    grep -qx 'curl' <<<"$modules" && ok "PHP curl Modul" || bad "PHP curl Modul fehlt"
    grep -qx 'pdo_sqlite' <<<"$modules" && ok "PHP pdo_sqlite Modul" || bad "PHP pdo_sqlite Modul fehlt"
    grep -qx 'openssl' <<<"$modules" && ok "PHP openssl Modul" || bad "PHP openssl Modul fehlt"
else
    bad "PHP CLI fehlt"
fi

# 8. Postfix / Monit ------------------------------------------------------
if command -v postfix >/dev/null 2>&1; then
    postfix check >/dev/null 2>&1 && ok "postfix check" || bad "postfix check"
    [[ "$(postconf -h inet_interfaces 2>/dev/null)" == "loopback-only" ]] \
        && ok "Postfix inet_interfaces=loopback-only" || bad "Postfix inet_interfaces nicht loopback-only"
    postconf -h smtpd_relay_restrictions 2>/dev/null | grep -q 'reject_unauth_destination' \
        && ok "Postfix reject_unauth_destination" || bad "Postfix relay restriction fehlt"
else
    bad "postfix Kommando fehlt"
fi

if command -v monit >/dev/null 2>&1; then
    monit -t >/dev/null 2>&1 && ok "monit -t" || bad "monit -t"
    [[ -f /etc/monit.d/teko-stack.monitrc ]] && ok "Eine TEKO Monit Policy vorhanden" || bad "TEKO Monit Policy fehlt"
else
    bad "monit Kommando fehlt"
fi

# 9. Permissions / ownership ---------------------------------------------
check_mode() {
    local file="$1" expected="$2" label="$3"
    if [[ -e "$file" ]]; then
        mode="$(stat -c '%a' "$file" 2>/dev/null)"
        [[ "$mode" == "$expected" ]] && ok "$label mode $expected" || bad "$label mode $mode, erwartet $expected"
    else
        bad "$label fehlt: $file"
    fi
}
check_owner() {
    local file="$1" expected="$2" label="$3"
    if [[ -e "$file" ]]; then
        owner="$(stat -c '%U:%G' "$file" 2>/dev/null)"
        [[ "$owner" == "$expected" ]] && ok "$label owner $expected" || bad "$label owner $owner, erwartet $expected"
    else
        bad "$label fehlt: $file"
    fi
}

check_mode /opt/service/env/config-agent.env 600 "config-agent.env"
check_mode /opt/service/env/loki-export.token 600 "loki-export.token"
check_mode /etc/monit.d/teko-stack.monitrc 600 "teko-stack.monitrc"
[[ ! -f /opt/service/env/forgejo-api.token ]] || check_mode /opt/service/env/forgejo-api.token 600 "forgejo-api.token"

check_owner /srv/www/config-manager-standalone/public/index.php "root:www" "Config Manager Webcode"
check_owner /srv/www/config-manager-standalone/public/operations.php "root:www" "Betriebsuebersicht Webcode"
check_owner /srv/www/config-manager-standalone/standalone/data "wwwrun:www" "Config Manager data"

# 10. Managed Config catalogue -------------------------------------------
MC="/opt/service/config-agent/managed_configs.json"
if [[ -r "$MC" ]]; then
    python3 - "$MC" <<'PY' >/dev/null 2>&1
import json,sys
d=json.load(open(sys.argv[1]))
required={
 "config-agent-global","config-agent-git-deploy",
 "apache-listen","apache-config-manager-vhost","apache-forgejo-vhost","apache-grafana-vhost",
 "postfix-main","postfix-master","monit-teko-stack",
 "loki-config","grafana-loki-datasource","grafana-dashboard-provider"
}
assert required.issubset(d)
assert d["monit-teko-stack"]["path"] == "/etc/monit.d/teko-stack.monitrc"
assert d["postfix-main"]["path"] == "/etc/postfix/main.cf"
assert d["postfix-master"]["path"] == "/etc/postfix/master.cf"
PY
    [[ $? -eq 0 ]] && ok "Managed Config Katalog vollstaendig" || bad "Managed Config Katalog unvollstaendig"
else
    bad "$MC fehlt/nicht lesbar"
fi


# 10b. Fleet / Desired State ---------------------------------------------
REGISTRY="/opt/service/config-manager/servers.json"
DESIRED="/srv/www/config-manager-standalone/standalone/data/desired_state.json"
if [[ -r "$REGISTRY" ]]; then
    python3 - "$REGISTRY" <<'PY' >/dev/null 2>&1
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("schema_version")==1 and isinstance(d.get("servers"),list) and len(d["servers"])>=1
for s in d["servers"]:
    assert isinstance(s.get("name"),str) and s["name"]
    assert isinstance(s.get("url"),str) and s["url"].startswith("https://")
PY
    [[ $? -eq 0 ]] && ok "Fleet Registry gueltig" || bad "Fleet Registry ungueltig"
    check_owner "$REGISTRY" "root:www" "Fleet Registry"
    check_mode "$REGISTRY" 640 "Fleet Registry"
else
    bad "$REGISTRY fehlt/nicht lesbar"
fi

if [[ -r "$DESIRED" ]]; then
    python3 - "$DESIRED" <<'PY' >/dev/null 2>&1
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("schema_version")==1 and isinstance(d.get("policies"),dict)
PY
    [[ $? -eq 0 ]] && ok "Desired State JSON gueltig" || bad "Desired State JSON ungueltig"
    check_owner "$DESIRED" "wwwrun:www" "Desired State"
    check_mode "$DESIRED" 640 "Desired State"
else
    bad "$DESIRED fehlt/nicht lesbar"
fi

curl -kfsS --max-time 10 "https://${CONFIG_MANAGER_FQDN}/desired_state.php" >/dev/null 2>&1 \
    && ok "Fleet / Desired State HTTPS" || bad "Fleet / Desired State HTTPS"

# 11. Agent certificate SAN ----------------------------------------------
CERT="/opt/service/ssl/agent.local.crt"
if [[ -r "$CERT" ]]; then
    san="$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null || true)"
    grep -q "IP Address:127.0.0.1" <<<"$san" && ok "Agent Zertifikat SAN 127.0.0.1" || bad "Agent Zertifikat SAN 127.0.0.1 fehlt"
    grep -q "DNS:${SERVER_FQDN}" <<<"$san" && ok "Agent Zertifikat SAN ${SERVER_FQDN}" || bad "Agent Zertifikat SAN ${SERVER_FQDN} fehlt"
else
    bad "Agent Zertifikat fehlt"
fi

echo
echo "============================================================"
echo " RESULT: ${PASS} PASS / ${FAIL} FAIL / ${SKIP} SKIP"
echo "============================================================"

[[ "$FAIL" -eq 0 ]]
