from pathlib import Path
agent=Path('config-agent/lib/Firewall.pm').read_text()
ui=Path('config-manager-standalone/public/firewall.php').read_text()
assert 'my $FW_INFO_CACHE_TTL = 4;' in agent
assert 'sub _fw_cache_invalidate' in agent
assert "my $pkg = $backend eq 'firewalld'" in agent
assert "? {supported=>true(),package=>'firewalld',installed=>true(),available=>true(),versions=>[]}" in agent
assert 'info=>_fw_info()' not in agent
assert "_fw_cache_invalidate();" in agent
assert 'id="fwBusy"' in ui
assert "function busy(text='Firewall-Status wird geladen …')" in ui
assert 'Die Abfrage dauert länger als erwartet.' in ui
assert 'Firewall-Status geladen (${ms} ms).' in ui
assert "busy(`Interface ${nic} wird ${zone} zugewiesen …`)" in ui
assert "busy(action==='add'?'Firewall-Regel wird angewendet …':'Firewall-Regel wird entfernt …')" in ui
print('PASS')
