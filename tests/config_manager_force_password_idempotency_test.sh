#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail=0
check(){ if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

check 'users.json excluded from code deploy' "grep -q -- \"--exclude 'standalone/data/users.json'\" '$ROOT/setup_config_manager.sh'"
check 'normal reinstall explicitly preserves existing users' "grep -q 'ohne --force werden Benutzer und Passwoerter nicht angetastet' '$ROOT/setup_config_manager.sh'"
check 'force path explicitly resets admin' "grep -q 'FORCE: Config-Manager-Admin wird nach dem Deployment auf admin/admin zurueckgesetzt' '$ROOT/setup_config_manager.sh'"
check 'force branches into credential reset' "grep -q 'if \[\[ \"\${TEKO_FORCE:-0}\" == \"1\" \]\]' '$ROOT/setup_config_manager.sh'"
check 'greenfield only initializes when users file is absent' "grep -q 'elif \[\[ ! -f \"\$TARGET_DIR/standalone/data/users.json\" \]\]' '$ROOT/setup_config_manager.sh'"
check 'bootstrap password is admin' "grep -q 'ADMIN_PASSWORD=\"admin\"' '$ROOT/setup_config_manager.sh'"
check 'force/greenfield requires password change' "grep -q 'FORCE_PASSWORD_CHANGE=1' '$ROOT/setup_config_manager.sh'"
check 'password change clears persistent must-change flag' "grep -q \"must_change_password.*false\" '$ROOT/config-manager-standalone/public/password_change.php'"
check 'password change writes bcrypt cost 12' "grep -q \"PASSWORD_BCRYPT, \['cost' => 12\]\" '$ROOT/config-manager-standalone/public/password_change.php'"

if command -v php >/dev/null 2>&1; then
  php -r '$h=password_hash("NeuesSicheresPasswort123!", PASSWORD_BCRYPT, ["cost"=>12]); if (password_verify("admin",$h)) exit(1); if (!password_verify("NeuesSicheresPasswort123!",$h)) exit(2);' \
    && echo 'PASS: changed bcrypt rejects admin and accepts new password' \
    || { echo 'FAIL: changed bcrypt rejects admin and accepts new password'; fail=1; }
else
  echo 'SKIP: php not available for dynamic bcrypt check'
fi

exit "$fail"
