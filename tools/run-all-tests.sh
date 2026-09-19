#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export ROOT
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
from pathlib import Path
import json, os, shutil, subprocess, sys
root=Path(os.environ['ROOT']).resolve()
tests=[]
for base in [root/'tests', root/'config-manager-standalone/tests']:
    if not base.is_dir():
        continue
    for p in base.iterdir():
        if p.is_file() and p.suffix in {'.py','.sh','.php','.js'} and p.name != 'sandbox_test.sh':
            tests.append(p)
tests=sorted(tests)
results=[]
for p in tests:
    rel=p.relative_to(root)
    cwd=root
    target=str(rel)
    if str(rel).startswith('config-manager-standalone/tests/'):
        cwd=root/'config-manager-standalone'
        target=str(Path('tests')/p.name)
    missing=[]
    if p.suffix=='.py':
        cmd=['python3',target]
    elif p.suffix=='.sh':
        cmd=['bash',target]
        source=p.read_text(encoding='utf-8',errors='ignore')
        for command in ('php','node','perl'):
            if command in source and shutil.which(command) is None:
                missing.append(command)
    elif p.suffix=='.js':
        cmd=['node',target]
        if shutil.which('node') is None:
            missing.append('node')
    else:
        cmd=['php','-d','zend.assertions=1','-d','assert.exception=1',target]
        if shutil.which('php') is None:
            missing.append('php')
        if p.name in {'desired_state_logic_test.php','fleet_registry_test.php'}:
            cmd.append(str(root))
    note=''
    if missing:
        rc=127
        out=''
        status='SKIP'
        note='missing runtime: '+', '.join(sorted(set(missing)))
    else:
        try:
            cp=subprocess.run(cmd,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=35)
            rc=cp.returncode; out=cp.stdout
        except subprocess.TimeoutExpired as e:
            rc=124
            out=((e.stdout or '') if isinstance(e.stdout,str) else '')+'\nTIMEOUT after 35s\n'
        status='PASS' if rc==0 else 'FAIL'
    if rc!=0 and p.name=='config_manager_distribution_integration.sh' and shutil.which('php') is not None:
        mods=subprocess.run(['php','-m'],stdout=subprocess.PIPE,text=True).stdout.lower().split()
        if 'curl' not in mods:
            status='SKIP'; note='PHP curl extension not installed in build environment'
    results.append({'test':str(rel),'status':status,'rc':rc,'note':note,'output':out[-4000:]})
    label=f"[{status}] {rel}"
    if note: label+=f" ({note})"
    print(label)
    if status=='FAIL':
        print(out[-4000:])
summary={s:sum(1 for x in results if x['status']==s) for s in ('PASS','FAIL','SKIP')}
print(f"SUMMARY: {summary['PASS']} PASS / {summary['FAIL']} FAIL / {summary['SKIP']} SKIP")
report=Path(os.environ.get('TEST_REPORT_PATH',str(root/'reports'/'TEST_RESULTS.json')))
report.parent.mkdir(parents=True,exist_ok=True)
report.write_text(json.dumps({'summary':summary,'results':results},indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
print(f"REPORT: {report}")
sys.exit(1 if summary['FAIL'] else 0)
PY

echo
if command -v php >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  bash "$ROOT/tests/sandbox_test.sh"
else
  echo "[SKIP] tests/sandbox_test.sh (PHP CLI und/oder Node.js fehlt)"
fi
