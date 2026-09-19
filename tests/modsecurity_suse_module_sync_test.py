from pathlib import Path
pm=Path(__file__).resolve().parents[1]/'config-agent/lib/ModSecurity.pm'
s=pm.read_text()
checks={
 'SUSE restart uses rcapache2 abstraction': "_ms_apache_control($profile,'restart')" in s and "'/usr/sbin/rcapache2'" in s,
 'proxy verified SUSE-native': "['proxy_module','ProxyPreserveHost/mod_proxy']" in s,
 'proxy_http verified SUSE-native': "['proxy_http_module','HTTP Reverse Proxy/mod_proxy_http']" in s,
 'security2 verified SUSE-native': "['security2_module','ModSecurity/security2']" in s,
 'effective module list used': "_ms_run('/usr/sbin/start_apache2','-M')" in s,
 'no apache2ctl runtime dependency': "['/usr/sbin/apache2ctl'" not in s,
}
for name, ok in checks.items():
 print(('PASS' if ok else 'FAIL'), '-', name)
 if not ok: raise SystemExit(1)
