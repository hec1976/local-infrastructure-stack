#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
TMP="$(mktemp -d /tmp/monit-prometheus-exporter-auth-test.XXXXXX)"
PIDS=()
cleanup(){ for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
USER_NAME='monitadmin'
PASSWORD='123456789123456'
cat > "$TMP/mock.py" <<'PY'
import base64,http.server,sys,pathlib
port=int(sys.argv[1]); xml=pathlib.Path(sys.argv[2]).read_bytes(); user=sys.argv[3]; pw=sys.argv[4]
want='Basic '+base64.b64encode((user+':'+pw).encode()).decode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get('Authorization') != want:
            self.send_response(401); self.send_header('WWW-Authenticate','Basic realm="Monit"'); self.end_headers(); return
        if self.path.startswith('/_status'):
            self.send_response(200); self.send_header('Content-Type','application/xml'); self.send_header('Content-Length',str(len(xml))); self.end_headers(); self.wfile.write(xml)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(('127.0.0.1',port),H).serve_forever()
PY
python3 "$TMP/mock.py" 18213 "$ROOT/testdata/all-types.xml" "$USER_NAME" "$PASSWORD" & PIDS+=("$!")
for _ in $(seq 1 50); do curl -fsS -u "$USER_NAME:$PASSWORD" 'http://127.0.0.1:18213/_status?format=xml&level=full' >/dev/null 2>&1 && break; sleep .1; done
MONIT_USER="$USER_NAME" MONIT_PASSWORD="$PASSWORD" \
  "$ROOT/bin/monit-prometheus-exporter-linux-amd64" --listen-address 127.0.0.1:19109 --monit-url 'http://127.0.0.1:18213/_status?format=xml&level=full' --cache 0s >"$TMP/exporter.log" 2>&1 & PIDS+=("$!")
for _ in $(seq 1 50); do curl -fsS http://127.0.0.1:19109/healthz >/dev/null 2>&1 && break; sleep .1; done
curl -fsS http://127.0.0.1:19109/metrics > "$TMP/metrics"
grep -q '^monit_up 1$' "$TMP/metrics"
! grep -q 'monit returned HTTP 401' "$TMP/exporter.log"
echo 'monit_exporter_auth_integration: PASS'
