#!/usr/bin/env python3
from pathlib import Path
import ast
root=Path(__file__).resolve().parents[1]
page=(root/'config-manager-standalone/public/agent_enrollment.php').read_text()
worker=(root/'bin/teko-agent-enrollment-worker.py').read_text()
ast.parse(worker)

# Password mode must not require a manually entered host-key fingerprint.
assert "if($authMode==='key'" in page
assert "if($authMode==='password' && $fp!==''" in page
assert "fp.required=mode==='key'" in page
assert "optional bei Passwort" in page
assert "automatisch erfasst" in page
assert "bootstrapKeyBox" in page
assert "keyBox.classList.toggle('ae-hidden',mode!=='key')" in page

# Worker keeps strict host-key checking and only allows empty fingerprint for password auth.
assert 'fingerprint required for key auth' in worker
assert 'job.get("auth_mode") != "password"' in worker
assert 'Explicit demo/bootstrap TOFU' in worker
assert 'StrictHostKeyChecking=yes' in worker
assert 'ssh-keyscan' in worker
assert 'SSH host key fingerprint mismatch' in worker
assert 'observed_host_key_sha256' in worker
print('agent_enrollment_password_optional_hostkey_test: PASS')
