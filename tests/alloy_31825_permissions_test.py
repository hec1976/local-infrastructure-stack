from pathlib import Path
root=Path(__file__).resolve().parents[1]
obs=(root/'baseline-repository/SOURCES/configure-observability-client.sh').read_text()
pb=(root/'config-agent/lib/PlatformBaseline.pm').read_text()
assert 'chown root:root "$ALLOY_CONFIG"' in obs
assert 'chmod 0644 "$ALLOY_CONFIG"' in obs
assert 'chown root:root "$ALLOY_TMP"' in obs
assert 'chmod 0644 "$ALLOY_TMP"' in obs
assert 'safe_write_file($path,$cfg,1); chown 0,0,$path; chmod 0644,$path;' in pb
assert 'chmod 0640,$path' not in pb
print('alloy 3.18.25 permissions regression: OK')
