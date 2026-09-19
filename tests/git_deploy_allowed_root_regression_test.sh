#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -q 'install -d -o root -g root -m 0755 /opt/service /opt/service_script /opt/mmbb_services /opt/mmbb_script' "$ROOT/setup_config_agent.sh"
grep -q 'git_deploy\["enabled"\] = True' "$ROOT/setup_config_agent.sh"
grep -q 'for canonical_root in ("/opt/service", "/opt/service_script", "/opt/mmbb_services", "/opt/mmbb_script")' "$ROOT/setup_config_agent.sh"
grep -q "deployments\['settings_error'\]" "$ROOT/config-manager-standalone/public/git_deploy.php"
grep -q '"/opt/mmbb_services"' "$ROOT/config-agent/example/global.json.example"
grep -q '"/opt/mmbb_script"' "$ROOT/config-agent/example/global.json.example"
echo 'PASS: canonical + MMBB Git-Deploy roots + degraded error surfacing'
