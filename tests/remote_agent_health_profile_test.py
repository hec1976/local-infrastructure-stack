from pathlib import Path
root=Path(__file__).resolve().parents[1]
core=(root/'config-agent/lib/Core.pm').read_text()
cf=(root/'config-agent/lib/ConfigFiles.pm').read_text()
routes=(root/'config-agent/lib/Routes.pm').read_text()
setup=(root/'setup_config_agent.sh').read_text()
remote=(root/'setup_remote_config_agent.sh').read_text()
ini=(root/'config-agent/service-install.ini').read_text()
assert 'sub _is_declared_hard_protected_path' in core
assert '_is_declared_hard_protected_path($target)' in cf
assert 'optional/nicht installiert' in routes
assert 'git_upload["enabled"] = True' in setup
assert 'git_deploy["enabled"] = True' in setup
assert 'cfg.pop("file_manager_roots", None)' in setup
assert 'CONFIG_AGENT_FORGEJO_TOKEN_FILE' in remote
assert 'out={"config-agent-global": e}' in remote
assert 'REMOTE_PROFILE_RESET' in remote
assert 'required_files =' in ini and 'required_files = /opt/service/env/forgejo-api.token' not in ini
print('remote_agent_health_profile_test: PASS')
