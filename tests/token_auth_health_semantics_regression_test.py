#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
py=(root/'bin/teko-agent-token-manager.py').read_text()
php=(root/'config-manager-standalone/public/server_management.php').read_text()
assert "api.get('authenticated') is True" in py
assert "api.get('authenticated') is False" in py
assert "Agent-API konnte nicht verifiziert werden" in py
assert "Auth nicht verifiziert" in php
assert "else if(a.authenticated===false)bits.push('Auth FEHLER')" in php
assert "else if(a.authenticated===true)bits.push('Health FEHLER'" in php
print('token_auth_health_semantics_regression_test: PASS')
