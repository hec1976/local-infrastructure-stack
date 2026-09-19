from pathlib import Path
p=Path(__file__).resolve().parents[1]/'config-manager-standalone/public/package_management.php'
s=p.read_text()
checks={
 'large preview': 'pm-preview-main{min-height:500px}' in s,
 'progress container': 'id="jobProgress"' in s,
 'progress bar': 'id="jobProgressBar"' in s,
 'progress phases': 'Paketaktion läuft' in s and 'Zielsysteme werden geprüft' in s,
 'button locking': 'runBtn.disabled=true' in s and 'runBtn.disabled=false' in s,
 'completion 100': 'setJobProgress(100' in s,
}
for k,v in checks.items(): print(f"[{'PASS' if v else 'FAIL'}] {k}")
if not all(checks.values()): raise SystemExit(1)
print('PACKAGE PROGRESS UI RESULT: PASS')
