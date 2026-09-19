#!/bin/bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
TMP="$(mktemp -d /tmp/teko-modsecurity-reload-regression.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Mojo" "$TMP/etc/modsecurity/crs"
cat > "$TMP/Mojo/JSON.pm" <<'PM'
package Mojo::JSON; use Exporter 'import'; our @EXPORT_OK=qw(true false); sub true(){1} sub false(){0} 1;
PM
cat > "$TMP/Mojo/IOLoop.pm" <<'PM'
package Mojo::IOLoop; 1;
PM
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
my($rc,$out)=_ms_run('/bin/sh','-c','echo OUT; echo STDERR-MARKER >&2; exit 7');
die "runner rc" unless $rc==7;
die "runner stdout" unless $out =~ /OUT/;
die "runner stderr" unless $out =~ /STDERR-MARKER/;
my $cfg="$root/teko-modsecurity.conf";
my $exc="$root/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf";
my $mode="$root/zz-teko-modsecurity-mode.conf";
open my $f,'>',$cfg or die $!; print $f "OLD-CONFIG\n"; close $f;
open my $m,'>',$mode or die $!; print $m "OLD-MODE\n"; close $m;
open my $e,'>',$exc or die $!; print $e "FOREIGN\n# BEGIN TEKO MANAGED RULE EXCLUSIONS\nSecRuleRemoveById 111\n# END TEKO MANAGED RULE EXCLUSIONS\n"; close $e;
my $oldcfg=do{open my $h,'<',$cfg or die $!; local $/; <$h>};
my $oldexc=do{open my $h,'<',$exc or die $!; local $/; <$h>};
my $oldmode=do{open my $h,'<',$mode or die $!; local $/; <$h>};
my $reload_calls=0;
{
  no warnings 'redefine';
  local *main::_ms_profile = sub { {os=>{manager=>'apt'},apache_service=>'apache2.service',teko_config=>$cfg,mode_override=>$mode,exclusions_file=>$exc,packages=>['libapache2-mod-security2'],audit_log=>'/tmp/audit.log'} };
  local *main::_ms_with_lock = sub { $_[0]->() };
  local *main::_ms_apache_test = sub { (0,'Syntax OK','/usr/sbin/apache2ctl') };
  local *main::_ms_apache_control = sub {
    my($profile,$action)=@_;
    if($action eq 'reload'){
      ++$reload_calls;
      return $reload_calls==1 ? (5,'reload denied: synthetic failure') : (0,'');
    }
    return (0,'');
  };
  my $ok=eval{_ms_save_config({rule_engine=>'DetectionOnly',audit_engine=>'RelevantOnly',request_body_access=>1,response_body_access=>0,request_body_limit=>134217728,excluded_rule_ids=>[942100,949110]});1};
  die "expected reload failure" if $ok;
  die "missing reload detail" unless $@ =~ /Reload fehlgeschlagen \(rc=5\).*reload denied/;
}
my $newcfg=do{open my $h,'<',$cfg or die $!; local $/; <$h>};
my $newexc=do{open my $h,'<',$exc or die $!; local $/; <$h>};
die "config rollback mismatch" unless $newcfg eq $oldcfg;
die "exclusion rollback mismatch" unless $newexc eq $oldexc;
my $newmode=do{open my $h,'<',$mode or die $!; local $/; <$h>};
die "mode override rollback mismatch" unless $newmode eq $oldmode;
die "rollback reload missing" unless $reload_calls==2;
print "modsecurity_reload_regression_test: OK\n";
PL
PERL5LIB="$TMP${PERL5LIB:+:$PERL5LIB}" perl "$TMP/test.pl" "$ROOT/config-agent/lib/ModSecurity.pm" "$TMP/etc/modsecurity/crs"
