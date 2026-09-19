from pathlib import Path
root=Path(__file__).resolve().parents[1]
js=(root/'config-manager-standalone/public/assets/js/git_deploy.js').read_text()
php=(root/'config-manager-standalone/public/git_deploy.php').read_text()
assert 'gitDeployBlockReason' in php
assert 'Nächster Schritt: „Änderungen prüfen“.' in js
assert 'Bereit zum Deploy.' in js
assert 'Erstinstallation' in js
assert "if (!activeCommit && desiredCommit)" in js
assert "!diffApproved" in js
assert 'git_deploy.js?v=3.25.0' in php
print('git_deploy_first_install_ux_test: PASS')
