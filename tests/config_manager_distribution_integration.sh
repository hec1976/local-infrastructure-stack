#!/bin/bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
TMP="$(mktemp -d /tmp/teko-cm-distribute.XXXXXX)"
PIDS=()
cleanup(){ for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

command -v php >/dev/null
if ! php -m | grep -qi '^curl$'; then echo 'SKIP config_manager_distribution_integration: PHP curl Modul fehlt im Test-Runner'; exit 0; fi
command -v python3 >/dev/null

TOKEN='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
printf '%s\n' 'set daemon 30' 'include /etc/monit.d/*.monitrc' > "$TMP/source.txt"
printf '%s\n' 'set daemon 60' > "$TMP/target.txt"

cat > "$TMP/fake_agent.py" <<'PY'
import http.server,sys,os,json
port=int(sys.argv[1]); token=sys.argv[2]; path=sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def auth(self):
        return self.headers.get("X-API-Token","")==token
    def do_GET(self):
        if not self.auth():
            self.send_response(401); self.end_headers(); return
        if self.path == "/config/monit-teko":
            data=open(path,"rb").read()
            self.send_response(200); self.send_header("Content-Type","text/plain")
            self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data); return
        if self.path == "/":
            data=b'{"version":"2.12.1"}'
            self.send_response(200); self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data); return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        if not self.auth():
            self.send_response(401); self.end_headers(); return
        if self.path == "/config/monit-teko":
            n=int(self.headers.get("Content-Length","0")); data=self.rfile.read(n)
            with open(path,"wb") as f: f.write(data)
            out=json.dumps({"ok":1,"saved":"monit-teko"}).encode()
            self.send_response(200); self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(out))); self.end_headers(); self.wfile.write(out); return
        self.send_response(404); self.end_headers()
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(("127.0.0.1",port),H).serve_forever()
PY

python3 "$TMP/fake_agent.py" 18110 "$TOKEN" "$TMP/source.txt" >"$TMP/source.log" 2>&1 & PIDS+=("$!")
python3 "$TMP/fake_agent.py" 18111 "$TOKEN" "$TMP/target.txt" >"$TMP/target.log" 2>&1 & PIDS+=("$!")
sleep .4

cat > "$TMP/test.php" <<'PHP'
<?php
// Standalone-Bootstrap vollständig nachbilden: Logger/Controller erwarten
// mmbb_audit_write(), das reguläre Portalseiten über standalone/audit.php laden.
require $argv[1] . '/config-manager-standalone/standalone/audit.php';
require $argv[1] . '/config-manager-standalone/autoloader.php';
require $argv[1] . '/config-manager-standalone/Repository/ConfigManagerRepository.php';
require $argv[1] . '/config-manager-standalone/Service/ConfigManagerService.php';
require $argv[1] . '/config-manager-standalone/Controller/ConfigManagerController.php';

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;
use ConfigManager\Controller\ConfigManagerController;

$token=$argv[2];
$mk=function($url) use($token) {
  return new ConfigManagerController(new ConfigManagerService(new ConfigManagerRepository([
    'name'=>'test','url'=>$url,'token'=>$token,
    'tls'=>['verify'=>false,'verify_host'=>false,'ca_file'=>''],
    'http'=>['connect_timeout'=>2,'timeout'=>5],
    'git_deploy'=>['timeout'=>5],'git_upload'=>['timeout'=>5],
  ])));
};
$source=$mk('http://127.0.0.1:18110');
$target=$mk('http://127.0.0.1:18111');

$desired=$source->getConfigContent('monit-teko');
$before=$target->getConfigContent('monit-teko');
if (hash('sha256',$desired)===hash('sha256',$before)) throw new RuntimeException('Expected drift before distribution.');

$r=$target->saveConfig('monit-teko',$desired,$before,md5($before));
if (($r['http_code']??0)!==200) throw new RuntimeException('saveConfig failed.');

$after=$target->getConfigContent('monit-teko');
if (!hash_equals(hash('sha256',$desired),hash('sha256',$after))) {
  throw new RuntimeException('Target does not match source after distribution.');
}
echo "config_manager_distribution_integration: OK\n";
PHP

php "$TMP/test.php" "$ROOT" "$TOKEN"
