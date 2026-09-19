#!/bin/bash
set -euo pipefail
PROFILE="${STACK_PROFILE_FILE:-/etc/local-infrastructure-stack.conf}"

valid_host(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$1" != *..* ]]; }
valid_short(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
prompt(){ local label="$1" def="$2" v; printf '%-22s [%s]: ' "$label" "$def" >&2; read -r v; printf '%s' "${v:-$def}"; }

[[ "${1:-}" == "--configure" ]] || { echo "Verwendung: $0 --configure" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

# Bestehende Werte als Vorschlag, sonst Paketdefaults.
SERVER_SHORTNAME="${SERVER_SHORTNAME:-teko}"
SERVER_FQDN="${SERVER_FQDN:-teko.local}"
FORGEJO_FQDN="${FORGEJO_FQDN:-git.local}"
CONFIG_MANAGER_FQDN="${CONFIG_MANAGER_FQDN:-config-manager.local}"
GRAFANA_FQDN="${GRAFANA_FQDN:-grafana.local}"
CONFIG_AGENT_PORT="${CONFIG_AGENT_PORT:-5008}"

while :; do SERVER_SHORTNAME="$(prompt 'Server-Hostname' "$SERVER_SHORTNAME")"; valid_short "$SERVER_SHORTNAME" && break; echo "Ungueltiger Hostname." >&2; done
while :; do SERVER_FQDN="$(prompt 'Server-FQDN' "$SERVER_FQDN")"; valid_host "$SERVER_FQDN" && break; echo "Ungueltiger FQDN (ohne https:// und Pfad)." >&2; done
while :; do FORGEJO_FQDN="$(prompt 'Forgejo-FQDN' "$FORGEJO_FQDN")"; valid_host "$FORGEJO_FQDN" && break; echo "Ungueltiger FQDN." >&2; done
while :; do CONFIG_MANAGER_FQDN="$(prompt 'Config-Manager-FQDN' "$CONFIG_MANAGER_FQDN")"; valid_host "$CONFIG_MANAGER_FQDN" && break; echo "Ungueltiger FQDN." >&2; done
while :; do GRAFANA_FQDN="$(prompt 'Grafana-FQDN' "$GRAFANA_FQDN")"; valid_host "$GRAFANA_FQDN" && break; echo "Ungueltiger FQDN." >&2; done
while :; do CONFIG_AGENT_PORT="$(prompt 'Config-Agent-Port' "$CONFIG_AGENT_PORT")"; valid_port "$CONFIG_AGENT_PORT" && break; echo "Port muss 1-65535 sein." >&2; done

# Die drei Web-FQDNs muessen eindeutig sein, damit Apache-VHosts eindeutig bleiben.
if [[ "$FORGEJO_FQDN" == "$CONFIG_MANAGER_FQDN" || "$FORGEJO_FQDN" == "$GRAFANA_FQDN" || "$CONFIG_MANAGER_FQDN" == "$GRAFANA_FQDN" ]]; then
    echo "FEHLER: Forgejo, Config Manager und Grafana benoetigen unterschiedliche FQDNs." >&2
    exit 2
fi

tmp="$(mktemp "${PROFILE}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<CFG
# Local Infrastructure Stack - setup profile
# Automatisch erzeugt. Nur root darf diese Datei aendern.
SERVER_SHORTNAME='${SERVER_SHORTNAME}'
SERVER_FQDN='${SERVER_FQDN}'
FORGEJO_FQDN='${FORGEJO_FQDN}'
CONFIG_MANAGER_FQDN='${CONFIG_MANAGER_FQDN}'
GRAFANA_FQDN='${GRAFANA_FQDN}'
CONFIG_AGENT_PORT='${CONFIG_AGENT_PORT}'
CFG
install -o root -g root -m 0600 "$tmp" "$PROFILE"
rm -f "$tmp"; trap - EXIT

echo
echo "Gespeichert: $PROFILE"
printf '%-16s %s / %s\n' 'Server:' "$SERVER_SHORTNAME" "$SERVER_FQDN"
printf '%-16s https://%s/\n' 'Forgejo:' "$FORGEJO_FQDN"
printf '%-16s https://%s/\n' 'Config Manager:' "$CONFIG_MANAGER_FQDN"
printf '%-16s https://127.0.0.1:%s\n' 'Config Agent:' "$CONFIG_AGENT_PORT"
printf '%-16s https://%s/\n' 'Grafana:' "$GRAFANA_FQDN"
