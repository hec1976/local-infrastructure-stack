from pathlib import Path
r=Path(__file__).resolve().parents[1]
cm=(r/'setup_config_manager.sh').read_text()
bs=(r/'setup_baseline_repository.sh').read_text()
fg=(r/'bin/forgejo-bootstrap-teko.sh').read_text()
sm=(r/'config-manager-standalone/public/server_management.php').read_text()
assert 'Alias /baseline-repo/' in cm
assert '<Location \\"/baseline-repo/\\">' in cm or '<Location "/baseline-repo/">' in cm
assert 'SecRuleEngine Off' in cm
assert 'repodata/repomd.xml' in bs
assert 'HTTPS Repository-Publishing' in bs
assert 'repo_https_preflight' in fg
assert '--cacert' in fg
assert 'Agent Lifecycle' in sm
assert 'Remote-Einstellungen ueberschreiben' not in sm
print('repository_publish_31813_test: PASS')
