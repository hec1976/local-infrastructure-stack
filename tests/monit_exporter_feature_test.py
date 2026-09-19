#!/usr/bin/env python3
from pathlib import Path
import json, subprocess
root=Path(__file__).resolve().parents[1]
xml=(root/'monit-exporter/internal/monit/xml.go').read_text()
metrics=(root/'monit-exporter/internal/monit/metrics.go').read_text()
main=(root/'monit-exporter/cmd/monit-prometheus-exporter/main.go').read_text()
setup=(root/'setup_monit_exporter.sh').read_text()
unit=(root/'baseline-repository/SOURCES/monit-prometheus-exporter.service').read_text()
spec=(root/'baseline-repository/SPECS/monit-prometheus-exporter.spec').read_text()
monit_setup=(root/'setup_postfix_monit.sh').read_text()
master=(root/'setup_teko_local.sh').read_text()

for code,name in [('0','filesystem'),('1','directory'),('2','file'),('3','process'),('4','host'),('5','system'),('6','fifo'),('7','program'),('8','network')]:
    assert f'"{code}": "{name}"' in xml
for metric in [
 'monit_process_cpu_percent','monit_process_memory_bytes',
 'monit_object_size_bytes','monit_filesystem_space_percent',
 'monit_host_port_response_seconds','monit_system_load1',
 'monit_program_exit_status','monit_network_rx_bytes_total',
 'monit_value']:
    assert metric in metrics, metric
assert 'io.LimitReader(r, 16<<20)' in xml
assert 'CharsetReader' in xml and 'iso-8859-1' in xml
assert '127.0.0.1:9108' in main
assert '/metrics' in main and '/healthz' in main
assert 'ReadHeaderTimeout' in main and 'TLS12' in main
assert 'set httpd' in monit_setup and 'use address 127.0.0.1' in monit_setup and 'allow localhost' in monit_setup
assert 'zypper --non-interactive install monit-prometheus-exporter' in setup
assert 'DynamicUser=true' in unit
assert 'NoNewPrivileges=true' in unit
assert 'ProtectSystem=strict' in unit
assert 'MemoryDenyWriteExecute=true' in unit
assert 'ExecStart=/usr/bin/monit-prometheus-exporter' in unit
assert 'Name:           monit-prometheus-exporter' in spec
assert 'setup_monit_exporter.sh' not in master
assert 'bootstrap-observability-deploy-profile.sh' in master
assert (root/'monit-exporter/bin/monit-prometheus-exporter-linux-amd64').is_file()
assert (root/'observability/grafana/dashboards/teko-monit-prometheus.json').is_file()
assert not (root/'observability/grafana/dashboards/teko-monit-logs.json').exists()
print('monit_exporter_feature_test: PASS')
