#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
setup = (root / 'teko-forgejo-local/setup_forgejo_teko.sh').read_text()
boot = (root / 'bin/forgejo-bootstrap-teko.sh').read_text()
conf = (root / 'teko-stack.conf').read_text()

checks = {
    'INSTALL_LOCK im Quadlet': 'FORGEJO__security__INSTALL_LOCK=true' in setup,
    'Forgejo Restart nach Quadlet': 'systemctl restart forgejo.service' in setup,
    'CLI/SQLite Readiness': 'forgejo_cli admin user list' in boot and 'CLI_READY' in boot,
    'Admin Greenfield Create': '--admin' in boot and 'FORGEJO_ADMIN_PASSWORD' in boot,
    'Admin-Datei 0600': 'chmod 0600 "$tmp"' in boot and 'forgejo-admin.env' in conf,
    'REST API Readiness': '/api/v1/version' in boot and 'API_READY' in boot,
    'Bestehender Admin wird erkannt': 'EXISTING_ADMIN' in boot,
    'Org/Repo Bootstrap bleibt': 'Organisation' in boot and 'Repository' in boot,
}
failed = [k for k,v in checks.items() if not v]
for k,v in checks.items():
    print(('[PASS] ' if v else '[FAIL] ') + k)
if failed:
    raise SystemExit('Fehlende Greenfield-Checks: ' + ', '.join(failed))
