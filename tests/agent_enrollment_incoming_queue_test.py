from pathlib import Path
root=Path(__file__).resolve().parents[1]
php=(root/'config-manager-standalone/public/agent_enrollment.php').read_text()
setup=(root/'setup_agent_enrollment_manager.sh').read_text()
assert "incoming_dir" in php
assert "Enrollment Incoming-Verzeichnis ist nicht beschreibbar." in php
assert "Enrollment State-Verzeichnis ist nicht beschreibbar." not in php
assert '$STATE/incoming' in setup
assert '"incoming_dir": "$STATE/incoming"' in setup
assert '-m 2770 "$STATE/incoming"' in setup
print('agent_enrollment_incoming_queue_test: PASS')
