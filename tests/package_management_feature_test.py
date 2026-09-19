#!/usr/bin/env python3
from pathlib import Path
import json,re
root=Path(__file__).resolve().parents[1]
agent=(root/"config-agent/lib/PackageMgmt.pm").read_text()
main=(root/"config-agent/config-agent.pl").read_text()
repo=(root/"config-manager-standalone/Repository/ConfigManagerRepository.php").read_text()
service=(root/"config-manager-standalone/Service/ConfigManagerService.php").read_text()
controller=(root/"config-manager-standalone/Controller/ConfigManagerController.php").read_text()
page=(root/"config-manager-standalone/public/package_management.php").read_text()
nav=json.loads((root/"config-manager-standalone/config/module_navigation.json").read_text())

for x in ["zypper","apt-get","dnf","dpkg-query","rpm","/packages/info","/packages/action"]:
    assert x in agent,x
for action in ["check","install","upgrade","remove"]:
    assert action in agent and action in page
assert "_pkg_name" in agent and "Ungueltiger Paketname" in agent
assert "_pkg_version" in agent and "Ungueltige Paketversion" in agent
assert "system(" not in agent
assert "qx/" not in agent
assert "`" not in agent
assert "PackageMgmt" in main

for x in ["getPackageInfo","packageAction"]:
    assert x in repo and x in service and x in controller
assert "package_"+"" in controller
assert "Maximal 50 Zielserver" in page
assert "Nur Canary" in page
assert "Keine freien Paketmanager-Parameter" in page
assert "csrf_token" in page
assert "server_names" in page
assert "mmbb_has_service('ConfigManager')" in page
assert "confirm_remove" in page and "confirm_remove" in agent
assert "teko-config-agent-package.lock" in agent
assert "flock" in agent
assert "our $logger" in agent
assert "$this->repo->packageAction" in service
assert "$this->repository->packageAction" not in service
assert "confirm(`Paket" in page
assert any(i["key"]=="package_management" for i in nav["items"])
print("package_management_feature_test: OK")
