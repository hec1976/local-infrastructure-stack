#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROFILE="$TMP/profile.conf"
# Simulate interactive answers; helper must persist neutral, central overrides.
printf '%s\n' 'mail01' 'mail01.example.test' 'git.example.test' 'config.example.test' 'grafana.example.test' '5443' \
  | STACK_PROFILE_FILE="$PROFILE" bash "$ROOT/bin/stack-name-config.sh" --configure >/dev/null
[[ -s "$PROFILE" ]]
grep -q "SERVER_SHORTNAME='mail01'" "$PROFILE"
grep -q "SERVER_FQDN='mail01.example.test'" "$PROFILE"
grep -q "FORGEJO_FQDN='git.example.test'" "$PROFILE"
grep -q "CONFIG_MANAGER_FQDN='config.example.test'" "$PROFILE"
grep -q "GRAFANA_FQDN='grafana.example.test'" "$PROFILE"
grep -q "CONFIG_AGENT_PORT='5443'" "$PROFILE"
mode="$(stat -c '%a' "$PROFILE")"
[[ "$mode" == "600" ]]
# teko-stack.conf must consume the profile as single source for all children.
out="$(STACK_PROFILE_FILE="$PROFILE" bash -c 'source "$1/teko-stack.conf"; printf "%s|%s|%s|%s|%s|%s" "$SERVER_SHORTNAME" "$SERVER_FQDN" "$FORGEJO_FQDN" "$CONFIG_MANAGER_FQDN" "$GRAFANA_FQDN" "$CONFIG_AGENT_PORT"' _ "$ROOT")"
[[ "$out" == 'mail01|mail01.example.test|git.example.test|config.example.test|grafana.example.test|5443' ]]
echo 'setup_fqdn_profile_test: PASS'
