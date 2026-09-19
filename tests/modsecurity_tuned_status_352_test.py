from pathlib import Path
p=Path(__file__).resolve().parents[1]/'config-manager-standalone/public/modsecurity.php'
s=p.read_text()
assert '# CM-FP-MATCH: rule=' in s
assert 'function parseManagedExclusions(content)' in s
assert 'function msNormHost(v)' in s
assert 'function msNormUri(v)' in s
assert "x.status!=='active'||x.rule!==rid" in s
assert "msNormHost(x.host)!==host||msNormUri(x.uri)!==uri" in s
print('OK tuned status matcher 3.5.2')
