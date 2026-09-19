#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
TMP="$(mktemp -d /tmp/monit-prometheus-exporter-test.XXXXXX)"
PIDS=()
cleanup(){ for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/mock.py" <<'PY'
import http.server,sys,pathlib
port=int(sys.argv[1]); xml=pathlib.Path(sys.argv[2]).read_bytes()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/_status'):
            self.send_response(200); self.send_header('Content-Type','application/xml'); self.send_header('Content-Length',str(len(xml))); self.end_headers(); self.wfile.write(xml)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(('127.0.0.1',port),H).serve_forever()
PY
python3 "$TMP/mock.py" 18212 "$ROOT/testdata/all-types.xml" & PIDS+=("$!")
for _ in $(seq 1 50); do curl -fsS 'http://127.0.0.1:18212/_status?format=xml&level=full' >/dev/null 2>&1 && break; sleep .1; done
"$ROOT/bin/monit-prometheus-exporter-linux-amd64" --listen-address 127.0.0.1:19108 --monit-url 'http://127.0.0.1:18212/_status?format=xml&level=full' --cache 0s >"$TMP/exporter.log" 2>&1 & PIDS+=("$!")
for _ in $(seq 1 50); do curl -fsS http://127.0.0.1:19108/healthz >/dev/null 2>&1 && break; sleep .1; done
curl -fsS http://127.0.0.1:19108/metrics > "$TMP/metrics"
grep -q '^monit_up 1$' "$TMP/metrics"
for t in filesystem directory file process host system fifo program network; do grep -q "monit_services_total{type=\"$t\"} 1" "$TMP/metrics"; done
grep -q 'monit_process_pid{service="postfix",type="process"} 1234' "$TMP/metrics"
grep -q 'monit_object_size_bytes{service="monitrc-file",type="file"} 2048' "$TMP/metrics"
grep -q 'monit_program_exit_status{service="health-program",type="program"} 0' "$TMP/metrics"
grep -q 'monit_network_rx_bytes_total{service="eth0",type="network"}' "$TMP/metrics"
# POST is intentionally rejected.
[[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:19108/metrics)" == "405" ]]
echo 'monit_exporter_integration: PASS'
