#!/usr/bin/env python3
from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
page=(root/"config-manager-standalone/public/desired_state.php").read_text()
lib=(root/"config-manager-standalone/lib/desired_state.php").read_text()
example=json.loads((root/"config-manager-standalone/config/desired_state.example.json").read_text())

assert "source.type muss git oder config_manager sein" in lib
assert "reference_server" in lib and "source_config" in lib and "target_config" in lib
assert "ConfigManagerController::saveConfig()" in page
assert "->saveConfig(" in page
assert "md5($oldContent)" in page
assert "hash('sha256', $content)" in page
assert "hash('sha256', $targetContent)" in page
assert "ds_find_server_by_name" in page
assert "ds_prepare_policy_context" in page
assert "Referenzserver ist nicht in der Fleet-Registry vorhanden" in page
assert "'source_type'=>'config_manager'" in page
assert "'source_type'=>'git'" in page
assert "Config Manager" in page and "Git" in page
assert "Soll SHA-256" in page and "Ist SHA-256" in page

cm=example["policies"]["monit-base-config"]
assert cm["source"]["type"]=="config_manager"
assert cm["source"]["source_config"]=="monit-teko-stack"
git=example["policies"]["software-scripts"]
assert git["source"]["type"]=="git"
assert git["source"]["desired"]["type"]=="tag"

print("multisource_desired_state_test: OK")
