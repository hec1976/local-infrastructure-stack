#!/usr/bin/env python3
from pathlib import Path
import json,re,sys
root=Path(__file__).resolve().parents[1]

page=(root/'config-manager-standalone/public/desired_state.php').read_text()
lib=(root/'config-manager-standalone/lib/desired_state.php').read_text()
setup=(root/'setup_config_manager.sh').read_text()
config=(root/'config-manager-standalone/config/config.php').read_text()
nav=json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())

assert "Desired State" in page
assert "Check only" in page and "Drift beheben" in page
assert "ds_server_matches" in lib and "ds_compliance" in lib
assert "Git desired.type muss allowed_ref, commit oder tag sein" in lib
assert "desired_state_enforce" in page and "desired_state_save" in page
assert "session_write_close()" in page
assert "count($targets) > $limit" in page
assert "token_file" in config or "server_registry_file" in config
assert "SERVER_REGISTRY_FILE" in setup and "DESIRED_STATE_FILE" in setup
assert "Zusaetzliche Server-Eintraege" not in setup
assert "--exclude 'standalone/data/desired_state.json'" in setup
assert 'chown root:"$APACHE_GROUP" "$SERVER_REGISTRY_FILE"' in setup
assert any(x.get('key')=='desired_state' for x in nav['items'])
assert "CONFIG_MANAGER_SERVER_REGISTRY_FILE" in (root/'config-manager-standalone/standalone/data/config-manager.env.example').read_text()

print("fleet_desired_state_feature_test: OK")
