from pathlib import Path
import json, re
root=Path(__file__).resolve().parents[1]
page=(root/'config-manager-standalone/public/server_management.php').read_text()
nav=json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())
setup=(root/'setup_config_manager.sh').read_text()
helper=(root/'bin/teko-server-registry-write.py').read_text()
runtime=(root/'config-manager-standalone/lib/config_manager_runtime.php').read_text()
assert any(i.get('key')=='server_management' for i in nav['items'])
for term in ['Gruppen','Labels','Server hinzufügen','Bearbeiten','Löschen','enabled']:
    assert term in page, term
assert '/opt/service/config-manager/servers.json' in page
assert 'proc_open' in page and '/usr/bin/sudo' in page
assert 'teko-config-manager-server-registry' in setup and 'visudo -cf' in setup
assert 'os.replace' in helper and 'Doppelter Servername' in helper and 'Doppelte Server-URL' in helper
assert "array_key_exists('enabled', $srv)" in runtime
print('server_management_feature_test: PASS')
