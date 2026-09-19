from pathlib import Path
import json
r=Path(__file__).resolve().parents[1]
s=(r/'setup_config_manager.sh').read_text()
assert 'apache2 apache2-mod_php8 apache2-utils' in s
assert '/var/lib/service/config-agent/identity.json' in s
assert 'lokaler Alloy-Host' in s
reg=(r/'bin/teko-server-registry-write.py').read_text()
assert 'subprocess' in reg.splitlines()[1] or 'subprocess' in reg.splitlines()[0] or 'subprocess' in reg[:200]
d=json.loads((r/'observability/grafana/dashboards/teko-alloy-journal.json').read_text())
assert d['uid']=='teko-alloy-journal'
blob=json.dumps(d)
assert 'source=\\"alloy\\"' in blob
assert 'job=\\"systemd-journal\\"' not in blob
assert 'hostname' in blob
ops=json.loads((r/'observability/grafana/dashboards/teko-operations-overview.json').read_text())
assert any(p.get('title')=='Alloy Journal' for p in ops['panels'])
print('PASS observability auth + Alloy Grafana 3.18.29')
