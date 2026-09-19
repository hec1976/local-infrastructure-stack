#!/usr/bin/env python3
from pathlib import Path
root = Path(__file__).resolve().parents[1]
routes = (root/'config-agent/lib/Routes.pm').read_text()
ops = (root/'config-manager-standalone/public/operations.php').read_text()
assert 'elsif ($auto_create_backup_subdirs)' in routes
assert 'noch kein Backup; Verzeichnis wird beim ersten Backup angelegt' in routes
assert 'Backup-Dir fehlt und auto_create_backups ist deaktiviert' in routes
assert "errors   => \\@errors" in routes
assert "warnings => \\@warnings" in routes
assert "info     => \\@info" in routes
assert "status=>(@errors ? 503 : 200)" in routes
assert 'backup_dirs_lazy' in routes and 'auto_create_backups' in routes
assert "$healthWarnings" in ops and "$healthInfo" in ops
assert "Config(s) noch ohne Backup" in ops
setup = (root/'setup_config_agent.sh').read_text()
assert 'cfg.setdefault("auto_create_backups", True)' in setup
print('health_backup_lazy_dirs_test: PASS')
