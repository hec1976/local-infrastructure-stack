#!/usr/bin/env python3
from pathlib import Path
import json, xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
agent=(root/'config-agent/lib/MonitStatus.pm').read_text()
portal=(root/'config-manager-standalone/public/monit_status.php').read_text()
repo=(root/'config-manager-standalone/Repository/ConfigManagerRepository.php').read_text()
nav=json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())
setup=(root/'setup_config_agent.sh').read_text()
post=(root/'bin/teko-postinstall-test.sh').read_text()
assert "get '/monit/status'" in agent
assert "127.0.0.1:2812/_status?format=xml&level=full" in agent
assert "Monit URL muss localhost/loopback sein" in agent
assert "XML::LibXML" in agent and "perl-XML-LibXML" in setup
assert "function getMonitStatus" in repo and "'/monit/status'" in repo
assert "Server Health" in portal and "Auto 30s" in portal
assert '<h3 class="mb-1">Monit Status</h3>' not in portal
assert "Zentrale Live-Übersicht aller registrierten Server" not in portal
assert "Promise.allSettled" in portal and "api=server" in portal
assert "Überwachte Services" in portal and "allServicesBody" in portal
assert portal.index('Server-Details') < portal.index('Überwachte Services')
assert "serviceTypeFilter" in portal and "serviceStatusFilter" in portal and "serviceServerFilter" in portal
assert "serviceState" in portal and "nicht überwacht" in portal
assert "groups => \\@groups" in agent
assert any(i.get('key')=='monit_status' and i.get('label')=='Server Health' and i.get('group')=='Monitoring' for i in nav['items'])
assert 'Monit Status API -> XML gelesen/normalisiert' in post
# Fixture coverage: all Monit service types are present and basic fields parse.
xml=ET.parse(root/'monit-exporter/testdata/all-types.xml').getroot()
services=xml.findall('service')
assert {int(x.attrib['type']) for x in services} == set(range(9))
assert len(services)==9
print('PASS: Monit multi-server status dashboard with all services')
