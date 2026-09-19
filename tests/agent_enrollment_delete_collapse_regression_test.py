from pathlib import Path
root=Path(__file__).resolve().parents[1]
php=(root/'config-manager-standalone/public/agent_enrollment.php').read_text()
setup=(root/'setup_agent_enrollment_manager.sh').read_text()
worker=(root/'bin/teko-agent-enrollment-worker.py').read_text()
required=[
    "ae_queue_delete_request", "control_dir", "state.openJobs", "state.jobsInitialized",
    "state.openJobs.clear()", "jobsEl.scrollTop=oldScroll", "addEventListener('toggle'"
]
for x in required:
    assert x in php, x
assert '"control_dir": "$STATE/control"' in setup
assert 'PathChanged=/var/lib/teko-agent-enrollment/control' in setup
assert 'process_control_requests(cfg)' in worker
print('agent_enrollment_delete_collapse_regression_test: PASS')
