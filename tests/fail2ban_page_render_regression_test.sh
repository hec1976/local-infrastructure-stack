#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUB="$ROOT/config-manager-standalone/public"
out="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$out" "$err"' EXIT
(
  cd "$PUB"
  php -d display_errors=1 -r '
    session_start();
    $_SESSION["standalone_user"]="test";
    $_SESSION["standalone_roles"]=["ConfigManager"];
    $_SESSION["standalone_must_change_password"]=false;
    $_SERVER["SCRIPT_NAME"]="/fail2ban.php";
    $_SERVER["REQUEST_METHOD"]="GET";
    include "fail2ban.php";
  '
) >"$out" 2>"$err"
if grep -qiE 'Fatal error|Failed opening required|Warning:' "$err"; then
  cat "$err" >&2
  exit 1
fi
grep -q '<title>Fail2ban</title>' "$out"
grep -q 'Jail hinzufügen' "$out"
grep -q 'Globale Einstellungen' "$out"
grep -q 'Gebannte IPs' "$out"
echo 'Fail2ban page render regression: PASS'
