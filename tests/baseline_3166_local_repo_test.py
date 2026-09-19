from pathlib import Path
r=Path(__file__).resolve().parents[1]
s=(r/'setup_monit_exporter.sh').read_text()
assert 'BASELINE_REPO_LOCAL_URL' in s
assert 'file://${BASELINE_REPO_DIR%/}/' in s
assert 'removerepo infrastructure-baseline' in s
assert 'repodata/repomd.xml' in s
conf=(r/'teko-stack.conf').read_text()
assert 'BASELINE_REPO_LOCAL_URL=' in conf
repo=(r/'baseline-repository/scripts/prepare_repository.sh').read_text()
assert 'Repository ist lokal gueltig, aber ueber HTTPS noch nicht erreichbar' in repo
cm=(r/'setup_config_manager.sh').read_text()
assert '/etc/pki/trust/anchors/infrastructure-config-manager.crt' in cm
print('baseline_3166_local_repo_test: PASS')
