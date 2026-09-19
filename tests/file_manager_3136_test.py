#!/usr/bin/env python3
from pathlib import Path
import json
r=Path(__file__).resolve().parents[1]
agent=(r/'config-agent/lib/FileManager.pm').read_text()
page=(r/'config-manager-standalone/public/file_manager.php').read_text()
global_cfg=json.loads((r/'config-agent/example/global.json.example').read_text())
for route in ["get '/files/roots'","get '/files/list'","get '/files/read'","post '/files/write'","post '/files/delete'","post '/files/rename'"]:
    assert route in agent, route
assert '_is_hard_protected_path' in agent
assert '_fm_no_symlink_path' in agent
assert 'safe_write_file' in agent
assert 0 < len(global_cfg.get('file_manager_read_roots', global_cfg.get('file_manager_roots',[])))
assert 0 < len(global_cfg.get('file_manager_write_roots', global_cfg.get('file_manager_roots',[])))
assert 'Max. 1 MiB' in page
print('file_manager_3136_test: PASS')
