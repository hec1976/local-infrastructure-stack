#!/usr/bin/env python3
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys=(root/'observability/system-loki-importer.py').read_text()
ap=(root/'observability/apache-loki-importer.py').read_text()
aud=(root/'observability/loki-importer.py').read_text()
assert "labels = {'job': job, 'service': job}" in sys
assert "key = (job, hostname)" in sys
assert "'event': event[:32]" not in sys
assert "return 'modsecurity'" in ap
assert "'service':job" in ap
assert '("service", "config-manager-audit")' in aud
for fn,uid in [
 ('teko-postfix.json','teko-postfix'),('teko-monit-prometheus.json','teko-monit-prometheus'),
 ('teko-apache-logs.json','teko-apache'),('teko-modsecurity.json','teko-modsecurity'),
 ('teko-config-manager-runtime.json','teko-config-manager-runtime'),
 ('teko-config-manager-audit.json','teko-config-manager-audit'),
 ('teko-operations-overview.json','teko-operations-overview')]:
 d=json.loads((root/'observability/grafana/dashboards'/fn).read_text()); assert d['uid']==uid
setup=(root/'setup_observability.sh').read_text()
assert 'for dashboard in "$ROOT"/observability/grafana/dashboards/teko-*.json' in setup
print('PASS service-separated Loki + dashboards')
