#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="$ROOT/config-agent/service/config-agent.service"
CORE="$ROOT/config-agent/lib/Core.pm"
# Regression: observability-client/install.sh executes as a child of config-agent.
# useradd must not see /etc/shadow as read-only in that mount namespace.
if grep -Eq '^ReadOnlyPaths=-/etc/(shadow|gshadow|passwd|group)$' "$UNIT"; then
  echo 'FAIL: account database still read-only in deploy executor sandbox' >&2
  exit 1
fi
# But direct file-manager/file API access remains denied.
for p in /etc/shadow /etc/gshadow /etc/sudoers /etc/ssh /etc/ssl/private; do
  grep -Fq "$p" "$CORE" || { echo "FAIL: missing hard-protected path $p" >&2; exit 1; }
done
echo 'deploy_service_account_31810_regression_test: PASS'
