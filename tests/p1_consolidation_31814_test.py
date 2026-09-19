#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
fg=(r/'bin/forgejo-bootstrap-teko.sh').read_text()
agent=(r/'setup_config_agent.sh').read_text()
remote=(r/'setup_remote_config_agent.sh').read_text()
e2e=(r/'bin/teko-postinstall-test.sh').read_text()
# curl rc must be captured from curl itself, not from ! curl
assert 'if ! curl -fsS --connect-timeout 8 --max-time 20' not in fg
assert 'curl_rc=$?' in fg and 'return "$curl_rc"' in fg
# Agent lifecycle cannot be blocked by an unrelated stale observability repo
assert 'zypper --non-interactive mr -d infrastructure-baseline' in agent
assert 'restore_optional_repo' in agent
# Remote rollout repairs wrong control-plane name mapping, not just missing DNS
assert 'getent ahostsv4 "$name"' in remote
assert 'managed by config-agent enrollment' in remote
# E2E release gate covers the new observability core
for marker in ['prometheus.service','alloy.service','Prometheus ready','Grafana Alloy active','Apache Observability Auth-Datei vorhanden']:
    assert marker in e2e, marker
print('p1_consolidation_31814_test: PASS')
