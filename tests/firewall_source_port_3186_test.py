from pathlib import Path
agent=Path('config-agent/lib/Firewall.pm').read_text()
ui=Path('config-manager-standalone/public/firewall.php').read_text()
assert 'source_port' in agent
assert '--${action}-rich-rule' in agent
assert 'Port + Quelle' in ui
for x in ['spIp','spPrefix','spPort','spProto']:
    assert x in ui
print('firewall_source_port_3186_test: PASS')
