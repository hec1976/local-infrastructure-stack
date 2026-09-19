#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
s=(root/'config-manager-standalone/Controller/ConfigManagerController.php').read_text()
assert "'service_' . ($cmd !== '' ? $cmd : 'action')" in s
assert "$cmd === 'journal'" in s
assert "$cmd === 'status'" in s
assert "'http_code' => $httpCode" in s
assert "['command' => $cmd, 'http_code' => $httpCode]" in s
assert "['command' => $cmd, 'error' => substr($e->getMessage(), 0, 500)]" in s
print('service_action_audit_test: PASS')
