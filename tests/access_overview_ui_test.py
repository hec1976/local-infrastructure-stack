from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
p=(root/'config-manager-standalone/public/access_overview.php').read_text()
nav=json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())
assert 'Zugänge & Secrets' in p
assert '--show-secrets' in p
assert 'Secrets werden nicht im Klartext angezeigt' in p
assert 'token_file' in p
item=next(x for x in nav['items'] if x['key']=='access_overview')
assert item['enabled'] and item['group']=='Administration'
pw=next(x for x in nav['items'] if x['key']=='password_change')
assert pw['group']=='Administration'
print('access_overview_ui_test: OK')
