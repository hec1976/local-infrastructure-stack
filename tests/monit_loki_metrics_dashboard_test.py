#!/usr/bin/env python3
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
d=json.loads((root/'observability/grafana/dashboards/teko-monit-prometheus.json').read_text())
assert d['title']=='TEKO Monit · System Health'
assert not (root/'observability/grafana/dashboards/teko-monit-logs.json').exists()
titles={p.get('title') for p in d['panels']}
for title in ['System CPU','System RAM / Swap','Host Response Time','Monit · Ereignisse nach Typ','Monit · Status / Event-Aktivität','Monit · aktuelle Probleme','Monit · aktuelle Recoveries','Monit · alle Ereignisse']:
    assert title in titles,title
for forbidden in ['Filesystem Belegung','Prozess RAM','Prozess CPU']:
    assert forbidden not in titles,forbidden
print('PASS: Monit System Health hybrid dashboard')
