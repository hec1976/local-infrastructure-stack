from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
nav=json.loads((ROOT/'config-manager-standalone/config/module_navigation.json').read_text())
items={x['key']:x for x in nav['items']}
assert 'security_policies' not in items
assert items['firewall']['enabled'] is True
assert items['fail2ban']['enabled'] is True
assert not (ROOT/'config-manager-standalone/public/security_policies.php').exists()
fw=(ROOT/'config-manager-standalone/public/firewall.php').read_text()
assert 'firewall.php?api=load&server=' in fw
assert "action:'change'" in fw
assert 'rich_rule' in fw
f2=(ROOT/'config-manager-standalone/public/fail2ban.php').read_text()
assert 'Security Policy' not in f2
assert "new URLSearchParams(location.search).get('server')" in f2
mon=(ROOT/'config-manager-standalone/public/monit_status.php').read_text()
assert 'firewall.php?server=${encodeURIComponent(srv.name)}' not in mon
assert 'fail2ban.php?server=${encodeURIComponent(srv.name)}' not in mon
assert 'package_management.php?server=${encodeURIComponent(srv.name)}' not in mon
assert 'überwachte Services und Systemstatus anzeigen.' in mon
agent=(ROOT/'config-agent/lib/Firewall.pm').read_text()
assert "post '/firewall/change'" in agent
assert 'rich_rules' in agent
print('server_security_tools_3134_test: OK')
