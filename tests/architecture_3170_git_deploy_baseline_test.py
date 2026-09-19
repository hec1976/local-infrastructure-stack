from pathlib import Path
r=Path(__file__).resolve().parents[1]
page=(r/'config-manager-standalone/public/client_baseline.php').read_text()
agent=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
forge=(r/'bin/forgejo-bootstrap-teko.sh').read_text()
setup=(r/'setup_teko_local.sh').read_text()
profile=(r/'bin/bootstrap-observability-deploy-profile.sh').read_text()
assert 'Baseline Paket-Repository' not in page
assert 'saveAlloy' not in page
assert 'installPackages' not in page
assert 'observability-client' in page
assert "deployment=>[qw(monit grafana-alloy monit-prometheus-exporter)]" in agent
assert 'deploy-profile.json' in forge and 'packages.json' in forge
assert 'ensure_repo_file "$OBS_REPO" "install.sh" "$OBS_INSTALL_SH"' in forge
assert "profiles['observability-client']" in profile
assert "'post_deploy': {" in profile and "'script': 'install.sh'" in profile
assert 'setup_monit_exporter.sh' not in setup
assert 'bootstrap-observability-deploy-profile.sh' in setup
print('architecture_3170_git_deploy_baseline_test: PASS')
