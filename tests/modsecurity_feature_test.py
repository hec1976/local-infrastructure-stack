#!/usr/bin/env python3
from pathlib import Path
import json,re
root=Path(__file__).resolve().parents[1]
agent=(root/"config-agent/lib/ModSecurity.pm").read_text()
main=(root/"config-agent/config-agent.pl").read_text()
repo=(root/"config-manager-standalone/Repository/ConfigManagerRepository.php").read_text()
svc=(root/"config-manager-standalone/Service/ConfigManagerService.php").read_text()
ctl=(root/"config-manager-standalone/Controller/ConfigManagerController.php").read_text()
page=(root/"config-manager-standalone/public/modsecurity.php").read_text()
nav=json.loads((root/"config-manager-standalone/config/module_navigation.json").read_text())
harness=(root/"tests/config_manager_distribution_integration.sh").read_text()

for x in [
    "libapache2-mod-security2","modsecurity-crs","apache2-mod_security2","mod_security",
    "/modsecurity/info","/modsecurity/config","/modsecurity/install",
    "DetectionOnly","RelevantOnly","SecRuleRemoveById","SecRequestBodyLimit",
    "_ms_apache_test","Änderung zurückgerollt","_ms_prepare_debian_layout",
    "modsecurity.conf-recommended","a2enmod","_pkg_mutate","RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf","BEGIN TEKO MANAGED RULE EXCLUSIONS"
]:
    assert x in agent,x

assert "system(" not in agent
assert "qx/" not in agent
assert "shell=True" not in agent
assert "Maximal 200 Rule-Ausnahmen" in agent
assert "/run/teko-config-agent-modsecurity.lock" in agent
assert "require ModSecurity;" in main

for x in ["getModSecurityInfo","getModSecurityConfig","installModSecurity","saveModSecurityConfig"]:
    assert x in repo and x in svc and x in ctl,x

for x in ["ModSecurity / OWASP CRS","confirm_install","excluded_rule_ids","Keine freie ModSecurity-/Apache-Syntax","CSRF"]:
    assert x.lower() in page.lower(),x

assert any(i.get("key")=="modsecurity" and i.get("href")=="modsecurity" for i in nav["items"])

# Regression: audit bootstrap must precede autoloader in synthetic distribution harness.
audit=harness.index("standalone/standalone/audit.php")
autoload=harness.index("config-manager-standalone/autoloader.php")
assert audit < autoload

print("modsecurity_feature_test: OK")
