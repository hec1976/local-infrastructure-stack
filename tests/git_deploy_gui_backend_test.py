#!/usr/bin/env python3
from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
example=json.loads((root/'config-agent/example/git_deploy.json.example').read_text())
profiles=example.get('profiles',{})
assert list(profiles)==['teko-config-deploy'], profiles
p=profiles['teko-config-deploy']
assert p['repository']=='https://git.local/teko/config-deploy.git'
assert p['target']=='/opt/service/config-deploy'
setup=(root/'setup_config_agent.sh').read_text()
assert 'install -d -o root -g root -m 0755 /opt/service /opt/service_script' in setup
assert 'legacy_urls' in setup
assert '/bin/bash ./_install.sh --no-start' in setup
portal=(root/'config-manager-standalone/public/git_deploy.php').read_text()
assert '$deployments = $service->getGitDeployments();' in portal
assert portal.index('$deployments = $service->getGitDeployments();') < portal.index("$item['version'] = $service->getServerVersion();")
assert 'git_deploy.js?v=3.25.0' in portal
post=(root/'bin/teko-postinstall-test.sh').read_text()
assert '/git_deployments' in post
assert 'd.get("config_valid") is True' in post
assert 'd.get("degraded") is False' in post
assert 'd.get("enabled") is True' in post

editor_js=(root/'config-manager-standalone/public/assets/js/git_config_editor.js').read_text()
editor_php=(root/'config-manager-standalone/public/git_config_editor.php').read_text()
assert 'assistantRepositories = [...assistantAllRepositories];' in editor_js
assert 'bereits verwendet:' in editor_js
assert 'bereits in git_deploy.json definiert und ausgeblendet' not in editor_js
assert 'Keine neuen Repositorys verfügbar' not in editor_js
assert 'Alle für den Forgejo-Service-User lesbaren Repositorys werden angezeigt.' in editor_php

print('PASS git_deploy_gui_backend_test')
