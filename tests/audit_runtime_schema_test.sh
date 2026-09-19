#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$ROOT/config-manager-standalone/standalone/audit.php"
if ! php -r 'exit(in_array("sqlite", PDO::getAvailableDrivers(), true) ? 0 : 1);'; then
  grep -q "ALTER TABLE audit_log ADD COLUMN" "$AUDIT"
  grep -q "data_json" "$AUDIT"
  grep -q "parse_url" "$AUDIT"
  echo "audit_runtime_schema_test: PASS (static fallback; pdo_sqlite not installed in build container)"
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LOG_DB_PATH="$TMP/audit.sqlite"
php -d display_errors=1 -r '
require $argv[1];
$_SESSION["standalone_user"]="tester";
$_SERVER["REMOTE_ADDR"]="192.0.2.15";
$_SERVER["REQUEST_URI"]="/index.php?action=restart&token=DO_NOT_LOG";
ensure_log_schema();
if (!mmbb_audit_write("service_restart","postfix-main",["command"=>"restart"],"test","ok")) exit(10);
$pdo=log_db();
$cols=[]; foreach($pdo->query("PRAGMA table_info(audit_log)") as $r){$cols[$r["name"]]=1;}
foreach(["ip","uri","data_json","payload"] as $c){if(empty($cols[$c])) exit(11);}
$r=$pdo->query("SELECT * FROM audit_log ORDER BY id DESC LIMIT 1")->fetch();
if($r["ip"]!=="192.0.2.15") exit(12);
if($r["uri"]!=="/index.php") exit(13);
if(strpos($r["uri"],"token")!==false) exit(14);
if($r["action"]!=="service_restart" || $r["result"]!=="ok") exit(15);
if(strpos($r["data_json"],"restart")===false) exit(16);
echo "audit_runtime_schema_test: PASS\n";
' "$AUDIT"
