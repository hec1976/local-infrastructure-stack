#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# Minimal copy of the parser contract used by Firewall.pm, deliberately fed
# realistic firewall-cmd --list-all-zones output.
sub parse_zones {
  my($out)=@_; my @zones; my $cur; my $key='';
  for my $line (split /\n/, ($out//'')){
    next if $line =~ /\A\s*\z/;
    if($line =~ /\A([A-Za-z0-9_.-]+)(?:\s+\(([^)]*)\))?\s*\z/){
      my($name,$flags)=($1,$2//'');
      my $act = $flags =~ /(?:\A|,\s*)active(?:\s*,|\z)/ ? 1 : 0;
      $cur={name=>$name,active=>$act,rich_rules=>[],interfaces=>[],ports=>[],services=>[],sources=>[]};
      push @zones,$cur; $key=''; next;
    }
    next unless $cur;
    if($line =~ /\A\x20\x20(\S[^:]*):\x20?(.*)\z/){
      my($k,$v)=($1,$2); $k =~ s/\s+\z//; $v='' unless defined $v; $key=$k;
      my @vals=grep {length} split /\s+/, $v;
      $cur->{interfaces}=\@vals if $k eq 'interfaces';
      $cur->{ports}=\@vals if $k eq 'ports';
      $cur->{services}=\@vals if $k eq 'services';
      $cur->{sources}=\@vals if $k eq 'sources';
      push @{$cur->{rich_rules}},$v if $k eq 'rich rules' && length $v;
      next;
    }
    my $t=$line; $t =~ s/\A\s+//; $t =~ s/\s+\z//;
    push @{$cur->{rich_rules}},$t if length($t) && $key eq 'rich rules';
  }
  return \@zones;
}

my $fixture = <<'EOF';
block
  target: %%REJECT%%
  interfaces:
  sources:
  services:
  ports:
  rich rules:
public (default, active)
  target: default
  interfaces: enp0s3
  sources:
  services: dhcpv6-client ssh
  ports: 22/tcp 443/tcp 5008/tcp 80/tcp
  rich rules:
internal
  target: default
  interfaces:
  sources:
  services: ssh
  ports:
  rich rules:
EOF
my $z=parse_zones($fixture);
is(scalar(@$z),3,'three zones parsed');
is($z->[1]{name},'public','public parsed as zone');
ok($z->[1]{active},'public active flag parsed with default flag');
is_deeply($z->[1]{interfaces},['enp0s3'],'interface parsed');
is_deeply($z->[1]{ports},['22/tcp','443/tcp','5008/tcp','80/tcp'],'ports parsed');
is_deeply($z->[0]{rich_rules},[],'public header not swallowed as previous rich rule');
is_deeply($z->[1]{rich_rules},[],'no bogus rich rule in public');

my $src_path='config-agent/lib/Firewall.pm';
open my $fh,'<',$src_path or die "$src_path: $!"; local $/; my $src=<$fh>; close $fh;
like($src, qr/--change-interface=\$value/, 'canonical change-interface form present');
like($src, qr/--remove-interface=\$value/, 'canonical remove-interface form present');
like($src, qr/--zone=\$p->\{zone\}/, 'canonical zone form present');

like($src, qr/--\$\{action\}-port=\$value/, 'canonical port add/remove form present');
like($src, qr/--\$\{action\}-service=\$value/, 'canonical service add/remove form present');
like($src, qr/--\$\{action\}-source=\$value/, 'canonical source add/remove form present');
done_testing();
