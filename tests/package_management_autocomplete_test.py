#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
pm=(root/'config-manager-standalone/public/package_management.php').read_text()
agent=(root/'config-agent/lib/PackageMgmt.pm').read_text()
repo=(root/'config-manager-standalone/Repository/ConfigManagerRepository.php').read_text()
svc=(root/'config-manager-standalone/Service/ConfigManagerService.php').read_text()
ctl=(root/'config-manager-standalone/Controller/ConfigManagerController.php').read_text()
checks={
 'agent search function':'sub _pkg_search' in agent,
 'agent search route':"get '/packages/search'" in agent,
 'manager search api':"api']??'')==='search'" in pm,
 'autocomplete debounce':'setTimeout(packageSearch,300)' in pm,
 'suggest dropdown':'pkgSuggest' in pm and 'pm-suggest-item' in pm,
 'version select':'Automatisch / neueste verfügbare' in pm,
 'version fill':'fillVersions' in pm,
 'repository method':'searchPackages' in repo,
 'service method':'searchPackages' in svc,
 'controller method':'searchPackages' in ctl,
}
for k,v in checks.items(): print(('[PASS] ' if v else '[FAIL] ')+k)
if not all(checks.values()): raise SystemExit(1)
print('PACKAGE AUTOCOMPLETE RESULT: PASS')
