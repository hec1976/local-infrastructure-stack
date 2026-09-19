from pathlib import Path
r=Path(__file__).resolve().parents[1]
sh=(r/'bin/teko-apache-https.sh').read_text()
pm=(r/'config-agent/lib/ModSecurity.pm').read_text()
checks={
  'shell uses start_apache2 configtest': '/usr/sbin/start_apache2 -t' in sh,
  'shell uses effective module list': '/usr/sbin/start_apache2 -M' in sh,
  'shell no direct httpd2 configtest': '/usr/sbin/httpd2 -t -f' not in sh and '/usr/sbin/httpd2-prefork -t -f' not in sh,
  'agent configtest uses start_apache2': "['/usr/sbin/start_apache2','-t']" in pm,
  'agent module check uses start_apache2': "_ms_run('/usr/sbin/start_apache2','-M')" in pm,
  'agent no direct httpd2 configtest': "['/usr/sbin/httpd2','-t'" not in pm and "['/usr/sbin/httpd2-prefork','-t'" not in pm,
  'modsecurity unique_id enabled': 'unique_id security2' in pm,
}
for name,ok in checks.items():
    print(('[PASS] ' if ok else '[FAIL] ')+name)
if not all(checks.values()): raise SystemExit(1)
