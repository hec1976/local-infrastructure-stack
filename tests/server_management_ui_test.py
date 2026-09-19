from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
page=(root/'config-manager-standalone/public/server_management.php').read_text()
nav=json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())
for term in ['sm-summary','Server gesamt','Label-Schlüssel','Authentifizierung','sm-server-icon','Keine Gruppen','Keine Labels']:
    assert term in page, term
item=next(i for i in nav['items'] if i.get('key')=='server_management')
assert item['icon']=='bi bi-server'
for f in ['observability/loki-importer.py','observability/apache-loki-importer.py']:
    s=(root/f).read_text()
    assert 'time.time_ns()' not in s
    assert 'int(time.time() * 1_000_000_000)' in s
print('server_management_ui_test: PASS')
