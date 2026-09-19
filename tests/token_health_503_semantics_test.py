from pathlib import Path
root=Path(__file__).resolve().parents[1]
h=(root/'bin/teko-agent-token-manager.py').read_text()
g=(root/'config-manager-standalone/public/server_management.php').read_text()
assert "'authenticated': int(e.code) not in (401,403)" in h
assert "not api.get('ok') and not api.get('authenticated')" in h
assert 'Agent Health ist degradiert' in h
assert 'tokenHealthErrors' in g and 'Auth OK' in g and 'Health FEHLER' in g
print('token_health_503_semantics_test: PASS')
