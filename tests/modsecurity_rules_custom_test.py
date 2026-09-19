#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
pm=(r/'config-agent/lib/ModSecurity.pm').read_text()
ui=(r/'config-manager-standalone/public/modsecurity.php').read_text()
assert "get '/modsecurity/rules'" in pm
assert "get '/modsecurity/custom-rules'" in pm
assert "post '/modsecurity/custom-rules'" in pm
assert 'teko-custom-rules.conf' in pm
assert '_ms_loaded_rules' in pm
assert 'CRS-Regeln' in ui and 'Custom Rules' in ui
assert 'data-rule' in ui
print('PASS modsecurity rule browser/custom rules')
