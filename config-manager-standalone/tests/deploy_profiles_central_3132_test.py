from pathlib import Path
root=Path(__file__).resolve().parents[1]
backend=(root/'public/git_deploy.php').read_text()
editor=(root/'public/git_config_editor.php').read_text()
editor_js=(root/'public/assets/js/git_config_editor.js').read_text()
desired=(root/'public/desired_state.php').read_text()
setup=(root.parent/'setup_config_manager.sh').read_text()
lib=(root/'lib/deploy_profiles.php').read_text()
assert "dp_profiles_file" in lib and "deploy_profiles.json" in lib
assert "profiles_get" in backend and "profiles_save" in backend and "profiles_restore" in backend
assert "migrated_from_agent:" in backend, 'one-time migration from existing agent profiles missing'
assert "gd_sync_central_profiles" in backend, 'sync-on-change helper missing'
assert "dp_inventory_profiles()" in desired, 'Desired State does not use central deployment catalog'
assert "ds_sync_deploy_profiles" in desired, 'Desired State does not sync central profiles before enforcement/status'
assert "deploy_profiles.json'" in setup and "deploy_profiles_backups/" in setup, 'central profile state is not preserved by setup rsync'
assert 'gilt für alle Zielserver' in editor
assert '?api=profiles_get' in editor_js and "action: 'profiles_save'" in editor_js
print('deploy_profiles_central_3132_test: PASS')
