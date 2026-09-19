#!/usr/bin/env python3
from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
nav=json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())
page=(root/'config-manager-standalone/public/managed_hosts.php').read_text()
tabs=(root/'config-manager-standalone/standalone/layout/managed_hosts_tabs.php').read_text()
baseline=(root/'config-manager-standalone/public/client_baseline.php').read_text()
health=(root/'config-manager-standalone/public/monit_status.php').read_text()
items={x['key']:x for x in nav['items']}
assert items['managed_hosts']['enabled'] is True
assert items['managed_hosts']['group']=='Server Management'
assert items['agent_enrollment']['enabled'] is False
assert items['server_management']['enabled'] is False
assert items['client_baseline']['enabled'] is False
assert items['package_management']['group']=='Server Management'
assert items['monit_status']['label']=='Server Health'
for label in ['Übersicht','Enrollment','Baseline','Registry']:
    assert label in tabs
for step in ['Enrollment','Baseline','Konfiguration','Server Health']:
    assert step in page
assert 'Config Manager → Config Agent → lokaler Dienst' in page
assert 'DEFAULT_SERVER' in baseline
assert 'Port 2812 muss nicht zentral erreichbar sein' in health
print('managed_hosts_architecture_3137_test: PASS')
