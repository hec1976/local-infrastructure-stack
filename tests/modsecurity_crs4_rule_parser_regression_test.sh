#!/bin/bash
set -euo pipefail
perl - <<'PERL'
my $buf = <<'RULE';
SecRule REQUEST_METHOD "@rx ^(?:GET|HEAD)$" \
    "id:911100,\
    phase:1,\
    severity:'CRITICAL',\
    msg:'TEKO CRS parser regression',\
    tag:'attack-protocol'"
RULE
$buf =~ /(?:^|[,\s'\"])id\s*:\s*['\"]?(\d+)/i or die "id not parsed\n";
die "wrong id\n" unless $1 == 911100;
$buf =~ /(?:^|[,\s'\"])phase\s*:\s*['\"]?(\d+)/i or die "phase not parsed\n";
die "wrong phase\n" unless $1 == 1;
$buf =~ /(?:^|[,\s'\"])severity\s*:\s*['\"]?([^,'\"\s]+)/i or die "severity not parsed\n";
die "wrong severity\n" unless $1 eq 'CRITICAL';
$buf =~ /(?:^|[,\s'\"])msg\s*:\s*'([^']*)'/i or die "msg not parsed\n";
die "wrong msg\n" unless $1 eq 'TEKO CRS parser regression';
print "PASS CRS 4 quoted-action parser\n";
PERL
