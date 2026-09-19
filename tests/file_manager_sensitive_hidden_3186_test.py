from pathlib import Path
s=Path('config-agent/lib/FileManager.pm').read_text()
for marker in ['/var/lib/service/config-agent/secrets', r'\.ssh', "hidden_protected"]:
    assert marker in s, marker
assert 'if (_fm_sensitive_path($p) || _fm_runtime_blocked($p))' in s
print('file_manager_sensitive_hidden_3186_test: PASS')
