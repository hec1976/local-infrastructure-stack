#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
files=[
    ROOT/'bin/teko-observability-auth-sync.py',
    ROOT/'bin/teko-server-registry-write.py',
    ROOT/'bin/teko-agent-enrollment-worker.py',
    ROOT/'bin/teko-agent-token-manager.py',
]
for p in files:
    s=p.read_text()
    assert 'subprocess.run' in s, p
    assert 'text=True' not in s, f'Python 3.7-only text=True in runtime file: {p}'
print('python36_subprocess_runtime_test: OK')
