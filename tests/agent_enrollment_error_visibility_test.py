from pathlib import Path
root=Path(__file__).resolve().parents[1]
php=(root/'config-manager-standalone/public/agent_enrollment.php').read_text()
worker=(root/'bin/teko-agent-enrollment-worker.py').read_text()
assert 'Fehlerursache' in php
assert 'Technische Fehlerdetails anzeigen' in php
assert 'renderFailure(x)' in php
assert 'STDOUT:' in worker and 'STDERR:' in worker
assert 'p.stdout.decode' in worker and 'p.stderr.decode' in worker
print('agent_enrollment_error_visibility_test: PASS')
