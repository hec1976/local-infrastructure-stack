#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
pm=(root/'config-agent/lib/Fail2Ban.pm').read_text()
php=(root/'config-manager-standalone/public/fail2ban.php').read_text()
assert "if (_f2b_installed())" in pm
fast=pm.split("sub _f2b_install_info {",1)[1].split("my $os=",1)[0]
assert "_pkg_preview" not in fast
assert "installed=>true()" in fast
assert "Fail2ban-Status wird geladen" in php
assert "Fail2ban-Abfrage dauert länger als erwartet" in php
assert "Fail2ban-Status geladen (${elapsed} ms)" in php
print('fail2ban 3.18.23 performance/UI regression: OK')
