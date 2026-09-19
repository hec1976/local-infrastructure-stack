#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/teko-common.sh"

fail=0
ok(){ printf '[OK]   %s\n' "$*"; }
bad(){ printf '[FAIL] %s\n' "$*"; fail=1; }
info(){ printf '[INFO] %s\n' "$*"; }

[[ "$(teko_hostname)" == "$SERVER_SHORTNAME" ]] && ok "Hostname $SERVER_SHORTNAME" || bad "Hostname ist $(teko_hostname), erwartet $SERVER_SHORTNAME"

for n in "$SERVER_FQDN" "$FORGEJO_FQDN" "$CONFIG_MANAGER_FQDN" "$GRAFANA_FQDN"; do
  ip="$(getent ahostsv4 "$n" 2>/dev/null | awk 'NR==1{print $1}')"
  [[ "$ip" == "$SERVER_IP" ]] && ok "$n -> $SERVER_IP" || bad "$n -> ${ip:-NICHT AUFGELOEST}"
done

for svc in apache2 forgejo.service config-agent.service; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then ok "$svc active"; else bad "$svc nicht active"; fi
done

ss -lnt 2>/dev/null | grep -qE ':443[[:space:]]' && ok "TCP/443 lauscht" || bad "TCP/443 lauscht nicht"
ss -lnt 2>/dev/null | grep -qE ":${CONFIG_AGENT_PORT}[[:space:]]" && ok "Agent TCP/${CONFIG_AGENT_PORT} lauscht" || bad "Agent TCP/${CONFIG_AGENT_PORT} lauscht nicht"
agent_ext="$(ss -lnt 2>/dev/null | awk -v p=":${CONFIG_AGENT_PORT}" '$4 ~ (p "$") {print $4}' | grep -Ev '^(127\.0\.0\.1|\[::1\]|::1):' || true)"
[[ -z "$agent_ext" ]] && ok "Agent TCP/${CONFIG_AGENT_PORT} nur loopback" || bad "Agent TCP/${CONFIG_AGENT_PORT} extern: $agent_ext"
ss -lnt 2>/dev/null | grep -qE ':2222[[:space:]]' && ok "Forgejo SSH TCP/2222 lauscht" || info "Forgejo SSH/2222 noch nicht erreichbar"

curl -kfsS --max-time 5 "https://${CONFIG_MANAGER_FQDN}/" >/dev/null 2>&1 && ok "Config Manager HTTPS" || bad "Config Manager HTTPS fehlgeschlagen"
curl -kfsS --max-time 5 "https://${FORGEJO_FQDN}/" >/dev/null 2>&1 && ok "Forgejo HTTPS" || bad "Forgejo HTTPS fehlgeschlagen"

if [[ -f /opt/service/env/config-agent.env ]]; then
  mode="$(stat -c '%a' /opt/service/env/config-agent.env 2>/dev/null)"
  [[ "$mode" == "600" ]] && ok "config-agent.env mode 600" || bad "config-agent.env mode ${mode:-?}"
fi

if [[ -f /opt/service/env/forgejo-api.token ]]; then
  mode="$(stat -c '%a' /opt/service/env/forgejo-api.token 2>/dev/null)"
  [[ "$mode" == "600" ]] && ok "forgejo-api.token mode 600" || bad "forgejo-api.token mode ${mode:-?}"
else
  info "Forgejo API-Token noch nicht gesetzt (Git Upload/API bleibt degraded)."
fi


if systemctl list-unit-files 2>/dev/null | grep -q '^loki\.service'; then
  systemctl is-active --quiet loki.service && ok "loki.service active" || bad "loki.service nicht active"
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^grafana\.service'; then
  systemctl is-active --quiet grafana.service && ok "grafana.service active" || bad "grafana.service nicht active"
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^teko-loki-importer\.service'; then
  systemctl is-active --quiet teko-loki-importer.service && ok "teko-loki-importer active" || bad "teko-loki-importer nicht active"
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^teko-apache-loki-importer\.service'; then
  systemctl is-active --quiet teko-apache-loki-importer.service && ok "teko-apache-loki-importer active" || bad "teko-apache-loki-importer nicht active"
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^teko-system-loki-importer\.service'; then
  systemctl is-active --quiet teko-system-loki-importer.service && ok "teko-system-loki-importer active" || bad "teko-system-loki-importer nicht active"
fi

ss -lnt 2>/dev/null | grep -qE ":${LOKI_HTTP_PORT}[[:space:]]" && ok "Loki TCP/${LOKI_HTTP_PORT} lokal" || info "Loki noch nicht installiert"
ss -lnt 2>/dev/null | grep -qE ":${GRAFANA_HTTP_PORT}[[:space:]]" && ok "Grafana TCP/${GRAFANA_HTTP_PORT} lokal" || info "Grafana noch nicht installiert"

for internal_port in "$FORGEJO_HTTP_PORT" "$GRAFANA_HTTP_PORT" "$LOKI_HTTP_PORT"; do
  internal_ext="$(ss -lnt 2>/dev/null | awk -v p=":${internal_port}" '$4 ~ (p "$") {print $4}' | grep -Ev '^(127\.0\.0\.1|\[::1\]|::1):' || true)"
  [[ -z "$internal_ext" ]] && ok "TCP/${internal_port} nicht extern exponiert" || bad "TCP/${internal_port} extern: $internal_ext"
done

if systemctl is-active --quiet grafana.service 2>/dev/null; then
  grafana_health="$(curl -kfsS --max-time 8 --resolve "${GRAFANA_FQDN}:443:127.0.0.1" \
    "https://${GRAFANA_FQDN}/api/health" 2>/dev/null || true)"
  if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); raise SystemExit(0 if str(d.get("database","")).lower()=="ok" else 1)' <<<"$grafana_health" 2>/dev/null; then
    ok "Grafana HTTPS (Apache -> Grafana API)"
  else
    bad "Grafana HTTPS fehlgeschlagen"
    info "Backend-Test: curl http://127.0.0.1:${GRAFANA_HTTP_PORT}/api/health"
  fi
fi


if systemctl list-unit-files 2>/dev/null | grep -q '^monit-prometheus-exporter\.service'; then
  systemctl is-active --quiet monit-prometheus-exporter.service && ok "monit-prometheus-exporter active" || bad "monit-prometheus-exporter nicht active"
  curl -fsS --max-time 5 http://127.0.0.1:9108/metrics 2>/dev/null | grep -q '^monit_up 1$' && ok "Monit Prometheus metrics" || bad "Monit Prometheus metrics fehlgeschlagen"
  exporter_ext="$(ss -lnt 2>/dev/null | awk '$4 ~ /:9108$/ {print $4}' | grep -Ev '^(127\.0\.0\.1|\[::1\]|::1):9108$' || true)"
  [[ -z "$exporter_ext" ]] && ok "Monit Exporter TCP/9108 nur loopback" || bad "Monit Exporter TCP/9108 extern: $exporter_ext"

fi

if systemctl list-unit-files 2>/dev/null | grep -q '^postfix\.service'; then
  systemctl is-enabled --quiet postfix.service 2>/dev/null && ok "postfix.service enabled" || bad "postfix.service nicht enabled"
  systemctl is-active --quiet postfix.service && ok "postfix.service active" || bad "postfix.service nicht active"
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^monit\.service'; then
  systemctl is-enabled --quiet monit.service 2>/dev/null && ok "monit.service enabled" || bad "monit.service nicht enabled"
  systemctl is-active --quiet monit.service && ok "monit.service active" || bad "monit.service nicht active"
fi

if [[ -f /etc/monit.d/teko-stack.monitrc ]]; then
  [[ "$(stat -c '%a' /etc/monit.d/teko-stack.monitrc 2>/dev/null)" == "600" ]] && ok "Monit TEKO Policy mode 600" || bad "Monit TEKO Policy falsche Rechte"
  command -v monit >/dev/null 2>&1 && { monit -t >/dev/null 2>&1 && ok "Monit Syntax" || bad "Monit Syntax"; }
fi

if command -v postfix >/dev/null 2>&1; then
  postfix check >/dev/null 2>&1 && ok "Postfix Config" || bad "Postfix Config"
  ext25="$(ss -lnt 2>/dev/null | awk '$4 ~ /:25$/ {print $4}' | grep -Ev '^(127\.0\.0\.1|::1|\[::1\]):25$' || true)"
  [[ -z "$ext25" ]] && ok "Postfix TCP/25 nur loopback" || bad "Postfix TCP/25 extern: $ext25"
fi

if [[ -f /opt/service/config-agent/managed_configs.json ]]; then
  python3 - /opt/service/config-agent/managed_configs.json >/dev/null 2>&1 <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
required={
"postfix-main","postfix-master","monit-teko-stack",
"apache-listen","apache-config-manager-vhost","apache-forgejo-vhost",
"apache-grafana-vhost","loki-config","grafana-loki-datasource"
}
raise SystemExit(0 if required.issubset(d) else 1)
PY
  [[ $? -eq 0 ]] && ok "Managed-Config-Katalog TEKO vollständig" || bad "Managed-Config-Katalog unvollständig"
fi

exit "$fail"
