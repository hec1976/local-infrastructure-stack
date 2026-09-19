from pathlib import Path
import json
r=Path(__file__).resolve().parents[1]
alloy=json.loads((r/"observability/grafana/dashboards/teko-alloy-journal.json").read_text())
blob=json.dumps(alloy)
assert 'source=\\"alloy\\"' in blob
assert 'job=\\"systemd-journal\\"' not in blob
assert 'label_values({source=\\"alloy\\"}, hostname)' in blob
ops=json.loads((r/"observability/grafana/dashboards/teko-operations-overview.json").read_text())
ops_blob=json.dumps(ops)
assert 'source=\\"alloy\\"' in ops_blob
assert 'job=\\"systemd-journal\\"' not in ops_blob
print("PASS Alloy Grafana stable source label 3.18.32")
