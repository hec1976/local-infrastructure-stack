from pathlib import Path
root=Path(__file__).resolve().parents[1]
fm=(root/'config-manager-standalone/public/file_manager.php').read_text()
fw=(root/'config-manager-standalone/public/firewall.php').read_text()
for needle in ['id="back"','id="forward"','id="up"','id="crumbs"','id="filter"','fm-breadcrumb','Neue Datei','Expert-Override']:
    assert needle in fm, needle
for needle in ['id="portNumber"','id="portProto"','id="zoneSourceIp"','id="zoneSourcePrefix"','id="spIp"','id="spPrefix"','id="spPort"','id="spProto"','id="serviceName"','data-kind="rich_rule"','function buildValue()']:
    assert needle in fw, needle
assert 'data-kind="source"' not in fw
assert 'placeholder="z. B. 443/tcp, ssh, 192.168.1.0/24"' not in fw
print('ui_file_manager_firewall_3184_test: PASS')
