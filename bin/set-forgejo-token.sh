#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/teko-common.sh"

[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

TOKEN="${FORGEJO_API_TOKEN:-${1:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "Verwendung:" >&2
  echo "  sudo FORGEJO_API_TOKEN='<token>' $0" >&2
  echo "oder:" >&2
  echo "  sudo $0 '<token>'" >&2
  exit 2
fi

TOKEN="${TOKEN//$'\r'/}"
TOKEN="${TOKEN//$'\n'/}"
[[ ${#TOKEN} -ge 20 ]] || { echo "Forgejo-Token erscheint zu kurz." >&2; exit 1; }

install -d -o root -g root -m 0700 /opt/service/env
TMP="$(mktemp /opt/service/env/forgejo-api.token.tmp.XXXXXX)"
printf '%s' "$TOKEN" > "$TMP"
chown root:root "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" /opt/service/env/forgejo-api.token

FP="$(printf '%s' "$TOKEN" | sha256sum | awk '{print substr($1,1,12)}')"
echo "Forgejo API-Token installiert: /opt/service/env/forgejo-api.token"
echo "Fingerprint: $FP"

if systemctl is-active --quiet config-agent.service 2>/dev/null; then
  systemctl restart config-agent.service
  echo "Config-Agent neu gestartet."
fi
