#!/usr/bin/env python3
from pathlib import Path
import json,re
root=Path(__file__).resolve().parents[1]
lib=(root/"config-manager-standalone/lib/desired_state.php").read_text()
page=(root/"config-manager-standalone/public/desired_state.php").read_text()
remote=(root/"setup_remote_config_agent.sh").read_text()
base=(root/"setup_config_agent.sh").read_text()
example=json.loads((root/"config-manager-standalone/config/desired_state.example.json").read_text())
registry=json.loads((root/"config-manager-standalone/config/server_registry.example.json").read_text())

for x in ["rollout.strategy muss all oder canary sein","ds_rollout_partition","max_canary_targets","require_canary_compliant"]:
    assert x in lib
for x in ["enforce_canary","enforce_remaining","Canary-Gate blockiert Rollout","Canary ausrollen","Rest ausrollen"]:
    assert x in page
assert "Canary-Policy: zuerst Canary ausrollen" in page
assert "'rollout_action'=>$action" in page

cm=example["policies"]["monit-base-config"]
assert cm["rollout"]["strategy"]=="canary"
assert "canary" in cm["rollout"]["canary_selector"]["groups"]

for x in ["CONFIG_MANAGER_IP","allowed_ips","firewall-cmd","agent-ca.crt","api-token","server-registry-entry.json"]:
    assert x in remote
assert 'CONFIG_AGENT_REMOTE_MODE=1' in remote
assert 'CONFIG_AGENT_REMOTE_MODE' in base
assert '"${CONFIG_AGENT_REMOTE_MODE:-0}" != "1"' in base
assert 'cfg["listen"] = agent_listen' in base

r=registry["servers"][1]
assert r["groups"]==["linux","mail","canary"]
assert r["tls"]["verify"] is True and r["tls"]["verify_host"] is True
assert r["token_file"].startswith("/opt/service/config-manager/tokens/")
print("remote_canary_feature_test: OK")
