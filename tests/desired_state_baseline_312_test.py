from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
nav=json.loads((ROOT/'config-manager-standalone/config/module_navigation.json').read_text())
mods=nav if isinstance(nav,list) else nav.get('items',[])
by={m.get('key'):m for m in mods}
assert by['desired_state']['label']=='Desired State'
assert by['desired_state_editor']['enabled'] is False
editor=(ROOT/'config-manager-standalone/public/desired_state_editor.php').read_text()
page=(ROOT/'config-manager-standalone/public/desired_state.php').read_text()
for text in ['Baselines verwalten','1. Sollzustand','2. Zuweisung','3. Abweichungen','Erweiterte Rollout-Einstellungen']:
    assert text in editor, text
assert 'Gleiche Config-ID auf den Zielservern verwenden (empfohlen)' in editor
assert 'Übersicht & Abweichungen' in page
assert 'Baseline Details' in page
print('desired_state_baseline_312_test: PASS')
