#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
php=(root/'config-manager-standalone/public/package_management.php').read_text()
pm=(root/'config-agent/lib/PackageMgmt.pm').read_text()
checks={
 'inventory_tab':'Server-Inventar' in php,
 'fleet_tab':'Fleet-Vergleich' in php,
 'inventory_cards':'invTotal' in php and 'invUpdates' in php and 'invOs' in php,
 'inventory_columns':'Installierte Version' in php and 'Repository' in php,
 'fleet_api':"==='fleet'" in php and 'getInstalledPackages($pkg,50)' in php,
 'fleet_ui':'fleetRows' in php and 'fleetPackage' in php and 'Fleet vergleichen' in php,
 'update_flag':'update_available' in php and 'Update verfügbar' in php,
 'agent_update_inventory':'sub _pkg_updates_list' in pm and 'updates_available' in pm and 'available_version' in pm,
 'suse_updates':"'list-updates'" in pm,
 'apt_updates':"'--upgradable'" in pm,
 'dnf_updates':"'--upgrades'" in pm,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
if failed: raise SystemExit('failed: '+', '.join(failed))
