#!/usr/bin/env python3
from pathlib import Path
import ast,re
root=Path(__file__).resolve().parents[1]
page=(root/'config-manager-standalone/public/agent_enrollment.php').read_text()
worker=(root/'bin/teko-agent-enrollment-worker.py').read_text()
ast.parse(worker)

# Worker must expose deterministic, persisted enrollment stages.
for needle in [
    'STAGE_DEFS=[',
    '("hostkey","SSH Host-Key",10)',
    '("ssh_auth","SSH Anmeldung",20)',
    '("bundle_transfer","Bundle uebertragen",45)',
    '("agent_install","Agent installieren",62)',
    '("registration_import","Registrierung importieren",87)',
    '("health_check","Health-Check",95)',
    'def set_progress(', 'def fail_progress(', 'def complete_progress(',
    'progress("agent_install"', 'progress("health_check"',
    '"events":[]', '"steps":make_steps()'
]:
    assert needle in worker, needle

# UI must present progress, steps and event history instead of only a final result.
for needle in [
    'ENROLL_STEPS=[', 'ae-progress-wrap', 'ae-step-grid', 'ae-eventlog',
    'Schritt ${esc(stepText)}', 'progress_percent', 'renderEvents(x)',
    'Wartet auf Enrollment-Worker', 'teko-agent-enrollment.service'
]:
    assert needle in page, needle

# Summary must de-duplicate queued/status copies of the same job.
assert '$byId=[];' in page
assert '$byId[$id]=$q;' in page
assert '$byId[$id]=$st;' in page
assert '$jobs=array_values($byId);' in page

# Auth mode should survive a page refresh for demo usability.
assert "localStorage.setItem('tekoEnrollmentAuthMode'" in page
assert "localStorage.getItem('tekoEnrollmentAuthMode')" in page
print('agent_enrollment_live_status_test: PASS')
