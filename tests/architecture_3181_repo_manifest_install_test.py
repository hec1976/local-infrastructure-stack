from pathlib import Path
root=Path(__file__).resolve().parents[1]
gd=(root/'config-agent/lib/GitDeploy.pm').read_text()
boot=(root/'bin/bootstrap-observability-deploy-profile.sh').read_text()
forge=(root/'bin/forgejo-bootstrap-teko.sh').read_text()
assert '_load_repository_package_plan' in gd
assert "'allow_repository_package_plan': False" in boot
segment=boot.split("profiles['observability-client']={",1)[1].split("}\ndoc['schema_version']",1)[0]
assert "'packages':" not in segment
assert "'package_repositories':" not in segment
assert "'post_deploy':" in segment and "'script': 'install.sh'" in segment
assert '"packages": [' in forge and '"package_repositories": [' in forge
assert 'ensure_repo_file "$OBS_REPO" "install.sh" "$OBS_INSTALL_SH"' in forge
ui=(root/'config-manager-standalone/public/assets/js/git_config_editor.js').read_text()
assert 'install.sh' in ui and 'automatisch gestartet' in ui
print('architecture_3181_repo_manifest_install_test: PASS')
