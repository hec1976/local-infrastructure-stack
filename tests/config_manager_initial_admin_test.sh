#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail=0
check(){ if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
check 'Greenfield username admin' "grep -q 'ADMIN_USER=\"admin\"' '$ROOT/setup_config_manager.sh'"
check 'Greenfield initial password admin' "grep -q 'ADMIN_PASSWORD=\\\"admin\\\"' '$ROOT/setup_config_manager.sh'"
check 'Weak bootstrap is explicit and scoped' "grep -q 'CM_BOOTSTRAP_ALLOW_WEAK=1' '$ROOT/setup_config_manager.sh' && grep -q \"username === 'admin'\" '$ROOT/config-manager-standalone/standalone/create_user.php'"
check 'Bootstrap user marked must-change' "grep -q \"'must_change_password' => getenv('CM_FORCE_PASSWORD_CHANGE') === '1'\" '$ROOT/config-manager-standalone/standalone/create_user.php'"
check 'Login redirects forced change' "grep -q \"standalone_must_change_password\" '$ROOT/config-manager-standalone/public/login.php' && grep -q \"password_change.php?required=1\" '$ROOT/config-manager-standalone/public/login.php'"
check 'Protected pages blocked until change' "grep -q \"standalone_must_change_password\" '$ROOT/config-manager-standalone/standalone/auth.php' && grep -q \"password_change.php?required=1\" '$ROOT/config-manager-standalone/standalone/auth.php'"
check 'Password change clears persisted flag' "grep -q \"must_change_password.*false\" '$ROOT/config-manager-standalone/public/password_change.php'"
check 'Password change clears session flag' "grep -q \"standalone_must_change_password.*false\" '$ROOT/config-manager-standalone/public/password_change.php'"
check 'New password remains minimum 12 chars' "grep -q \"strlen(\\\$new1) < 12\" '$ROOT/config-manager-standalone/public/password_change.php'"
check 'Existing users remain untouched' "grep -q 'ohne --force werden Benutzer und Passwoerter nicht angetastet' '$ROOT/setup_config_manager.sh'"
exit "$fail"
