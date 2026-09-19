from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
setup=(root/'setup_config_agent.sh').read_text()
remote=(root/'setup_remote_config_agent.sh').read_text()
worker=(root/'bin/teko-agent-enrollment-worker.py').read_text()
manager=(root/'setup_agent_enrollment_manager.sh').read_text()
example=json.loads((root/'config-agent/example/global.json.example').read_text())
assert 'AGENT_ALLOWED_IPS="${SERVER_IP}/32,127.0.0.1/32"' in setup
assert 'AGENT_ALLOWED_IPS="${CONFIG_MANAGER_IP}/32,127.0.0.1/32"' in setup
assert 'git_deploy["enabled"] = True' in setup
assert 'git_upload["enabled"] = True' in setup
assert 'cfg.pop("file_manager_roots", None)' in setup
assert example['allowed_roots']==['/etc','/opt','/srv','/var/lib','/var/log','/usr/local']
assert example['file_manager_read_roots']==['/']
assert example['file_manager_write_roots']==['/etc','/opt','/srv','/var/lib','/var/log','/usr/local']
assert example['git_deploy']['enabled'] is True
assert example['git_upload']['enabled'] is True
assert 'CONFIG_AGENT_FORGEJO_TOKEN_FILE' in remote
assert '"forgejo_token_file": "/opt/service/env/forgejo-api.token"' in manager
assert 'forgejo-api.token' in worker and 'Bootstrap-Bundle' in worker
print('agent_common_defaults_31811_test: PASS')
