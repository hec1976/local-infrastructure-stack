#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
php=(root/'config-manager-standalone/public/git_deploy.php').read_text()
js=(root/'config-manager-standalone/public/assets/js/git_deploy.js').read_text()
css=(root/'config-manager-standalone/public/assets/css/git_deploy.css').read_text()
for marker in ['data-gd-tab="deploy"','data-gd-tab="history"','data-gd-tab="restore"','gitDeployStep1','gitDeployStep4','gitDeployNextAction']:
    assert marker in php, marker
for marker in ['function activateTab','function updateWorkflow',"activateTab('history')",'git-deploy-profile-cards']:
    assert marker in js, marker
for marker in ['.git-deploy-workflow','.git-deploy-mode-tabs','.git-deploy-next-action','.git-deploy-profile-cards']:
    assert marker in css, marker
header=php.split('git-deploy-server-columns',1)[1].split('</div>',1)[0]
assert 'Agent</span>' not in header
assert 'Token</span>' not in header
print('git_deploy_guided_ux_test: PASS')
