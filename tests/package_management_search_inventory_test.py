from pathlib import Path
r=Path(__file__).resolve().parents[1]
php=(r/'config-manager-standalone/public/package_management.php').read_text()
pm=(r/'config-agent/lib/PackageMgmt.pm').read_text()
checks={
 'search limit 100': 'searchPackages($q,100)' in php,
 'search progress': 'packageSearchProgress' in php and 'input.readOnly=true' in php,
 'result count': 'Maximum 100' in php,
 'installed overview': 'Server-Inventar' in php and 'installedSummary' in php,
 'installed progress': 'installedProgress' in php,
 'installed api 2000': 'getInstalledPackages($q,2000)' in php,
 'agent inventory 2000': '$limit>2000' in pm,
}
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
raise SystemExit(0 if all(checks.values()) else 1)
