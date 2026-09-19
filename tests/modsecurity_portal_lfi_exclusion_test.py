from pathlib import Path

root = Path(__file__).resolve().parents[1]
s = (root / 'setup_config_manager.sh').read_text(encoding='utf-8')

# The exclusion must be narrow: only the two server-side allow-listed config ID
# parameters, only the LFI rule family, and only the Config Manager index route.
assert '<Location "/index.php">' in s
assert 'SecRuleUpdateTargetByTag "attack-lfi" "!ARGS:config_name"' in s
assert 'SecRuleUpdateTargetByTag "attack-lfi" "!ARGS:config_names"' in s
assert 'SecRuleRemoveById 949110' not in s
assert 'SecRuleRemoveByTag "attack-lfi"' not in s
assert 'SecAction' not in s[s.index('# OWASP CRS False-Positive-Ausnahme'):s.index('# standalone/, config/ und lib/')]
assert 'config_name/config_names gegen' in s
print('modsecurity_portal_lfi_exclusion_test: PASS')
