from pathlib import Path
r=Path(__file__).resolve().parents[1]
pb=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
ui=(r/'config-manager-standalone/public/client_baseline.php').read_text()
repo=(r/'baseline-repository')
unit=(repo/'SOURCES/monit-prometheus-exporter.service').read_text()
meta=(repo/'SPECS/client-baseline.spec').read_text()
exp=(repo/'SPECS/monit-prometheus-exporter.spec').read_text()
metrics=(r/'monit-exporter/internal/monit/metrics.go').read_text()
assert 'client-baseline' in pb and 'monit-prometheus-exporter' in pb
assert 'infrastructure-baseline' in pb
assert 'observability-client' in ui and 'monit-prometheus-exporter' not in ui
assert 'ExecStart=/usr/bin/monit-prometheus-exporter' in unit
assert 'Environment=MONIT_EXPORTER_LISTEN=' in unit and 'TEKO_MONIT_' not in unit
assert 'Name:           client-baseline' in meta
assert 'Name:           monit-prometheus-exporter' in exp
assert '10-infrastructure-baseline.conf' in meta
assert 'monit_up' in metrics and 'teko_monit_' not in metrics
assert (r/'monit-exporter/bin/monit-prometheus-exporter-linux-amd64').is_file()
assert not (r/'monit-exporter/bin/teko-monit-exporter-linux-amd64').exists()
# Legacy package names are permitted only as upgrade metadata / migration cleanup.
for p in [repo/'manifest.json', repo/'README.md', repo/'install.sh', repo/'SOURCES/monit-prometheus-exporter.service']:
    t=p.read_text()
    assert 'teko-client-baseline' not in t and 'teko-monit-exporter' not in t
print('baseline_3161_generic_naming_test: PASS')
