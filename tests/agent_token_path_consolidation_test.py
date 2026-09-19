#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
tm=(root/'bin/teko-agent-token-manager.py').read_text()
enroll=(root/'setup_agent_enrollment_manager.sh').read_text()
remote=(root/'setup_remote_config_agent.sh').read_text()
setup=(root/'setup_config_manager.sh').read_text()
runtime=(root/'config-manager-standalone/lib/config_manager_runtime.php').read_text()
canonical='/opt/service/config-manager/tokens'
assert "TOKEN_ROOT='/opt/service/config-manager/tokens/'" in tm
assert "/opt/service/env/agents/" in tm  # migration source only
assert 'return canonical_token_path(server)' in tm
assert canonical in enroll
assert canonical in remote
assert 'CONFIG_MANAGER_TOKEN_DIR=' in setup
assert 'PY_TOKEN_MIGRATE' in setup
assert "'runtime_available' => $runtimeAvailable" in runtime
assert "'runtime_error' => $runtimeError" in runtime
assert 'darf niemals das ganze Portal sperren' in runtime
print('agent_token_path_consolidation_test: PASS')
