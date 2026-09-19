#!/bin/bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
TMP="$(mktemp -d /tmp/teko-modsecurity-install-rollback.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Mojo" "$TMP/etc/modsecurity" "$TMP/etc/apache2/mods-available" "$TMP/etc/apache2/mods-enabled"
cat > "$TMP/Mojo/JSON.pm" <<'PM'
package Mojo::JSON; use Exporter 'import'; our @EXPORT_OK=qw(true false); sub true(){1} sub false(){0} 1;
PM
cat > "$TMP/Mojo/IOLoop.pm" <<'PM'
package Mojo::IOLoop; 1;
PM
printf '%s\n' 'RECOMMENDED' > "$TMP/etc/modsecurity/modsecurity.conf-recommended"
printf '%s\n' 'ACTIVE-OLD' > "$TMP/etc/modsecurity/modsecurity.conf"
printf '%s\n' '<IfModule security2_module>' '  IncludeOptional /usr/share/modsecurity-crs/*.conf' '</IfModule>' > "$TMP/etc/apache2/mods-available/security2.conf"
cp "$TMP/etc/modsecurity/modsecurity.conf" "$TMP/active.before"
cp "$TMP/etc/apache2/mods-available/security2.conf" "$TMP/security2.before"
cat > "$TMP/test.pl" <<'PL'
use strict; use warnings;
BEGIN {
  *main::get = sub { 1 }; *main::post = sub { 1 };
  *main::_pkg_read_os = sub { {id=>'debian',pretty_name=>'Debian',version_id=>'13',manager=>'apt'} };
  *main::_pkg_check = sub { {installed=>1,version=>'1.0'} };
  *main::_pkg_mutate = sub { {ok=>1} };
  *main::_fmt_req = sub { 'test' };
}
require $ARGV[0];
my $root=$ARGV[1];
my $reload_calls=0;
my $test_calls=0;
{
  no warnings 'redefine';
  local *main::_ms_profile = sub { {
    os=>{manager=>'apt'}, apache_service=>'apache2.service',
    teko_config=>"$root/etc/modsecurity/teko-modsecurity.conf",
    mode_override=>"$root/etc/apache2/zz-teko-modsecurity-mode.conf",
    custom_rules=>"$root/etc/modsecurity/teko-custom-rules.conf",
    custom_rules_include=>"$root/etc/apache2/teko-modsecurity-custom.conf",
    exclusions_file=>"$root/etc/modsecurity/crs/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf",
    packages=>['libapache2-mod-security2','modsecurity-crs'], audit_log=>'/tmp/audit.log',
    base_config=>"$root/etc/modsecurity/modsecurity.conf",
    recommended_config=>"$root/etc/modsecurity/modsecurity.conf-recommended",
    security2_config=>"$root/etc/apache2/mods-available/security2.conf",
    security2_enabled=>"$root/etc/apache2/mods-enabled/security2.load",
  } };
  local *main::_ms_with_lock = sub { $_[0]->() };
  local *main::_ms_apache_test = sub { ++$test_calls; return (0,'Syntax OK','/usr/sbin/apache2ctl') };
  local *main::_ms_module_loaded = sub { 1 };
  local *main::_ms_ensure_apache_modules = sub { 1 };
  local *main::_ms_run = sub {
    my(@cmd)=@_;
    if(@cmd>=3 && $cmd[0] eq '/usr/bin/systemctl' && $cmd[1] eq 'reload'){
      ++$reload_calls;
      return $reload_calls==1 ? (5,'reload denied: synthetic install failure') : (0,'rollback reload ok');
    }
    return (0,'');
  };
  my $ok=eval{_ms_install();1};
  die "expected install reload failure" if $ok;
  die "missing original reload detail: $@" unless $@ =~ /Reload nach Installation fehlgeschlagen \(rc=5\).*synthetic install failure/s;
}
die "rollback configtest missing" unless $test_calls>=2;
die "rollback reload missing" unless $reload_calls==2;
print "modsecurity_install_rollback_regression_test: OK\n";
PL
PERL5LIB="$TMP${PERL5LIB:+:$PERL5LIB}" perl "$TMP/test.pl" "$ROOT/config-agent/lib/ModSecurity.pm" "$TMP"
cmp -s "$TMP/etc/modsecurity/modsecurity.conf" "$TMP/active.before" || { echo 'base config rollback mismatch' >&2; exit 1; }
cmp -s "$TMP/etc/apache2/mods-available/security2.conf" "$TMP/security2.before" || { echo 'security2 rollback mismatch' >&2; exit 1; }
