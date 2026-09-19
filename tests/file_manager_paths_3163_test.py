from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
fm=(ROOT/'config-agent/lib/FileManager.pm').read_text()
core=(ROOT/'config-agent/lib/Core.pm').read_text()
unit=(ROOT/'config-agent/service/config-agent.service').read_text()
setup=(ROOT/'setup_config_agent.sh').read_text()
ex=json.loads((ROOT/'config-agent/example/global.json.example').read_text())
assert ex['file_manager_read_roots']==['/']
for r in ['/etc','/opt','/srv','/var/lib','/var/log','/usr/local']:
    assert r in ex['file_manager_write_roots']
    assert r in ex['allowed_roots']
assert "ReadWritePaths=-/etc/systemd/system" in unit
assert "ReadOnlyPaths=-/etc/systemd/system" not in unit
for protected in ['/etc/shadow','/etc/sudoers','/etc/ssl/private','/opt/service/env','/opt/service/ssl']:
    assert protected in core
for runtime in ['/proc','/sys','/dev','/run']:
    assert runtime in fm
assert 'file_manager_read_roots' in setup and 'file_manager_write_roots' in setup
print('file_manager_paths_3163_test: PASS')
