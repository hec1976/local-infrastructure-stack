#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail=0
check(){ if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
check 'Greenfield admin secret file' "grep -q 'CONFIG_MANAGER_ADMIN_PASSWORD' '$ROOT/setup_config_manager.sh'"
check 'Greenfield password defined' "grep -q 'ADMIN_PASSWORD=\"admin\"' '$ROOT/setup_config_manager.sh'"
check 'Final setup shows secrets by default' "grep -q '^SHOW_SECRETS=1' '$ROOT/setup_teko_local.sh'"
check 'Optional hide-secrets switch' "grep -q -- '--hide-secrets' '$ROOT/setup_teko_local.sh'"
check 'Password change page present' "test -f '$ROOT/config-manager-standalone/public/password_change.php'"
check 'Current password verified' "grep -q 'password_verify(.*current' '$ROOT/config-manager-standalone/public/password_change.php'"
check 'New password bcrypt cost 12' "grep -q \"PASSWORD_BCRYPT, \['cost' => 12\]\" '$ROOT/config-manager-standalone/public/password_change.php'"
check 'Password change audited' "grep -q \"mmbb_audit_write('password_change'\" '$ROOT/config-manager-standalone/public/password_change.php'"
check 'Password page in navigation' "grep -q '\"href\": \"password_change\"' '$ROOT/config-manager-standalone/config/module_navigation.json'"
check 'Topbar password shortcut' "grep -q 'password_change.php' '$ROOT/config-manager-standalone/standalone/layout/navigation.php'"
exit "$fail"
