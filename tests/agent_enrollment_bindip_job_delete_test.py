from pathlib import Path
p=Path(__file__).resolve().parents[1]/'config-manager-standalone/public/agent_enrollment.php'
s=p.read_text(encoding='utf-8')
checks=[
    "id=\"sshHost\"",
    "id=\"bindIp\"",
    "function syncBindFromSsh()",
    "Agent Bind-IP entspricht der Manager-IP",
    "api=delete_job",
    "Job löschen",
    "Ein laufender Enrollment-Job kann nicht gelöscht werden",
    "agent_enrollment_delete",
]
missing=[x for x in checks if x not in s]
if missing:
    raise SystemExit('missing: '+', '.join(missing))
print('agent_enrollment_bindip_job_delete_test: PASS')
