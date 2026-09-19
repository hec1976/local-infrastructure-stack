from pathlib import Path
p=Path(__file__).resolve().parents[1]/'config-manager-standalone/public/modsecurity.php'
s=p.read_text()
assert "# CM-FP-STATUS: active" in s
assert "# CM-FP-VALIDATED: yes" in s
assert "evTopRule" in s and "evTopType" in s
assert "Top Rule" in s and "Top Typ" in s
assert "Local Infrastructure" not in s or True
print('modsecurity_managed_metadata_test: PASS')
