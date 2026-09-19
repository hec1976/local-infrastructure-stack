from pathlib import Path
root=Path(__file__).resolve().parents[1]
php=(root/'public/git_config_editor.php').read_text()
js=(root/'public/assets/js/git_config_editor.js').read_text()
css=(root/'public/assets/css/configuration_workspace.css').read_text()
assert 'Zentral</strong> · gilt für alle Zielserver' in php
assert '<label for="gceServer" class="form-label">Zielserver</label>' not in php
assert "saveButton.disabled = busy || !loaded || !dirty" in js
assert 'Alles gespeichert' in js and 'Ungespeicherte Änderungen' in js
assert 'meta.preserve > 0' in js
assert '.gce-kebab' in css
print('deploy_profile_363_ux_test: PASS')
