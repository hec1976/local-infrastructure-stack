#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
agent=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
status=(r/'config-agent/lib/MonitStatus.pm').read_text()
page=(r/'config-manager-standalone/public/client_baseline.php').read_text()
service=(r/'config-manager-standalone/Service/ConfigManagerService.php').read_text()
assert '/var/lib/service/config-agent/secrets/monit-status.env' in agent
assert 'MONIT_USER=' in agent and 'MONIT_PASSWORD=' in agent
assert "post '/baseline/monit-test'" in agent
assert 'Authorization' in status and 'encode_base64' in status
assert 'credentials_file' in status
assert 'Passwort setzen / rotieren' in page
assert 'Verbindung testen' in page
assert 'secret_present' in page and 'monitSecretPath' in page
assert "testClientMonitBaseline" in service
assert "($pass!==''" in service
print('monit_credentials_3140_test: PASS')
