#!/usr/bin/env python3
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
dash=root/'observability/grafana/dashboards'
monit=sorted(p.name for p in dash.glob('teko-monit*.json'))
assert monit == ['teko-monit-prometheus.json'], monit
d=json.loads((dash/'teko-monit-prometheus.json').read_text())
assert d['uid']=='teko-monit-prometheus'
assert d['title']=='TEKO Monit · System Health'
titles={p.get('title') for p in d['panels']}
required=['System CPU','System RAM / Swap','Host Response Time','Monit · Ereignisse nach Typ','Monit · Status / Event-Aktivität','Monit · aktuelle Probleme','Monit · aktuelle Recoveries','Monit · alle Ereignisse']
for t in required: assert t in titles,t
for t in ['Prozess CPU','Prozess RAM','Filesystem Belegung']: assert t not in titles,t
setup=(root/'setup_observability.sh').read_text()
assert 'rm -f "$GRAFANA_DASHBOARDS"/teko-*.json' in setup
prov=(root/'observability/grafana/provisioning/dashboards/teko.yaml').read_text()
assert 'disableDeletion: false' in prov
imp=(root/'observability/system-loki-importer.py').read_text()
assert 'MONIT_METRICS_URL' in imp and 'event_type' in imp and 'monit_object' in imp
print('PASS: one Monit dashboard; working system metrics + event views; stale dashboard cleanup enabled')
