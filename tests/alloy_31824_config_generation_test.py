#!/usr/bin/env python3
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
pm=(root/'config-agent/lib/PlatformBaseline.pm').read_text()
sh=(root/'baseline-repository/SOURCES/configure-observability-client.sh').read_text()
drop=(root/'baseline-repository/SOURCES/alloy-baseline.conf').read_text()
# Config-Agent generator must not emit Alloy-invalid shell-style comments.
assert '$txt.="# Workload-specific' not in pm
assert '// Workload-specific log sources' in pm
# Both endpoint families must remain plain URLs, never Markdown links.
for text in (pm, sh):
    assert '[https://' not in text
    assert '](https://' not in text
assert 'https://config-manager.local/observability-ingest/loki/api/v1/push' in sh
assert 'https://config-manager.local/observability-ingest/prometheus/api/v1/write' in sh
# Runtime service must receive ingest credentials.
assert 'EnvironmentFile=-/var/lib/service/config-agent/secrets/alloy-observability.env' in drop
# Journal access must follow the detected service account.
assert 'usermod -aG "$g" "$ALLOY_USER"' in sh
# Stable query labels in both generators.
assert "source=>'alloy'" in pm and "job=>'systemd-journal'" in pm
assert 'source = "alloy", job = "systemd-journal"' in sh
print('alloy 3.18.24 config generation regression: OK')
