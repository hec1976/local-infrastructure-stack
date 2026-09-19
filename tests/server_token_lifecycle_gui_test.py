from pathlib import Path
root=Path(__file__).resolve().parents[1]
php=(root/'config-manager-standalone/public/server_management.php').read_text()
helper=(root/'bin/teko-agent-token-manager.py').read_text()
setup=(root/'setup_config_manager.sh').read_text()
for s in ['Token prüfen','Via SSH synchronisieren','Token rotieren','token_status','token_sync','token_rotate']:
    assert s in php, s
assert 'ssh_password' in php
assert "mmbb_audit_write('server_token_'" in php
assert "'ssh_password'" not in php.split("mmbb_audit_write('server_token_'",1)[1].split("sm_json",1)[0]
for s in ['CONFIG_AGENT_API_TOKEN','/health','StrictHostKeyChecking=yes','UserKnownHostsFile=','ROTATE_SCRIPT','READ_SCRIPT']:
    assert s in helper, s
assert 'teko-agent-token-manager.py' in setup
assert 'NOPASSWD: /usr/bin/python3 /usr/local/libexec/teko-agent-token-manager.py' in setup
print('server_token_lifecycle_gui_test: PASS')
