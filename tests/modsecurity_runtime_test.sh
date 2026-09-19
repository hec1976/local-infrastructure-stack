#!/bin/bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
TMP="$(mktemp -d /tmp/teko-modsecurity-runtime.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Mojo"

cat > "$TMP/Mojo/JSON.pm" <<'PM'
package Mojo::JSON;
use strict; use warnings;
use Exporter 'import';
our @EXPORT_OK=qw(true false);
sub true(){1} sub false(){0}
1;
PM

cat > "$TMP/Mojo/IOLoop.pm" <<'PM'
package Mojo::IOLoop;
1;
PM

cat > "$TMP/test.pl" <<'PL'
use strict; use warnings;
BEGIN {
  *main::get = sub { 1 };
  *main::post = sub { 1 };
  *main::_pkg_read_os = sub { return {id=>'debian',pretty_name=>'Debian',version_id=>'13',manager=>'apt'} };
  *main::_pkg_check = sub { return {installed=>1,version=>'1.0'} };
  *main::_pkg_mutate = sub { return {ok=>1,exit_code=>0,output=>'',command=>'apt install'} };
  *main::_fmt_req = sub { return 'test'; };
}
require $ARGV[0];

my $ok=_ms_validate_config({
  rule_engine=>'DetectionOnly',
  audit_engine=>'RelevantOnly',
  request_body_access=>1,
  response_body_access=>0,
  request_body_limit=>134217728,
  excluded_rule_ids=>[942100,949110],
});
die "engine" unless $ok->{rule_engine} eq 'DetectionOnly';
die "ids" unless @{$ok->{excluded_rule_ids}}==2;
my $profile=_ms_profile();
die "debian package mapping" unless $profile->{packages}[0] eq 'libapache2-mod-security2';
my $render=_ms_render_config($ok,$profile);
die "render rule engine" unless $render =~ /SecRuleEngine DetectionOnly/;
die "Debian exclusions must be placed after CRS, not in base config" if $render =~ /SecRuleRemoveById/;

for my $bad (
 {rule_engine=>'BAD',audit_engine=>'RelevantOnly',request_body_limit=>134217728},
 {rule_engine=>'On',audit_engine=>'BAD',request_body_limit=>134217728},
 {rule_engine=>'On',audit_engine=>'On',request_body_limit=>1},
 {rule_engine=>'On',audit_engine=>'On',request_body_limit=>134217728,excluded_rule_ids=>['1;rm']},
){
 my $x=eval{_ms_validate_config($bad);1};
 die "invalid config accepted" if $x;
}
print "modsecurity_runtime_test: OK\n";
PL

PERL5LIB="$TMP${PERL5LIB:+:$PERL5LIB}" perl "$TMP/test.pl" "$ROOT/config-agent/lib/ModSecurity.pm"
