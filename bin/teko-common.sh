#!/bin/bash
# Shared helpers for the TEKO single-server stack.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STACK_CONF="${TEKO_STACK_CONF:-$STACK_ROOT/teko-stack.conf}"

[[ -f "$STACK_CONF" ]] || { echo "TEKO config fehlt: $STACK_CONF" >&2; exit 1; }
# shellcheck disable=SC1090
source "$STACK_CONF"

: "${SERVER_IP:?SERVER_IP fehlt}"
: "${SERVER_SHORTNAME:?SERVER_SHORTNAME fehlt}"
: "${SERVER_FQDN:?SERVER_FQDN fehlt}"
: "${FORGEJO_FQDN:?FORGEJO_FQDN fehlt}"
: "${CONFIG_MANAGER_FQDN:?CONFIG_MANAGER_FQDN fehlt}"
: "${CONFIG_AGENT_PORT:?CONFIG_AGENT_PORT fehlt}"

# Return the current host name without requiring the legacy `hostname` binary.
# util-linux/systemd installations may not ship /usr/bin/hostname.
teko_hostname() {
  local h=""
  if command -v hostname >/dev/null 2>&1; then
    h="$(hostname 2>/dev/null || true)"
  fi
  if [[ -z "$h" && -r /proc/sys/kernel/hostname ]]; then
    IFS= read -r h < /proc/sys/kernel/hostname || true
  fi
  if [[ -z "$h" && -r /etc/hostname ]]; then
    IFS= read -r h < /etc/hostname || true
  fi
  if [[ -z "$h" ]]; then
    h="$(uname -n 2>/dev/null || true)"
  fi
  printf '%s\n' "$h"
}
