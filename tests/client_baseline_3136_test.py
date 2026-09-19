#!/usr/bin/env python3
from pathlib import Path
import json
r=Path(__file__).resolve().parents[1]
agent=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
page=(r/'config-manager-standalone/public/client_baseline.php').read_text()
nav=json.loads((r/'config-manager-standalone/config/module_navigation.json').read_text())
assert "get '/baseline/info'" in agent
assert "post '/baseline/monit-config'" in agent
assert 'allow localhost' in agent and 'allow $user:' in agent and '$password' in agent
assert 'Software-Rollout erfolgt ausschliesslich über Deploy-Profile / Git Deploy.' in page
assert 'Monit-Paket, Exporter und Alloy werden hier <strong>nicht</strong> installiert' in page
assert any(x.get('key')=='client_baseline' and not x.get('enabled') for x in nav['items'])
assert any(x.get('key')=='managed_hosts' and x.get('enabled') and x.get('group')=='Server Management' for x in nav['items'])
print('client_baseline_3136_test: PASS')
