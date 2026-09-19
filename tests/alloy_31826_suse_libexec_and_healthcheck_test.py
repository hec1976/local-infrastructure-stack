from pathlib import Path
root=Path(__file__).resolve().parents[1]
boot=(root/'bin/forgejo-bootstrap-teko.sh').read_text()
conf=(root/'baseline-repository/SOURCES/configure-observability-client.sh').read_text()
spec=(root/'baseline-repository/SPECS/client-baseline.spec').read_text()
assert '/usr/libexec/client-baseline/configure-observability-client' in boot
assert '/usr/lib/client-baseline/configure-observability-client' in boot
assert 'rpm -ql client-baseline' in boot
assert 'client-baseline ist installiert, aber configure-observability-client wurde nicht gefunden' in boot
# no direct restart fallback after a missing configurator
block=boot[boot.index('ALLOY_CONFIGURATOR=""'):boot.index('if rpm -q monit-prometheus-exporter')]
assert 'systemctl restart alloy.service\n  fi' not in block
# authoritative configurator makes config world-readable (no secrets there) and requires stable service
assert 'chmod 0644 "$ALLOY_CONFIG"' in conf
assert 'for i in 1 2 3 4 5; do' in conf
assert 'alloy.service aktiv und stabil' in conf
assert 'Version:        1.2.8' in spec
print('alloy 3.18.26 SUSE libexec/healthcheck regression: OK')
