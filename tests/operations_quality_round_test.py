#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
nav = json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())
ops = next((x for x in nav['items'] if x.get('key') == 'operations'), None)
assert ops and ops['href'] == 'operations' and ops['enabled'] is True

page = (root/'config-manager-standalone/public/operations.php').read_text()
for needle in [
    'Runtime vs. Sollzustand', 'Health &amp; Abhängigkeiten',
    'Backup / Restore Readiness', 'Audit-Trail', 'Config-Agent API /health',
    'desired_status', 'getAgentOverview()', 'getAgentHealth()', 'getModSecurityInfo()', 'getMonitStatus()'
]:
    assert needle in page, needle

repo = (root/'config-manager-standalone/Repository/ConfigManagerRepository.php').read_text()
service = (root/'config-manager-standalone/Service/ConfigManagerService.php').read_text()
agent = (root/'config-agent/lib/ConfigFiles.pm').read_text()
assert 'public function getAgentOverview()' in repo
assert 'public function getAgentHealth()' in repo
assert 'public function getAgentOverview()' in service
assert 'public function getAgentHealth()' in service
assert 'desired_status=>$desired_status' in agent
assert "$desired_status = 'running'" in agent
print('operations_quality_round_test: PASS')
