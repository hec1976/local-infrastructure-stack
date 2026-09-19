#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
setup=(root/'setup_agent_enrollment_manager.sh').read_text()
page=(root/'config-manager-standalone/public/agent_enrollment.php').read_text()
for needle in [
    'PathChanged=/var/lib/teko-agent-enrollment/queue',
    'DirectoryNotEmpty=/var/lib/teko-agent-enrollment/queue',
    'teko-agent-enrollment.timer',
    'OnUnitActiveSec=10s',
    'systemctl enable --now teko-agent-enrollment.path teko-agent-enrollment.timer',
    'systemctl start teko-agent-enrollment.service || true',
]:
    assert needle in setup, needle
assert "incoming=rtrim" in page
assert "incoming_dir" in page
assert ".queue-'.$id.'.tmp'" in page
assert "$tmp=$queue.'/.'.$id.'.tmp'" not in page
assert 'Job wartet länger als 20 Sekunden' in page
print('agent_enrollment_worker_trigger_test: PASS')
