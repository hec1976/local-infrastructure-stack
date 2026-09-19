#!/usr/bin/env python3
from pathlib import Path
import ast

root = Path(__file__).resolve().parents[1]
imp = root / 'observability/system-loki-importer.py'
setup = (root / 'setup_observability.sh').read_text(encoding='utf-8')
src = imp.read_text(encoding='utf-8')
ast.parse(src)
assert "return 'postfix'" in src
assert "return 'monit'" in src
assert "SYSLOG_IDENTIFIER" in src
assert "__CURSOR" in src and "--after-cursor" in src
assert "job': job" in src or "'job': job" in src
assert 'teko-system-loki-importer.service' in setup
assert 'systemctl restart teko-loki-importer.service teko-apache-loki-importer.service' in setup
assert 'systemctl restart teko-system-loki-importer.service' in setup
assert 'time.time_ns' not in src
print('PASS: Postfix/Monit journald Loki importer + restart regression')
# openSUSE/Python 3.6 runtime compatibility
assert 'text=True' not in imp.read_text()
assert 'universal_newlines=True' in imp.read_text()
