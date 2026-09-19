#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
agent=(root/'config-agent/lib/PackageMgmt.pm').read_text()
repo=(root/'config-manager-standalone/Repository/ConfigManagerRepository.php').read_text()
service=(root/'config-manager-standalone/Service/ConfigManagerService.php').read_text()
controller=(root/'config-manager-standalone/Controller/ConfigManagerController.php').read_text()
page=(root/'config-manager-standalone/public/package_management.php').read_text()
for x in ['/packages/preview','/packages/installed','_pkg_preview','_pkg_installed_list','zypper','--xmlout','rpm','-qa','dpkg-query']:
    assert x in agent,x
for x in ['getPackagePreview','getInstalledPackages']:
    assert x in repo and x in service and x in controller,x
for x in ['Paketvorschau','Installierte Pakete','Zielsysteme','Gruppe übernehmen','Nur Canary','Auswahl leeren','selectedCount','selectionNames']:
    assert x in page,x
assert "api=preview" in page and "api=installed" in page
assert "Paketname eingeben, einen Referenzserver auswählen" in page
assert "es wird dabei noch keine Paketaktion ausgeführt" in page
print('package_management_preview_test: OK')
