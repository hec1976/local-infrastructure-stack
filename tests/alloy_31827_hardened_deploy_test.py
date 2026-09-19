from pathlib import Path
root=Path(__file__).resolve().parents[1]
s=(root/'baseline-repository/SOURCES/configure-observability-client.sh').read_text()
assert 'runuser -u "$ALLOY_USER"' not in s
assert 'alloy validate "$ALLOY_TMP"' in s
assert 'chown root:root "$ALLOY_CONFIG"' in s
assert 'chmod 0644 "$ALLOY_CONFIG"' in s
assert 'systemctl restart alloy.service' in s
assert 'for i in 1 2 3 4 5; do' in s
assert 'alloy.service aktiv und stabil' in s
spec=(root/'baseline-repository/SPECS/client-baseline.spec').read_text()
assert 'Version:        1.2.8' in spec
print('PASS alloy 3.18.27 hardened deploy')
