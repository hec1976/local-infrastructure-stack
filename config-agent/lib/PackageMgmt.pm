package main;
use strict;
use warnings;
use utf8;
use Mojo::JSON qw(true false);
use Mojo::IOLoop;
use Fcntl qw(:flock);
use Time::HiRes qw(time sleep);

our $logger;

sub _pkg_read_os {
  open my $fh,'<','/etc/os-release' or die "os-release nicht lesbar";
  my %o;
  while(<$fh>){ chomp; next unless /^([A-Z0-9_]+)=(.*)$/; my($k,$v)=($1,$2); $v =~ s/^["']//; $v =~ s/["']$//; $o{$k}=$v; }
  close $fh;
  my $id=lc($o{ID}//''); my $like=lc($o{ID_LIKE}//'');
  my $mgr =
    ($id =~ /^(?:opensuse|opensuse-leap|sles)$/ || $like =~ /suse/) ? 'zypper' :
    ($id =~ /^(?:debian|ubuntu)$/ || $like =~ /debian/) ? 'apt' :
    ($id =~ /^(?:rhel|rocky|almalinux|centos|fedora)$/ || $like =~ /(?:rhel|fedora)/) ? 'dnf' : '';
  die "Nicht unterstuetztes OS: ".($o{PRETTY_NAME}//$id) unless $mgr;
  return {id=>$id, pretty_name=>($o{PRETTY_NAME}//$id), version_id=>($o{VERSION_ID}//''), manager=>$mgr};
}
sub _pkg_name {
  my($p)=@_; $p//=q{};
  die "Ungueltiger Paketname" unless $p =~ /\A[A-Za-z0-9][A-Za-z0-9+_.:@-]{0,127}\z/;
  return $p;
}
sub _pkg_version {
  my($v)=@_; return '' unless defined($v) && length($v);
  die "Ungueltige Paketversion" unless $v =~ /\A[A-Za-z0-9][A-Za-z0-9+_.:~@-]{0,127}\z/;
  return $v;
}
sub _pkg_run {
  my(@cmd)=@_; my $pid=open(my $fh,'-|',@cmd); die "Kommando konnte nicht gestartet werden" unless defined $pid;
  local $/; my $out=<$fh>//''; close $fh; my $rc=$?>>8;
  $out =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
  return ($rc,substr($out,0,250000));
}
sub _pkg_check {
  my($os,$p)=@_;
  my($rc,$out);
  if($os->{manager} eq 'apt'){
    ($rc,$out)=_pkg_run('dpkg-query','-W','-f=${Status}\t${Version}\n',$p);
    return {installed=>false(),version=>''} if $rc;
    my($st,$ver)=split(/\t/,$out,2); $ver//=q{}; $ver=~s/\s+$//;
    return {installed=>($st =~ /install ok installed/ ? true():false()),version=>$ver};
  } else {
    ($rc,$out)=_pkg_run('rpm','-q','--qf','%{VERSION}-%{RELEASE}\n',$p);
    return {installed=>false(),version=>''} if $rc;
    $out=~s/\s+$//; return {installed=>true(),version=>$out};
  }
}

sub _pkg_xml_unescape {
  my($s)=@_; $s//=q{};
  $s =~ s/&quot;/"/g; $s =~ s/&apos;/'/g; $s =~ s/&lt;/</g; $s =~ s/&gt;/>/g; $s =~ s/&amp;/&/g;
  return $s;
}
sub _pkg_zypper_solvable_attrs {
  my($xml)=@_; my @rows;
  while($xml =~ /<solvable\b([^>]*?)\/>/sg){
    my $attrs=$1; my %a;
    while($attrs =~ /([A-Za-z0-9_-]+)="([^"]*)"/g){ $a{$1}=_pkg_xml_unescape($2); }
    next unless ($a{kind}//'package') eq 'package';
    push @rows, \%a;
  }
  return \@rows;
}
sub _pkg_preview {
  my($os,$p)=@_; $p=_pkg_name($p);
  my $installed=_pkg_check($os,$p); my @available; my $summary='';
  if($os->{manager} eq 'zypper'){
    my($rc,$out)=_pkg_run('zypper','--xmlout','--non-interactive','search','-s','--match-exact',$p);
    my $rows=_pkg_zypper_solvable_attrs($out);
    for my $r (@$rows){ next unless ($r->{name}//'') eq $p; push @available,{version=>($r->{edition}//''),arch=>($r->{arch}//''),repository=>($r->{repository}//''),status=>($r->{status}//'')}; last if @available>=20; }
  } elsif($os->{manager} eq 'apt'){
    my($rc,$out)=_pkg_run('apt-cache','policy',$p);
    if(!$rc){ my($cand)=$out =~ /^\s*Candidate:\s*(\S+)/m; push @available,{version=>$cand,arch=>'',repository=>'apt',status=>'candidate'} if defined($cand) && $cand ne '(none)'; }
    my($src,$desc)=_pkg_run('apt-cache','show',$p); if(!$src && $desc =~ /^Description(?:-[^:]+)?:\s*(.+)$/m){$summary=$1;}
  } else {
    my($rc,$out)=_pkg_run('dnf','-q','repoquery','--qf','%{evr}\t%{arch}\t%{reponame}\t%{summary}',$p);
    if(!$rc){ for my $line(split /\n/,$out){ my($v,$a,$repo,$sum)=split /\t/,$line,4; next unless defined $v && length $v; $summary=$sum if !$summary && defined $sum; push @available,{version=>$v,arch=>($a//''),repository=>($repo//''),status=>'available'}; last if @available>=20; } }
  }
  return {ok=>true(),package=>$p,os=>$os,installed=>$installed,available=>\@available,summary=>$summary};
}

sub _pkg_search {
  my($os,$query,$limit)=@_; $query//=q{}; $query=~s/^\s+|\s+$//g;
  die "Paketsuche muss mindestens 2 Zeichen enthalten" unless $query =~ /\A[A-Za-z0-9+_.:@-]{2,64}\z/;
  $limit=int($limit||30); $limit=30 if $limit<1||$limit>100;
  my @out; my %seen;
  if($os->{manager} eq 'zypper'){
    my($rc,$xml)=_pkg_run('zypper','--xmlout','--non-interactive','search','-s',$query);
    my $rows=_pkg_zypper_solvable_attrs($xml);
    for my $r (@$rows){
      my $n=$r->{name}//''; next unless length($n) && index(lc($n),lc($query))>=0; next if $seen{$n}++;
      my $inst=_pkg_check($os,$n);
      push @out,{name=>$n,version=>($r->{edition}//''),arch=>($r->{arch}//''),repository=>($r->{repository}//''),status=>($r->{status}//''),installed=>$inst->{installed},installed_version=>($inst->{version}//'')};
      last if @out >= $limit;
    }
  } elsif($os->{manager} eq 'apt'){
    my($rc,$txt)=_pkg_run('apt-cache','search',$query);
    for my $line(split /\n/,$txt){ my($n,$sum)=split /\s+-\s+/,$line,2; next unless defined $n && $n =~ /\A[A-Za-z0-9][A-Za-z0-9+_.:@-]*\z/; next if $seen{$n}++;
      my($prc,$pol)=_pkg_run('apt-cache','policy',$n); my($cand)=$pol =~ /^\s*Candidate:\s*(\S+)/m; my $inst=_pkg_check($os,$n);
      push @out,{name=>$n,version=>(defined($cand)&&$cand ne '(none)'?$cand:''),arch=>'',repository=>'apt',summary=>($sum//''),installed=>$inst->{installed},installed_version=>($inst->{version}//'')}; last if @out >= $limit;
    }
  } else {
    my($rc,$txt)=_pkg_run('dnf','-q','repoquery','--available','--qf','%{name}\t%{evr}\t%{arch}\t%{reponame}\t%{summary}','*'.$query.'*');
    if(!$rc){ for my $line(split /\n/,$txt){ my($n,$v,$a,$repo,$sum)=split /\t/,$line,5; next unless defined $n && length $n; next if $seen{$n}++; my $inst=_pkg_check($os,$n);
      push @out,{name=>$n,version=>($v//''),arch=>($a//''),repository=>($repo//''),summary=>($sum//''),installed=>$inst->{installed},installed_version=>($inst->{version}//'')}; last if @out >= $limit; } }
  }
  return {ok=>true(),os=>$os,query=>$query,count=>scalar(@out),packages=>\@out};
}

sub _pkg_updates_list {
  my($os)=@_; my @rows;
  if($os->{manager} eq 'zypper'){
    my($rc,$xml)=_pkg_run('zypper','--xmlout','--non-interactive','list-updates');
    # zypper returns 100 in some update-related situations; parse any XML we got.
    my $solv=_pkg_zypper_solvable_attrs($xml);
    my %seen;
    for my $r (@$solv){
      my $n=$r->{name}//''; next unless length($n) && !$seen{$n}++;
      push @rows,{name=>$n,version=>($r->{edition}//''),arch=>($r->{arch}//''),repository=>($r->{repository}//'')};
    }
  } elsif($os->{manager} eq 'apt'){
    my($rc,$out)=_pkg_run('apt','list','--upgradable');
    for my $line(split /\n/,$out){
      next if $line =~ /^Listing/;
      # name/repo version arch [upgradable from: old]
      if($line =~ m{^([^/\s]+)/([^\s]+)\s+(\S+)\s+(\S+)\s+\[upgradable from:\s*([^\]]+)\]}){
        push @rows,{name=>$1,repository=>$2,version=>$3,arch=>$4,installed_version=>$5};
      }
    }
  } else {
    my($rc,$out)=_pkg_run('dnf','-q','repoquery','--upgrades','--qf','%{name}\t%{evr}\t%{arch}\t%{reponame}');
    if(!$rc){ for my $line(split /\n/,$out){ my($n,$v,$a,$repo)=split /\t/,$line,4; next unless defined $n && length $n; push @rows,{name=>$n,version=>($v//''),arch=>($a//''),repository=>($repo//'')}; } }
  }
  return \@rows;
}

sub _pkg_installed_list {
  my($os,$query,$limit)=@_; $query=lc($query//q{}); $limit=int($limit||1000); $limit=1000 if $limit<1||$limit>2000; my @all;
  if($os->{manager} eq 'apt'){
    my($rc,$out)=_pkg_run('dpkg-query','-W','-f=${binary:Package}\t${Version}\t${Architecture}\n');
    die "Installierte Pakete konnten nicht gelesen werden" if $rc;
    for my $line(split /\n/,$out){ my($n,$v,$a)=split /\t/,$line,3; next unless defined $n&&defined $v; push @all,{name=>$n,version=>$v,arch=>($a//'')}; }
  } else {
    my($rc,$out)=_pkg_run('rpm','-qa','--qf','%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n');
    die "Installierte Pakete konnten nicht gelesen werden" if $rc;
    for my $line(sort split /\n/,$out){ my($n,$v,$a)=split /\t/,$line,3; next unless defined $n&&defined $v; push @all,{name=>$n,version=>$v,arch=>($a//'')}; }
  }
  my $updates=_pkg_updates_list($os); my %up=map { (lc($_->{name}//''),$_) } @$updates;
  my @rows;
  for my $r (@all){
    next if length($query)&&index(lc($r->{name}),$query)<0;
    my $u=$up{lc($r->{name})};
    $r->{update_available}=$u ? true() : false();
    $r->{available_version}=$u ? ($u->{version}//'') : '';
    $r->{repository}=$u ? ($u->{repository}//'') : '';
    push @rows,$r; last if @rows >= $limit;
  }
  return {ok=>true(),os=>$os,query=>$query,count=>scalar(@rows),total_installed=>scalar(@all),updates_available=>scalar(@$updates),packages=>\@rows};
}

sub _pkg_lock_acquire {
  my $path = '/run/teko-config-agent-package.lock';
  open my $fh, '>>', $path or die "Package-Lock kann nicht geoeffnet werden: $!";
  chmod 0600, $path;
  my $deadline = time() + 10.0;
  while (!flock($fh, LOCK_EX|LOCK_NB)) {
    die "Package Manager ist bereits durch einen anderen Job belegt" if time() >= $deadline;
    sleep 0.10;
  }
  return $fh;
}
sub _pkg_mutate {
  my($os,$action,$p,$version)=@_;
  my $lockfh=_pkg_lock_acquire();
  my @cmd;
  if($os->{manager} eq 'zypper'){
    my $spec=$version ? "$p=$version" : $p;
    @cmd = $action eq 'install' ? ('zypper','--non-interactive','install','--no-recommends',$spec)
         : $action eq 'upgrade' ? ('zypper','--non-interactive','update',$spec)
         : ('zypper','--non-interactive','remove',$p);
  } elsif($os->{manager} eq 'apt'){
    my $spec=$version ? "$p=$version" : $p;
    @cmd = $action eq 'install' ? ('apt-get','-y','--no-install-recommends','install',$spec)
         : $action eq 'upgrade' ? ('apt-get','-y','--only-upgrade','install',$spec)
         : ('apt-get','-y','remove',$p);
  } else {
    my $spec=$version ? "$p-$version" : $p;
    @cmd = $action eq 'install' ? ('dnf','-y','install',$spec)
         : $action eq 'upgrade' ? ('dnf','-y','upgrade',$spec)
         : ('dnf','-y','remove',$p);
  }
  my($rc,$out)=_pkg_run(@cmd);
  return {ok=>($rc==0?true():false()), exit_code=>$rc, output=>$out, command=>$os->{manager}." ".$action};
}
sub _pkg_execute {
  my($payload)=@_;
  die "Payload muss Objekt sein" unless ref($payload) eq 'HASH';
  my $action=lc($payload->{action}//'check');
  die "Ungueltige Paketaktion" unless $action =~ /\A(?:check|install|upgrade|remove)\z/;
  my $p=_pkg_name($payload->{package}); my $v=_pkg_version($payload->{version});
  die "Version ist fuer remove nicht erlaubt" if $action eq 'remove' && length $v;
  die "Remove erfordert confirm_remove=true" if $action eq 'remove' && !$payload->{confirm_remove};
  my $os=_pkg_read_os();
  my $before=_pkg_check($os,$p);
  return {ok=>true(), action=>$action, package=>$p, os=>$os, before=>$before, after=>$before} if $action eq 'check';
  my $result=_pkg_mutate($os,$action,$p,$v);
  my $after=_pkg_check($os,$p);
  return {ok=>$result->{ok},action=>$action,package=>$p,requested_version=>$v,os=>$os,before=>$before,after=>$after,
          exit_code=>$result->{exit_code},output=>$result->{output},command=>$result->{command}};
}

get '/packages/info' => sub {
  my $c=shift; my $os=eval{_pkg_read_os()};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>501) if $@;
  $c->render(json=>{ok=>true(),os=>$os,actions=>[qw(check install upgrade remove)]});
};

get '/packages/preview' => sub {
  my $c=shift; my $os=eval{_pkg_read_os()};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>501) if $@;
  my $p=$c->param('package')//''; my $res=eval{_pkg_preview($os,$p)};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;
  $c->render(json=>$res);
};

get '/packages/search' => sub {
  my $c=shift; my $os=eval{_pkg_read_os()};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>501) if $@;
  my $q=$c->param('q')//''; my $limit=$c->param('limit')//30;
  my $res=eval{_pkg_search($os,$q,$limit)};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;
  $c->render(json=>$res);
};

get '/packages/installed' => sub {
  my $c=shift; my $os=eval{_pkg_read_os()};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>501) if $@;
  my $q=$c->param('q')//''; $q=~s/[^A-Za-z0-9+_.:@-]//g; my $limit=$c->param('limit')//1000;
  my $res=eval{_pkg_installed_list($os,$q,$limit)};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;
  $c->render(json=>$res);
};

post '/packages/action' => sub {
  my $c=shift; my $in=$c->req->json;
  return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in) eq 'HASH';
  $c->render_later;
  my $sp=Mojo::IOLoop::Subprocess->new;
  $sp->run(
    sub { _pkg_execute($in) },
    sub {
      my($sub,$err,$res)=@_;
      if($err){ my $m="$err"; $m=~s/[\r\n]+/ /g; return $c->render(json=>{ok=>false(),error=>$m},status=>400); }
      my $status=$res->{ok}?200:500;
      $logger->info(sprintf('PACKAGE action=%s package=%s manager=%s rc=%s %s',
        $res->{action}//'', $res->{package}//'', $res->{os}{manager}//'', $res->{exit_code}//0, _fmt_req($c)));
      $c->render(json=>$res,status=>$status);
    }
  );
};

1;
