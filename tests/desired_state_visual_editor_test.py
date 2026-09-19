from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
page=(root/'config-manager-standalone/public/desired_state_editor.php').read_text()
api=(root/'config-manager-standalone/public/desired_state.php').read_text()
nav=json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())
checks={
'page_exists': 'Baseline bearbeiten' in page,
'visual_selector': '2. Zuweisung' in page and 'Passende Server' in page and 'selectorModeBar' in page and 'fGroupMatch' in page,
'deployment_dropdown': 'id="fDeployment"' in page and 'Git-Deploy-Profilen' in page,
'advanced_json': 'Erweitert: JSON' in page,
'atomic_save_api': "saveOrValidate('save')" in page and "desired_state.php" in page,
'catalog_api': "editor_catalog" in api and "dp_inventory_profiles" in api,
'nav': any(x.get('key')=='desired_state_editor' for x in nav['items']),
}
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
assert all(checks.values())
