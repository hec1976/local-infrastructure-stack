#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
agent=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
page=(r/'config-manager-standalone/public/client_baseline.php').read_text()
auth=(r/'bin/teko-observability-auth-sync.py').read_text()
feedback=(r/'config-manager-standalone/public/assets/mmbb-feedback.js').read_text()
setup=(r/'setup_config_manager.sh').read_text()
assert 'Bestehende HTTP-Definitionen' in agent
assert 'Monit HTTP ist bereits in der Hauptkonfiguration definiert' not in agent
assert 'set httpd' in agent and 'managed by Config Manager baseline' in agent
assert '_pb_alloy_current' in agent
assert 'staged=>true()' in agent
assert 'OBSERVABILITY_INGEST_PASSWORD' in agent
assert "$api_token" in agent
assert 'observability_defaults' not in page
assert 'Baseline Paket-Repository' not in page
assert 'observability-client' in page
assert 'https://rpm.grafana.com' not in agent
assert 'saveAlloy' not in page
assert 'observability.htpasswd' in setup
assert '/observability-ingest/loki/api/v1/push http://127.0.0.1:3100/loki/api/v1/push' in setup
assert '/observability-ingest/prometheus/api/v1/write http://127.0.0.1:9090/api/v1/write' in setup
assert 'AuthBasicProvider file' in setup and 'Require valid-user' in setup
assert 'host_id' in auth and 'token_file' in auth
assert 'var busyOps = new Map()' in feedback
assert 'window.mmbbBusyReset' in feedback
assert "window.addEventListener('pagehide', resetBusy)" in feedback
assert 'CONFIG_MANAGER_PUBLIC_BASE_URL=https://%s' in setup
print('baseline_3141_regression_test: PASS')
