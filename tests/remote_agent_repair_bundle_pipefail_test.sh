#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/setup_config_manager.sh"
grep -Fq 'REPAIR_CONTENTS="$REPAIR_TMP_DIR/repair-bundle.contents"' "$SCRIPT"
grep -Fq 'tar -tzf "${AGENT_REPAIR_BUNDLE}.tmp" > "$REPAIR_CONTENTS"' "$SCRIPT"
grep -Fq 'grep -Fx -- "$required" "$REPAIR_CONTENTS" >/dev/null' "$SCRIPT"
if grep -F 'tar -tzf "${AGENT_REPAIR_BUNDLE}.tmp" | grep -Fxq' "$SCRIPT" >/dev/null; then
  echo 'legacy pipefail-prone bundle check still present' >&2
  exit 1
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/teko-agent-bundle/config-agent"
touch "$TMP/teko-agent-bundle/setup_config_agent.sh" \
      "$TMP/teko-agent-bundle/setup_remote_config_agent.sh" \
      "$TMP/teko-agent-bundle/teko-stack.conf" \
      "$TMP/teko-agent-bundle/config-agent/VERSION"
tar -C "$TMP" -czf "$TMP/bundle.tar.gz" teko-agent-bundle
tar -tzf "$TMP/bundle.tar.gz" > "$TMP/list"
for required in teko-agent-bundle/setup_config_agent.sh teko-agent-bundle/setup_remote_config_agent.sh teko-agent-bundle/teko-stack.conf teko-agent-bundle/config-agent/VERSION; do
  grep -Fx -- "$required" "$TMP/list" >/dev/null
 done
echo 'remote_agent_repair_bundle_pipefail_test: PASS'
