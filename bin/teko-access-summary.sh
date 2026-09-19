#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck disable=SC1090
source "$STACK_ROOT/teko-stack.conf"

SHOW_SECRETS="${TEKO_SHOW_SECRETS:-0}"
case "${1:-}" in
  --show-secrets) SHOW_SECRETS=1 ;;
  "") ;;
  *) echo "Verwendung: $0 [--show-secrets]" >&2; exit 2 ;;
esac

[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

CM_CRED="${CONFIG_MANAGER_ADMIN_ENV_FILE:-/opt/service/env/config-manager-admin.env}"
FORGEJO_CRED="${FORGEJO_ADMIN_ENV_FILE:-/opt/service/env/forgejo-admin.env}"
GRAFANA_CRED="/opt/service/env/grafana.env"
AGENT_ENV="/opt/service/env/config-agent.env"
FORGEJO_TOKEN="/opt/service/env/forgejo-api.token"
AUDIT_TOKEN="/opt/service/env/loki-export.token"

read_var() {
  local file="$1" key="$2"
  [[ -r "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | tail -n1
}

secret_or_file() {
  local file="$1" key="$2" value=""
  if [[ "$SHOW_SECRETS" == "1" ]]; then
    value="$(read_var "$file" "$key" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then printf '%s' "$value"; else printf '%s' '<nicht gespeichert/verfuegbar>'; fi
  else
    if [[ -r "$file" ]]; then printf 'gespeichert in %s' "$file"; else printf '%s' '<nicht gespeichert/verfuegbar>'; fi
  fi
}


config_manager_password() {
  local value="" users_file="/srv/www/config-manager-standalone/standalone/data/users.json"
  value="$(read_var "$CM_CRED" CONFIG_MANAGER_ADMIN_PASSWORD 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    printf '%s' '<nicht gespeichert/verfuegbar>'
    return
  fi

  # Nach einer Passwortaenderung im Web-GUI ist das beim Greenfield-Setup
  # gespeicherte Klartext-Passwort absichtlich veraltet. Vor einer Ausgabe
  # deshalb gegen den aktuellen bcrypt-Hash in users.json pruefen.
  if [[ -r "$users_file" ]] && command -v php8 >/dev/null 2>&1; then
    if ! CM_CHECK_USER="${cm_user:-admin}" CM_CHECK_PASSWORD="$value" php8 -r '
      $p="/srv/www/config-manager-standalone/standalone/data/users.json";
      $u=getenv("CM_CHECK_USER"); $pw=getenv("CM_CHECK_PASSWORD");
      $j=json_decode((string)@file_get_contents($p), true);
      $h=is_array($j)&&isset($j[$u]["password_hash"])?(string)$j[$u]["password_hash"]:"";
      exit($h!=="" && password_verify($pw,$h) ? 0 : 1);
    ' >/dev/null 2>&1; then
      printf '%s' '<im Web-GUI geaendert; Klartext nicht gespeichert>'
      return
    fi
  elif [[ -r "$users_file" ]] && command -v php >/dev/null 2>&1; then
    if ! CM_CHECK_USER="${cm_user:-admin}" CM_CHECK_PASSWORD="$value" php -r '
      $p="/srv/www/config-manager-standalone/standalone/data/users.json";
      $u=getenv("CM_CHECK_USER"); $pw=getenv("CM_CHECK_PASSWORD");
      $j=json_decode((string)@file_get_contents($p), true);
      $h=is_array($j)&&isset($j[$u]["password_hash"])?(string)$j[$u]["password_hash"]:"";
      exit($h!=="" && password_verify($pw,$h) ? 0 : 1);
    ' >/dev/null 2>&1; then
      printf '%s' '<im Web-GUI geaendert; Klartext nicht gespeichert>'
      return
    fi
  fi

  if [[ "$SHOW_SECRETS" == "1" ]]; then
    printf '%s' "$value"
  else
    printf 'gespeichert in %s' "$CM_CRED"
  fi
}

token_or_file() {
  local file="$1" value=""
  if [[ "$SHOW_SECRETS" == "1" ]]; then
    [[ -r "$file" ]] && value="$(tr -d '\r\n' < "$file")"
    [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' '<nicht vorhanden>'
  else
    [[ -r "$file" ]] && printf 'gespeichert in %s' "$file" || printf '%s' '<nicht vorhanden>'
  fi
}

cm_user="$(read_var "$CM_CRED" CONFIG_MANAGER_ADMIN_USER 2>/dev/null || true)"
[[ -n "$cm_user" ]] || cm_user="admin"
forgejo_user="$(read_var "$FORGEJO_CRED" FORGEJO_ADMIN_USER 2>/dev/null || true)"
[[ -n "$forgejo_user" ]] || forgejo_user="${FORGEJO_BOOTSTRAP_ADMIN_USER:-gitadmin}"
grafana_user="$(read_var "$GRAFANA_CRED" GF_SECURITY_ADMIN_USER 2>/dev/null || true)"
[[ -n "$grafana_user" ]] || grafana_user="admin"

printf '\n%s\n' '=================================================================='
printf '%s\n' ' ZUGANGS- UND ENDPOINT-UEBERSICHT'
printf '%s\n' '=================================================================='
printf '%-20s %s\n' 'Config Manager:' "https://${CONFIG_MANAGER_FQDN}/"
printf '%-20s %s\n' '  Benutzer:' "$cm_user"
printf '%-20s %s\n' '  Passwort:' "$(config_manager_password)"
printf '%-20s %s\n' '  Passwort ändern:' "https://${CONFIG_MANAGER_FQDN}/password_change.php"
if [[ "$(config_manager_password)" == "admin" ]]; then
  printf '%-20s %s\n' '  Erstlogin:' 'admin / admin; danach Passwortaenderung Pflicht'
fi
printf '\n%-20s %s\n' 'Forgejo:' "https://${FORGEJO_FQDN}/"
printf '%-20s %s\n' '  Admin:' "$forgejo_user"
printf '%-20s %s\n' '  Passwort:' "$(secret_or_file "$FORGEJO_CRED" FORGEJO_ADMIN_PASSWORD)"
printf '%-20s %s\n' '  Service-User:' "${FORGEJO_SERVICE_USER:-svc-teko-deploy} (restricted)"
printf '%-20s %s\n' '  Service-Token:' "$(token_or_file "$FORGEJO_TOKEN")"
printf '%-20s %s\n' '  Repository:' "https://${FORGEJO_FQDN}/${FORGEJO_ORG}/${FORGEJO_REPO}.git"
printf '%-20s %s\n' '  SSH:' "${FORGEJO_FQDN}:${FORGEJO_SSH_PORT}"
printf '\n%-20s %s\n' 'Grafana:' "https://${GRAFANA_FQDN}/"
printf '%-20s %s\n' '  Benutzer:' "$grafana_user"
printf '%-20s %s\n' '  Passwort:' "$(secret_or_file "$GRAFANA_CRED" GF_SECURITY_ADMIN_PASSWORD)"
printf '\n%-20s %s\n' 'Config-Agent API:' "https://127.0.0.1:${CONFIG_AGENT_PORT}/"
printf '%-20s %s\n' '  Auth:' 'X-API-Token'
if [[ "$SHOW_SECRETS" == "1" ]]; then
  agent_token="$(read_var "$AGENT_ENV" CONFIG_AGENT_API_TOKEN 2>/dev/null || true)"
  printf '%-20s %s\n' '  Token:' "${agent_token:-<nicht vorhanden>}"
else
  printf '%-20s %s\n' '  Token:' "${AGENT_ENV} (CONFIG_AGENT_API_TOKEN)"
fi
printf '\n%-20s %s\n' 'Loki (lokal):' "http://127.0.0.1:${LOKI_HTTP_PORT}/"
printf '%-20s %s\n' '  Auth:' 'keine; nur Loopback gebunden'
printf '%-20s %s\n' '  Audit-Token:' "$(token_or_file "$AUDIT_TOKEN")"
printf '\n%-20s %s\n' 'Monit (lokal):' 'http://127.0.0.1:2812/'
printf '%-20s %s\n' '  Auth:' 'keine; nur Loopback gebunden'
printf '%-20s %s\n' 'Monit Exporter:' 'http://127.0.0.1:9108/metrics'
printf '\n%-20s %s\n' 'Apache HTTPS:' "https://${CONFIG_MANAGER_FQDN}/ | https://${FORGEJO_FQDN}/ | https://${GRAFANA_FQDN}/"
printf '%-20s %s\n' 'Postfix:' 'lokaler systemd/Postfix-Dienst; kein Web-Login'
printf '%s\n' '------------------------------------------------------------------'
printf '%-20s %s\n' 'Client hosts:' "${SERVER_IP}  ${SERVER_FQDN} ${FORGEJO_FQDN} ${CONFIG_MANAGER_FQDN} ${GRAFANA_FQDN}"
printf '%s\n' '=================================================================='
if [[ "$SHOW_SECRETS" != "1" ]]; then
  echo "Secrets werden aus Sicherheitsgruenden nicht im normalen Setup-Log ausgegeben."
  echo "Einmalig anzeigen: sudo $0 --show-secrets"
else
  echo "WARNUNG: Secrets wurden im Klartext ausgegeben. Terminal-/CI-Logs entsprechend schuetzen."
fi
printf '%s\n' '=================================================================='
