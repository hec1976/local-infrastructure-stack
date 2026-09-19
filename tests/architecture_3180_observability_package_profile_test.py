from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
profile=(ROOT/'bin/bootstrap-observability-deploy-profile.sh').read_text()
forgejo=(ROOT/'bin/forgejo-bootstrap-teko.sh').read_text()
gitdeploy=(ROOT/'config-agent/lib/GitDeploy.pm').read_text()
spec=(ROOT/'baseline-repository/SPECS/client-baseline.spec').read_text()
assert "FORGEJO_OBSERVABILITY_REPO:-observability-client" in profile
assert "'post_deploy': {" in profile and "'script': 'install.sh'" in profile
assert "'allow_repository_package_plan': False" in profile
assert 'ensure_repo_file "$OBS_REPO" "deploy-profile.json"' in forgejo
assert 'ensure_repo_file "$OBS_REPO" "packages.json"' in forgejo
assert 'ensure_repo_file "$OBS_REPO" "install.sh" "$OBS_INSTALL_SH"' in forgejo
for pkg in ('monit','alloy','monit-prometheus-exporter','client-baseline'):
    assert '{"name": "%s", "state": "present"}' % pkg in forgejo
assert 'zypper --non-interactive install --no-recommends "${PACKAGES[@]}"' in forgejo
assert r'unless $program_real =~ /\.sh\z/' in gitdeploy
assert 'Version:        1.2.8' in spec
print('architecture_3180_observability_package_profile_test: PASS')
