from pathlib import Path
root=Path(__file__).resolve().parents[1]
editor=(root/'config-manager-standalone/public/desired_state_editor.php').read_text()
api=(root/'config-manager-standalone/public/desired_state.php').read_text()
cfg=(root/'config-manager-standalone/public/configs_editor.php').read_text()
checks={
 'source_is_select':'<select class="form-select" id="fSourceConfig">' in editor,
 'target_is_select':'<select class="form-select" id="fTargetConfig">' in editor,
 'same_id_default':'id="fSameTarget" checked' in editor,
 'catalog_in_api':"'config_catalog'=>ds_managed_config_catalog($servers)" in api,
 'server_ref_validation':'ds_validate_config_object_references($servers, $normalized)' in api,
 'delete_rename_guard':'cm_assert_config_ids_not_referenced' in cfg,
 'guard_message':'kann nicht gelöscht oder umbenannt werden' in cfg,
 'dependency_roles':"'role'=>'Quelle'" in cfg and "'role'=>'Ziel'" in cfg,
}
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
assert all(checks.values())
