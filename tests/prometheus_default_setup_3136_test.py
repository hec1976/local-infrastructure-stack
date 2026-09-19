#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
s=(r/'setup_observability.sh').read_text()
conf=(r/'teko-stack.conf').read_text()
assert 'prometheus.container' in s
assert 'PROMETHEUS_IMAGE' in conf and 'PROMETHEUS_HTTP_PORT' in conf
assert '--web.enable-remote-write-receiver' in s
assert (r/'observability/prometheus/prometheus.yml').is_file()
assert (r/'observability/grafana/provisioning/datasources/prometheus.yaml').is_file()
assert '127.0.0.1:${PROMETHEUS_HTTP_PORT}:9090' in s
print('prometheus_default_setup_3136_test: PASS')
