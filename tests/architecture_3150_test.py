#!/usr/bin/env python3
from pathlib import Path
import json
r=Path(__file__).resolve().parents[1]
core=(r/'config-agent/lib/Core.pm').read_text()
base=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
fm=(r/'config-agent/lib/FileManager.pm').read_text()
setup=(r/'setup_config_manager.sh').read_text()
enroll=(r/'bin/teko-agent-enrollment-worker.py').read_text()
vers=json.loads((r/'VERSIONS.json').read_text())
assert tuple(map(int,vers['stack'].split('.'))) >= (3,15,0)
assert '/var/lib/service/config-agent/secrets/monit-status.env' in base
assert '/opt/service/env/monit-status.env' in base  # legacy read-only migration fallback
assert 'CONFIG_AGENT_TOKEN_SCOPES' in core and 'baseline.manage' in core and 'security.manage' in core
assert '_fm_ownership' in fm and 'Expert-Override' in fm
assert 'host_id' in enroll and 'CONFIG_AGENT_LABELS_JSON' in enroll
assert 'observability-ingest.service' in setup  # migration cleanup only
assert 'ProxyPass        /observability-ingest/loki/api/v1/push' in setup
assert 'ProxyPass        /observability-ingest/prometheus/api/v1/write' in setup
assert not (r/'observability-ingest').exists()
assert (r/'bin/sync-versions.py').is_file()
print('architecture_3150_test: PASS')
