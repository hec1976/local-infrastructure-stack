from pathlib import Path
import json,re
root=Path(__file__).resolve().parents[1]
agent=(root/'config-agent/lib/Fail2Ban.pm').read_text()
main=(root/'config-agent/config-agent.pl').read_text()
page=(root/'config-manager-standalone/public/fail2ban.php').read_text()
service=(root/'config-manager-standalone/Service/ConfigManagerService.php').read_text()
nav=json.loads((root/'config-manager-standalone/config/module_navigation.json').read_text())
assert 'require Fail2Ban;' in main
for route in ['/fail2ban/info','/fail2ban/install','/fail2ban/config','/fail2ban/unban']:
    assert route in agent
assert 'fail2ban-client' in agent and "'-t'" in agent
# Generic templates and arbitrary managed jails.
for template in ['sshd','apache-auth','nginx-http-auth','postfix-sasl','dovecot','recidive','modsecurity','web-scanner','custom']:
    assert f"id=>'{template}'" in agent
assert 'Maximal 64 verwaltete Fail2ban-Jails' in agent
assert 'cm-managed-' in agent
assert 'Failregex für $name muss <HOST> enthalten' in agent
assert 'Logpfad muss unter /var/log liegen' in agent
# Generic page must expose the four operational views.
for text in ['Jails','Filter','Gebannte IPs','Globale Einstellungen','Jail hinzufügen','Failregex','Ignoreregex','Logpath','Backend','Action']:
    assert text in page
assert 'Lokale Fail2ban-Konfiguration' not in page
# Browser can submit generic jails, while server validates names, paths, actions and regexes.
assert "count($jails)>64" in service
assert "Failregex für '.$name.' muss <HOST> enthalten" in service
assert "preg_match('/^[A-Za-z0-9_.-]{1,64}$/',$jail)" in service
assert any(x.get('key')=='fail2ban' and x.get('group')=='Security' for x in nav['items'])
print('fail2ban_feature_test: PASS')
