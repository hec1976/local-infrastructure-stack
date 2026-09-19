#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/teko-common.sh"

[[ $EUID -eq 0 || "${TEKO_TEST_MODE:-0}" == "1" ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

HOSTS_FILE="${TEKO_HOSTS_FILE:-/etc/hosts}"
HOSTNAMECTL_BIN="${TEKO_HOSTNAMECTL_BIN:-hostnamectl}"

if [[ "${TEKO_SKIP_HOSTNAMECTL:-0}" != "1" ]]; then
  "$HOSTNAMECTL_BIN" set-hostname "$SERVER_SHORTNAME"
fi

BACKUP="${HOSTS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$HOSTS_FILE" "$BACKUP"

TMP="$(mktemp "${HOSTS_FILE}.tmp.XXXXXX")"
awk '
  !($0 ~ /(^|[[:space:]])teko([[:space:]]|$)/) &&
  !($0 ~ /(^|[[:space:]])teko\.local([[:space:]]|$)/) &&
  !($0 ~ /(^|[[:space:]])git([[:space:]]|$)/) &&
  !($0 ~ /(^|[[:space:]])git\.local([[:space:]]|$)/) &&
  !($0 ~ /(^|[[:space:]])config-manager([[:space:]]|$)/) &&
  !($0 ~ /(^|[[:space:]])config-manager\.local([[:space:]]|$)/) &&
  !($0 ~ /(^|[[:space:]])grafana([[:space:]]|$)/) &&
  !($0 ~ /(^|[[:space:]])grafana\.local([[:space:]]|$)/)
' "$HOSTS_FILE" > "$TMP"

printf '%s  %s %s %s git %s config-manager %s grafana\n' \
  "$SERVER_IP" "$SERVER_FQDN" "$SERVER_SHORTNAME" \
  "$FORGEJO_FQDN" "$CONFIG_MANAGER_FQDN" "$GRAFANA_FQDN" >> "$TMP"

chown --reference="$HOSTS_FILE" "$TMP"
chmod --reference="$HOSTS_FILE" "$TMP"
mv -f "$TMP" "$HOSTS_FILE"

echo "Hostname: $(teko_hostname)"
echo "$HOSTS_FILE:"
grep -E "(^|[[:space:]])(${SERVER_SHORTNAME}|${SERVER_FQDN}|${FORGEJO_FQDN}|${CONFIG_MANAGER_FQDN}|${GRAFANA_FQDN})([[:space:]]|$)" "$HOSTS_FILE" || true
echo "Backup: $BACKUP"
