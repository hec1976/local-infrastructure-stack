from pathlib import Path
root=Path(__file__).resolve().parents[1]
pm=(root/'config-agent/lib/ModSecurity.pm').read_text()
setup=(root/'setup_config_agent.sh').read_text()
checks={
 'zypper does not require missing CRS RPM': "eq 'zypper' ? ['apache2-mod_security2']" in pm,
 'CRS RPM remains optional': "crs_package=>'modsecurity-crs'" in pm and "_ms_install_crs_fallback_zypper" in pm,
 'pinned CRS LTS': "crs_version=>'4.25.1'" in pm,
 'CRS engine minimum enforced': "_ms_version_ge($st->{version},'2.9.6')" in pm,
 'SUSE Apache Modules upgrade path': 'Apache:/Modules/openSUSE_Leap_${ver}/' in pm and "--allow-vendor-change" in pm,
 'repairs broken v2.2.2 repo alias': "removerepo',$repo" in pm and 'actual repository directory' in pm,
 'official CRS source': "github.com/coreruleset/coreruleset/archive/refs/tags/v4.25.1.tar.gz" in pm,
 'download retries': "'--retry','4'" in pm,
 'atomic CRS staging': 'my $staging="$dest.new.$$"' in pm and 'rename($staging,$dest)' in pm,
 'Apache CRS include': '<IfModule security2_module>' in pm and 'IncludeOptional /etc/modsecurity/crs/crs-setup.conf' in pm and 'IncludeOptional /etc/modsecurity/crs/rules/*.conf' in pm,
 'Apache modules enabled before configtest': '_ms_ensure_apache_modules($profile);' in pm and 'qw(ssl proxy proxy_http headers rewrite unique_id security2)' in pm,
 'CRS marker/idempotence': '.teko-crs-version' in pm,
 'fallback dependencies': all(x in setup for x in ['    curl \\\n','    tar \\\n','    gzip \\\n']),
}
for name, ok in checks.items():
    if not ok:
        raise SystemExit(f'FAIL: {name}')
    print(f'PASS: {name}')
print('modsecurity_suse_crs_fallback_test: OK')
