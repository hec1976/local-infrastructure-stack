#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sh=(root/'bin/teko-apache-https.sh').read_text()
pm=(root/'config-agent/lib/ModSecurity.pm').read_text()
checks={
 'shell parks forgejo': 'forgejo-teko.conf' in sh and 'teko-module-sync-disabled' in sh,
 'shell parks grafana': 'grafana-teko.conf' in sh,
 'shell restores before configtest': 'restore_teko_sync_vhosts' in sh and 'apache_configtest' in sh,
 'shell uses SUSE effective module list': '/usr/sbin/start_apache2 -M' in sh and 'proxy_http' in sh,
 'shell has SUSE-native configtest': '/usr/sbin/start_apache2 -t' in sh,
 'shell no hard apache2ctl exec': 'apache2ctl -M' not in sh and 'apache2ctl -t' not in sh,
 'agent parks TEKO vhosts': "forgejo-teko.conf','/etc/apache2/vhosts.d/grafana-teko.conf" in pm,
 'agent restores TEKO vhosts': 'my $restore=sub' in pm and '$restore->();' in pm,
 'agent uses SUSE effective module list': "_ms_run('/usr/sbin/start_apache2','-M')" in pm,
 'agent configtest uses SUSE start_apache2': "['/usr/sbin/start_apache2','-t']" in pm,
 'agent no apache2ctl runtime candidate': "['/usr/sbin/apache2ctl'" not in pm,
}
for name,ok in checks.items():
    print(('[PASS] ' if ok else '[FAIL] ')+name)
if not all(checks.values()): raise SystemExit(1)
