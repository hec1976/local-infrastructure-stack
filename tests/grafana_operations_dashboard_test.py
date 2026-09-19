#!/usr/bin/env python3
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
D=ROOT/'observability/grafana/dashboards'
ops=json.loads((D/'teko-operations-overview.json').read_text())
titles={p.get('title') for p in ops.get('panels',[])}
required={'Postfix','Monit','Apache','ModSecurity','Config Manager','Audit','Service Logaktivität'}
assert not (required-titles), sorted(required-titles)
expected={
 'teko-postfix.json':('TEKO Postfix','job="postfix"'),
 'teko-monit-prometheus.json':('TEKO Monit · System Health','service="monit"'),
 'teko-apache-logs.json':('TEKO Apache','job="apache"'),
 'teko-modsecurity.json':('TEKO ModSecurity','job="modsecurity"'),
 'teko-config-manager-runtime.json':('TEKO Config Manager','job="config-manager"'),
 'teko-config-manager-audit.json':('TEKO Config Manager · Audit','job="config-manager-audit"'),
}
for fn,(title,needle) in expected.items():
 d=json.loads((D/fn).read_text()); assert d['title']==title; assert d.get('panels')
 exprs='\n'.join(t.get('expr','') for p in d['panels'] for t in p.get('targets',[]))
 assert needle in exprs, (fn,needle)
print('PASS: service-separated Grafana dashboards')
