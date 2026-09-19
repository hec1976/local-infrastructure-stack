from pathlib import Path
r=Path(__file__).resolve().parents[1]
script=(r/'baseline-repository/SOURCES/configure-observability-client.sh').read_text()
spec=(r/'baseline-repository/SPECS/client-baseline.spec').read_text()
assert '// Managed by package: client-baseline' in script
assert 'cat > "$ALLOY_TMP"' in script
assert 'alloy validate "$ALLOY_TMP"' in script
assert 'mv -f "$ALLOY_TMP" "$ALLOY_CONFIG"' in script
assert '# Managed by package: client-baseline' not in script
assert 'Version:        1.2.8' in spec
print('PASS alloy_config_3185_regression_test')
