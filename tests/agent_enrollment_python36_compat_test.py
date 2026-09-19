#!/usr/bin/env python3
from pathlib import Path
import ast

root=Path(__file__).resolve().parents[1]
worker=(root/"bin/teko-agent-enrollment-worker.py").read_text()
setup=(root/"setup_agent_enrollment_manager.sh").read_text()

assert "from __future__ import annotations" not in worker
assert "capture_output=True" not in worker
assert "missing_ok=True" not in worker
assert "stdout=subprocess.PIPE" in worker
assert "stderr=subprocess.PIPE" in worker
assert "sys.version_info < (3, 6)" in setup
assert 'ExecStart=/usr/bin/python3 /usr/local/sbin/teko-agent-enrollment-worker' in setup
# Parse against Python 3.6 grammar when supported by the running interpreter.
try:
    ast.parse(worker, filename="teko-agent-enrollment-worker.py", feature_version=(3, 6))
except TypeError:
    ast.parse(worker, filename="teko-agent-enrollment-worker.py")
print("agent_enrollment_python36_compat_test: PASS")
