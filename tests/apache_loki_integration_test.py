#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
s=(r/'setup_observability.sh').read_text()
i=(r/'observability/apache-loki-importer.py').read_text()
assert 'teko-apache-loki-importer.service' in s
assert '/var/log/apache2' in s
assert 'for dashboard in "$ROOT"/observability/grafana/dashboards/teko-*.json' in s
assert "return 'apache'" in i
assert "return 'modsecurity'" in i
assert "'service':job" in i
assert 'modsecurity-audit' in i
print('PASS apache/modsecurity/config-manager logs -> separated Loki services')
