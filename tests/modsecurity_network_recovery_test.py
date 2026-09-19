from pathlib import Path
p=Path(__file__).resolve().parents[1]/'config-manager-standalone/public/modsecurity.php'
s=p.read_text()
checks={
 'network detector': 'function isNetworkError' in s,
 'recovery polling': 'async function waitForManager' in s,
 '45s timeout': 'timeoutMs=45000' in s,
 'apache restart message': 'Apache wird neu gestartet' in s,
 'same-origin credentials': "credentials:'same-origin'" in s,
 'status reload after recovery': 'await waitForManager();' in s and 'await load();' in s,
}
for k,v in checks.items(): print(('PASS' if v else 'FAIL'), k)
raise SystemExit(0 if all(checks.values()) else 1)
