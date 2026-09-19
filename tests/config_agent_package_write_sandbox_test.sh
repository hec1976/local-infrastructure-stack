#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for unit in "$ROOT/config-agent/service/config-agent.service" "$ROOT/config-agent/service/config-agent.service.example"; do
  grep -qx 'ProtectSystem=false' "$unit"
  ! grep -qx 'ProtectSystem=true' "$unit"
  # Package/Git deployment must be able to create service accounts and let RPM
  # scriptlets manage package-owned files below /etc.
  ! grep -q '^ReadOnlyPaths=-/etc/shadow$' "$unit"
  ! grep -q '^ReadOnlyPaths=-/etc/gshadow$' "$unit"
  ! grep -q '^ReadOnlyPaths=-/etc/ssh$' "$unit"
  grep -qx 'ReadOnlyPaths=-/opt/service/env' "$unit"
  grep -qx 'ReadOnlyPaths=-/opt/service/ssl' "$unit"
done
# File API must still block sensitive paths independently of the service sandbox.
grep -q '/etc/shadow' "$ROOT/config-agent/lib/Core.pm"
grep -q '/etc/gshadow' "$ROOT/config-agent/lib/Core.pm"
grep -q '/etc/sudoers' "$ROOT/config-agent/lib/Core.pm"
grep -q '/etc/ssh' "$ROOT/config-agent/lib/Core.pm"
grep -q '/etc/ssl/private' "$ROOT/config-agent/lib/Core.pm"
echo 'config_agent_package_write_sandbox_test: PASS'
