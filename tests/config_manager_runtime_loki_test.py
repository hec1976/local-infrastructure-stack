from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
ap=(root/'observability/apache-loki-importer.py').read_text()
assert "return 'config-manager'" in ap
assert "'service':job" in ap
dash=json.loads((root/'observability/grafana/dashboards/teko-config-manager-runtime.json').read_text())
exprs='\n'.join(t.get('expr','') for p in dash.get('panels',[]) for t in p.get('targets',[]))
assert 'job="config-manager"' in exprs
assert any(p.get('title')=='Config Manager · Runtime Log' for p in dash.get('panels',[]))
print('config-manager runtime Loki: PASS')
