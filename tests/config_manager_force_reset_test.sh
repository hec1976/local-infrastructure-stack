#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
F="$ROOT/setup_config_manager.sh"
pass=0; fail=0
check(){ if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
check 'Force explicitly resets admin' "grep -q 'Config-Manager-Admin wird nach dem Deployment auf admin/admin zurueckgesetzt' '$F'"
check 'Force activates reset path' "grep -q 'TEKO_FORCE:-0.*==.*1' '$F' && grep -q 'RESET_ADMIN=1' '$F'"
check 'Reset username fixed admin' "grep -q 'ADMIN_USER=\"admin\"' '$F'"
check 'Reset password fixed admin' "grep -q 'ADMIN_PASSWORD=\"admin\"' '$F'"
check 'Must change after reset' "grep -q 'FORCE_PASSWORD_CHANGE=1' '$F'"
check 'Weak bootstrap explicitly scoped' "grep -q 'CM_BOOTSTRAP_ALLOW_WEAK=1 CM_FORCE_PASSWORD_CHANGE=1' '$F'"
check 'Credential file updated' "grep -q 'CONFIG_MANAGER_ADMIN_PASSWORD=%s' '$F'"
check 'users.json remains rsync-excluded' "grep -Fq -- \"--exclude 'standalone/data/users.json'\" '$F'"
check 'Normal reinstall preserves credentials' "grep -q 'ohne --force werden Benutzer und Passwoerter nicht angetastet' '$F'"
check 'Old idempotency SHA guard removed' "! grep -q 'USERS_SHA_BEFORE' '$F'"

# Dynamischer Nachweis der Reset-Semantik auf einer Kopie des CLI-Helpers.
if command -v php >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/standalone/data"
  cp "$ROOT/config-manager-standalone/standalone/create_user.php" "$TMP/standalone/create_user.php"
  CM_NEW_PASSWORD='SicheresPasswortVorForce123!' php "$TMP/standalone/create_user.php" admin 'AdminPortal,ConfigManager' >/dev/null
  CM_NEW_PASSWORD='AndererBenutzerPass123!' php "$TMP/standalone/create_user.php" operator 'AdminPortal' >/dev/null
  CM_BOOTSTRAP_ALLOW_WEAK=1 CM_FORCE_PASSWORD_CHANGE=1 CM_NEW_PASSWORD='admin' php "$TMP/standalone/create_user.php" admin 'AdminPortal,ConfigManager' >/dev/null
  if USERS_FILE="$TMP/standalone/data/users.json" php -r '
    $j=json_decode(file_get_contents(getenv("USERS_FILE")),true);
    if (!isset($j["admin"],$j["operator"])) exit(1);
    if (!password_verify("admin",$j["admin"]["password_hash"])) exit(2);
    if (password_verify("SicheresPasswortVorForce123!",$j["admin"]["password_hash"])) exit(3);
    if (($j["admin"]["must_change_password"]??false)!==true) exit(4);
    if (!password_verify("AndererBenutzerPass123!",$j["operator"]["password_hash"])) exit(5);
  '; then
    echo 'PASS: dynamic force reset -> admin/admin, other users retained'
    pass=$((pass+1))
  else
    echo 'FAIL: dynamic force reset semantics'
    fail=$((fail+1))
  fi
fi

echo "Result: $pass PASS / $fail FAIL"
[[ $fail -eq 0 ]]
