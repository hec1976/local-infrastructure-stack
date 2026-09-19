#!/usr/bin/env python3
from pathlib import Path
import ast,json,re
root=Path(__file__).resolve().parents[1]
worker=(root/"bin/teko-agent-enrollment-worker.py").read_text()
setup=(root/"setup_agent_enrollment_manager.sh").read_text()
remote=(root/"setup_remote_config_agent.sh").read_text()
page=(root/"config-manager-standalone/public/agent_enrollment.php").read_text()
nav=json.loads((root/"config-manager-standalone/config/module_navigation.json").read_text())
master=(root/"setup_teko_local.sh").read_text()

ast.parse(worker)
for x in [
 "PasswordAuthentication=no","PasswordAuthentication=yes","PubkeyAuthentication=no",
 "KbdInteractiveAuthentication=no","StrictHostKeyChecking=yes",
 "expected_host_key_sha256","ssh-keyscan","SSH host key fingerprint mismatch",
 "fcntl.flock","atomic_json","token_file","ca_file",
 "manager_ip does not match root-owned enrollment config",
 "sshpass","pass_fds","delete_secret","auth_mode"
]:
    assert x in worker,x

# Password auth exists; its secret must not enter job JSON, status or audit payloads. Host-key input may be optional only in password mode.
assert 'type="password"' in page
assert "'auth_mode'=>$authMode" in page
assert "ae_write_secret" in page
assert "unset($j['expected_host_key_sha256'],$j['ssh_password'],$j['secret_file'])" in page
assert "Password and fingerprint are intentionally excluded from audit payloads" in page
assert "'ssh_password'=>$password" not in page
assert '"ssh_password"' not in worker

for x in [
 "Managed Hosts – Enrollment","Bootstrap Public Key","Agent installieren & registrieren",
 "expected_host_key_sha256","canary","agent_enrollment_queue","csrf_token",
 "SSH Authentifizierung","SSH-Key","Passwort","Enrollment Status"
]:
    assert x in page,x

# Worker is root only and GUI cannot send arbitrary command/options.
assert "os.geteuid()!=0" in worker
assert 'j["command"]' not in worker
assert "ssh_options" not in worker
assert "shell=True" not in worker

for x in [
 "ssh-keygen","sshpass","teko-agent-enrollment.path","teko-agent-enrollment.service",
 "ProtectSystem=strict","NoNewPrivileges=true","teko-agent-bundle.tar.gz","secret_dir"
]:
    assert x in setup,x

assert "CONFIG_AGENT_REMOTE_MODE=1" in remote
assert "setup_agent_enrollment_manager.sh" in master
assert any(i["key"]=="agent_enrollment" and i["href"]=="agent_enrollment" for i in nav["items"])
print("agent_enrollment_feature_test: OK")
