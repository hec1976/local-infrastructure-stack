#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
setup=(r/'setup_config_manager.sh').read_text()
auth=(r/'bin/teko-observability-auth-sync.py').read_text()
tm=(r/'bin/teko-agent-token-manager.py').read_text()
reg=(r/'bin/teko-server-registry-write.py').read_text()
enroll=(r/'bin/teko-agent-enrollment-worker.py').read_text()
apache=(r/'bin/teko-apache-https.sh').read_text()
e2e=(r/'bin/teko-postinstall-test.sh').read_text()
assert not (r/'observability-ingest').exists()
assert not (r/'config-manager-standalone/standalone/observability_ingest.php').exists()
assert 'ProxyPass        /observability-ingest/loki/api/v1/push http://127.0.0.1:3100/loki/api/v1/push' in setup
assert 'ProxyPass        /observability-ingest/prometheus/api/v1/write http://127.0.0.1:9090/api/v1/write' in setup
assert 'AuthUserFile /opt/service/config-manager/observability.htpasswd' in setup
assert 'Require valid-user' in setup
assert 'systemctl disable --now observability-ingest.service' in setup
assert 'rm -rf /opt/service/observability-ingest' in setup
assert 'htpasswd' in auth and "{SHA}" in auth
assert 'OBS_AUTH_SYNC' in tm and 'sync_observability_auth()' in tm
assert 'teko-observability-auth-sync.py' in reg
assert 'teko-observability-auth-sync.py' in enroll
assert 'a2enmod auth_basic' in apache and 'a2enmod authn_file' in apache
assert 'observability-ingest.service active' not in e2e
print('observability_direct_proxy_31828_test: PASS')
