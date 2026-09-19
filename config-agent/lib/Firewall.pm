package main;
use strict;
use warnings;
use utf8;
use Mojo::JSON qw(true false);
use Mojo::IOLoop;
use File::Basename qw(dirname);

# Firewall status cache: repeated GUI refreshes should not execute the same
# expensive firewalld/repository probes over and over. Mutations invalidate it.
my $FW_INFO_CACHE;
my $FW_INFO_CACHE_AT = 0;
my $FW_INFO_CACHE_TTL = 4;
sub _fw_cache_invalidate { $FW_INFO_CACHE=undef; $FW_INFO_CACHE_AT=0; }

sub _fw_run {
  my(@cmd)=@_; my $pid=open(my $fh,'-|',@cmd); die "Kommando konnte nicht gestartet werden" unless defined $pid;
  local $/; my $out=<$fh>//''; close $fh; my $rc=$?>>8; $out =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
  return($rc,substr($out,0,250000));
}
sub _fw_backend {
  return 'firewalld' if -x '/usr/bin/firewall-cmd';
  return 'nftables' if -x '/usr/sbin/nft' || -x '/usr/bin/nft';
  return 'none';
}
sub _fw_package_name {
  my($os)=@_;
  return 'firewalld';
}
sub _fw_package_info {
  my $os=eval{_pkg_read_os()};
  return {supported=>false(),available=>false(),error=>"$@"} if $@;
  my $pkg=_fw_package_name($os);
  my $preview=eval{_pkg_preview($os,$pkg)};
  return {supported=>true(),package=>$pkg,os=>$os,available=>false(),error=>"$@"} if $@;
  return {supported=>true(),package=>$pkg,os=>$os,installed=>$preview->{installed},available=>(@{$preview->{available}||[]}?true():false()),versions=>$preview->{available}||[]};
}
sub _fw_install {
  my $os=_pkg_read_os();
  my $pkg=_fw_package_name($os);
  my $before=_pkg_check($os,$pkg);
  if($before->{installed} && -x '/usr/bin/firewall-cmd'){
    _fw_cache_invalidate();
    return {ok=>true(),installed=>true(),already_installed=>true(),package=>$pkg,os=>$os};
  }
  my $preview=_pkg_preview($os,$pkg);
  die "Firewall-Paket $pkg ist in den konfigurierten Repositories nicht verfuegbar" unless @{$preview->{available}||[]};
  my $r=_pkg_mutate($os,'install',$pkg,'');
  die "Firewall-Installation fehlgeschlagen: $r->{output}" unless $r->{ok};
  die 'firewall-cmd fehlt nach Installation' unless -x '/usr/bin/firewall-cmd';
  _fw_cache_invalidate();
  return {ok=>true(),installed=>true(),package=>$pkg,os=>$os,output=>$r->{output}};
}
sub _fw_service_state {
  my $backend=_fw_backend(); return {backend=>'none',active=>false(),enabled=>false()} if $backend eq 'none';
  if($backend eq 'firewalld'){
    my($a,$ao)=_fw_run('/usr/bin/systemctl','is-active','firewalld.service'); chomp $ao;
    my($e,$eo)=_fw_run('/usr/bin/systemctl','is-enabled','firewalld.service'); chomp $eo;
    return {backend=>$backend,active=>$a==0?true():false(),enabled=>$e==0?true():false(),active_state=>$ao||'unknown',enabled_state=>$eo||'unknown'};
  }
  my($rc,$out)=_fw_run((-x '/usr/sbin/nft'?'/usr/sbin/nft':'/usr/bin/nft'),'list','ruleset');
  return {backend=>$backend,active=>$rc==0?true():false(),enabled=>true(),summary=>$out};
}
sub _fw_parse_zones {
  my($out)=@_; my @zones; my $cur; my $key='';
  for my $line (split /\n/, ($out//'')){
    next if $line =~ /\A\s*\z/;
    # firewalld marks zone headers with zero or more flags, e.g.
    #   public (active)
    #   public (default, active)
    #   public (default)
    # Older parsing only accepted exactly "(active)".  A default+active zone
    # was therefore swallowed as a continuation line of the previous field
    # (commonly rich rules) and appeared in the portal as a bogus Rich Rule.
    if($line =~ /\A([A-Za-z0-9_.-]+)(?:\s+\(([^)]*)\))?\s*\z/){
      my($name,$flags)=($1,$2//'');
      my $act = $flags =~ /(?:\A|,\s*)active(?:\s*,|\z)/ ? 1 : 0;
      $cur={name=>$name,active=>($act?true():false()),target=>'',interfaces=>[],sources=>[],
            services=>[],ports=>[],protocols=>[],source_ports=>[],icmp_blocks=>[],
            forward_ports=>[],masquerade=>false(),rich_rules=>[]};
      push @zones,$cur; $key=''; next;
    }
    next unless $cur;
    if($line =~ /\A\x20\x20(\S[^:]*):\x20?(.*)\z/){
      my($k,$v)=($1,$2); $k =~ s/\s+\z//; $v='' unless defined $v; $key=$k;
      my @vals=grep {length} split /\s+/, $v;
      if   ($k eq 'target'){ $cur->{target}=$v }
      elsif($k eq 'interfaces'){ $cur->{interfaces}=\@vals }
      elsif($k eq 'sources'){ $cur->{sources}=\@vals }
      elsif($k eq 'services'){ $cur->{services}=\@vals }
      elsif($k eq 'ports'){ $cur->{ports}=\@vals }
      elsif($k eq 'protocols'){ $cur->{protocols}=\@vals }
      elsif($k eq 'source-ports'){ $cur->{source_ports}=\@vals }
      elsif($k eq 'icmp-blocks'){ $cur->{icmp_blocks}=\@vals }
      elsif($k eq 'masquerade'){ $cur->{masquerade}=($v =~ /yes/ ? true() : false()) }
      elsif($k eq 'forward-ports'){ push @{$cur->{forward_ports}},$v if length $v }
      elsif($k eq 'rich rules'){ push @{$cur->{rich_rules}},$v if length $v }
      next;
    }
    my $t=$line; $t =~ s/\A\s+//; $t =~ s/\s+\z//; next unless length $t;
    if   ($key eq 'rich rules'){ push @{$cur->{rich_rules}},$t }
    elsif($key eq 'forward-ports'){ push @{$cur->{forward_ports}},$t }
  }
  return \@zones;
}

# Vergleicht Runtime- und Permanent-Stand einer Zone. Ein Unterschied bedeutet,
# dass jemand ausserhalb des Portals direkt auf der Konsole gearbeitet hat.
sub _fw_zone_drift {
  my($rt,$pm)=@_; return false() unless ref($pm) eq 'HASH';
  for my $f (qw(ports services sources rich_rules)){
    my @a=sort @{$rt->{$f}||[]}; my @b=sort @{$pm->{$f}||[]};
    return true() if @a != @b;
    for my $i (0..$#a){ return true() if $a[$i] ne $b[$i] }
  }
  return false();
}

sub _fw_info_uncached {
  my $st=_fw_service_state(); my $backend=$st->{backend}; my @zones;
  # If firewalld is already present there is no reason to run a repository
  # preview on every status refresh. Repository metadata probing can take
  # seconds on SLES/openSUSE and was the main reason the page felt frozen.
  my $pkg = $backend eq 'firewalld'
    ? {supported=>true(),package=>'firewalld',installed=>true(),available=>true(),versions=>[]}
    : _fw_package_info();
  my $default_zone=''; my $source='none';
  # Ist firewalld gestoppt, gibt es keine Laufzeitkonfiguration. Die permanente
  # Konfiguration ist aber lesbar und genau das, was nach einem Start gilt.
  # Sie wird deshalb angezeigt und als solche gekennzeichnet.
  if($backend eq 'firewalld' && !$st->{active}){
    my $off=_fw_offline_bin();
    if($off){
      my($drc,$dz)=_fw_run($off,'--get-default-zone'); chomp $dz;
      $default_zone=$dz unless $drc;
      my($prc,$pout)=_fw_run($off,'--list-all-zones');
      unless($prc){
        for my $z (@{_fw_parse_zones($pout)}){
          $z->{active}=false(); $z->{drift}=false(); $z->{permanent}=undef;
          $z->{default}=($default_zone && $z->{name} eq $default_zone) ? true() : false();
          push @zones,$z;
        }
        $source='permanent';
      }
    }
  }
  if($backend eq 'firewalld' && $st->{active}){
    $source='runtime';
    my($drc,$dout)=_fw_run('/usr/bin/firewall-cmd','--get-default-zone'); chomp $dout;
    $default_zone=$dout if !$drc;

    # Alle definierten Zonen, nicht nur die aktiven. Eine Zone ohne Interface
    # oder Source ist trotzdem konfigurierbar und muss im Portal sichtbar sein.
    my($zrc,$zout)=_fw_run('/usr/bin/firewall-cmd','--list-all-zones');
    my $runtime = $zrc ? [] : _fw_parse_zones($zout);
    my($prc,$pout)=_fw_run('/usr/bin/firewall-cmd','--permanent','--list-all-zones');
    my %perm = $prc ? () : map { $_->{name} => $_ } @{_fw_parse_zones($pout)};

    for my $z (@$runtime){
      my $pm=$perm{$z->{name}};
      $z->{drift}=_fw_zone_drift($z,$pm);
      $z->{permanent}= $pm ? {ports=>$pm->{ports},services=>$pm->{services},
                              sources=>$pm->{sources},rich_rules=>$pm->{rich_rules}} : undef;
      $z->{default}=($default_zone && $z->{name} eq $default_zone) ? true() : false();
      push @zones,$z;
    }
  }
  return {ok=>true(),service=>$st,zones=>\@zones,backend=>$backend,default_zone=>$default_zone,
          config_source=>$source,agent_port=>_fw_agent_port(),
          interfaces=>_fw_host_interfaces(\@zones),
          installed=>($backend eq 'firewalld'?true():false()),install=>$pkg};
}

sub _fw_info {
  my($force)=@_;
  my $now=time();
  if(!$force && $FW_INFO_CACHE && ($now-$FW_INFO_CACHE_AT)<$FW_INFO_CACHE_TTL){
    return $FW_INFO_CACHE;
  }
  my $info=_fw_info_uncached();
  $FW_INFO_CACHE=$info; $FW_INFO_CACHE_AT=$now;
  return $info;
}

# Der Agent-Listener muss den Start von firewalld ueberleben. firewalld startet
# mit der Standardzone, die nur ssh kennt; ohne vorher gesetzte Selbstschutzregel
# sperrt sich der Agent beim ersten Start selbst aus und ist ueber das Portal
# nicht mehr erreichbar. Die Regeln werden deshalb mit firewall-offline-cmd in
# die permanente Konfiguration geschrieben, BEVOR der Dienst startet.
sub _fw_offline_bin {
  for my $f ('/usr/bin/firewall-offline-cmd','/usr/sbin/firewall-offline-cmd'){ return $f if -x $f }
  return '';
}

sub _fw_agent_port {
  # Core.pm haelt die Agent-Konfiguration in package main. Der voll qualifizierte
  # Zugriff vermeidet eine zweite our-Deklaration in diesem Modul.
  my $cfg = $main::global;
  my $listen = (ref($cfg) eq 'HASH' ? ($cfg->{listen} // '') : '');
  my $port='';
  if   ($listen =~ /\]:(\d{1,5})\z/){ $port=$1 }
  elsif($listen =~ /:(\d{1,5})\z/){ $port=$1 }
  elsif($listen =~ /\A(\d{1,5})\z/){ $port=$1 }
  $port=5008 unless $port && $port>0 && $port<65536;
  return $port;
}

sub _fw_self_protect {
  my $off=_fw_offline_bin();
  return {ok=>false(),reason=>'firewall-offline-cmd ist nicht verfuegbar'} unless $off;
  my($zrc,$zone)=_fw_run($off,'--get-default-zone'); chomp $zone;
  $zone='public' if $zrc || !length $zone;
  my $port=_fw_agent_port(); my @rules; my $failed=0;
  for my $spec (['--add-service','ssh'],['--add-port',"$port/tcp"]){
    my($rc,$out)=_fw_run($off,'--zone',$zone,@$spec);
    my $ok=(!$rc || $out =~ /ALREADY_ENABLED/) ? 1 : 0; $failed++ unless $ok;
    push @rules,{rule=>$spec->[1],ok=>($ok?true():false()),output=>$out};
  }
  return {ok=>($failed?false():true()),reason=>($failed?'Selbstschutzregeln konnten nicht geschrieben werden':''),
          zone=>$zone,agent_port=>$port,rules=>\@rules};
}

sub _fw_ensure_running {
  my $st=_fw_service_state();
  die 'firewalld ist nicht installiert' unless $st->{backend} eq 'firewalld';
  return {state=>$st,self_protect=>undef,started=>false()} if $st->{active};
  my $prot=_fw_self_protect();
  # Fail closed: lieber keine Regel anwenden als den Agenten aussperren.
  die "firewalld wurde nicht gestartet: $prot->{reason}. Ohne Selbstschutzregel fuer Port "._fw_agent_port()."/tcp waere der Agent nach dem Start nicht mehr erreichbar."
    unless $prot->{ok};
  my($rc,$out)=_fw_run('/usr/bin/systemctl','enable','--now','firewalld.service');
  die "firewalld konnte nicht gestartet werden: $out" if $rc;
  my $after=_fw_service_state();
  die 'firewalld laeuft nach dem Start nicht' unless $after->{active};
  return {state=>$after,self_protect=>$prot,started=>true()};
}

sub _fw_service_action {
  my($in)=@_; die 'Firewall-Dienstaktion muss Objekt sein' unless ref($in) eq 'HASH';
  my $action=lc(trim($in->{action}//''));
  die 'Aktion muss enable, disable oder restart sein' unless $action =~ /\A(?:enable|disable|restart)\z/;
  die 'firewalld ist nicht installiert' unless _fw_backend() eq 'firewalld';
  if($action eq 'enable'){
    my $run=_fw_ensure_running();
    _fw_cache_invalidate();
  return {ok=>true(),action=>$action,self_protect=>$run->{self_protect},started=>$run->{started}};
  }
  my @cmd = $action eq 'disable' ? ('/usr/bin/systemctl','disable','--now','firewalld.service')
          :                        ('/usr/bin/systemctl','restart','firewalld.service');
  my($rc,$out)=_fw_run(@cmd);
  die "firewalld $action fehlgeschlagen: $out" if $rc;
  _fw_cache_invalidate();
  return {ok=>true(),action=>$action,output=>$out};
}

sub _fw_validate_policy {
  my($in)=@_; die 'Firewall-Policy muss Objekt sein' unless ref($in) eq 'HASH';
  my $zone=trim($in->{zone}//'public'); die 'Ungueltige Zone' unless $zone =~ /\A[A-Za-z0-9_.-]{1,64}\z/;
  my @rules; my $raw=ref($in->{rules}) eq 'ARRAY' ? $in->{rules}:[]; die 'Maximal 64 Firewall-Regeln' if @$raw>64;
  for my $r (@$raw){ die 'Ungueltige Firewall-Regel' unless ref($r) eq 'HASH'; my $port=int($r->{port}//0); my $proto=lc(trim($r->{proto}//'tcp')); my $source=trim($r->{source}//'');
    die 'Ungueltiger Port' if $port<1||$port>65535; die 'Ungueltiges Protokoll' unless $proto eq 'tcp'||$proto eq 'udp';
    die 'Ungueltige Quelle' if length($source)>128 || ($source ne '' && $source !~ /\A[0-9A-Fa-f:.\/]+\z/);
    push @rules,{port=>$port,proto=>$proto,source=>$source,description=>substr(trim($r->{description}//''),0,120)};
  }
  return {zone=>$zone,rules=>\@rules};
}
sub trim { my($s)=@_; $s='' unless defined $s; $s=~s/^\s+|\s+$//g; return $s; }
sub _fw_preview {
  my($raw)=@_; my $p=_fw_validate_policy($raw); my $info=_fw_info(); my @cmd;
  die 'Firewall-Backend firewalld ist fuer Policy-Apply erforderlich' unless $info->{backend} eq 'firewalld';
  for my $r (@{$p->{rules}}){
    if($r->{source}){ push @cmd, sprintf('firewall-cmd --permanent --zone=%s --add-rich-rule=%s',$p->{zone},qq{'rule family="}.($r->{source}=~/:/?'ipv6':'ipv4').qq{" source address="$r->{source}" port port="$r->{port}" protocol="$r->{proto}" accept'}); }
    else { push @cmd, sprintf('firewall-cmd --permanent --zone=%s --add-port=%d/%s',$p->{zone},$r->{port},$r->{proto}); }
  }
  return {ok=>true(),policy=>$p,commands=>\@cmd,warning=>'V1 wendet nur additive Allow-Regeln an; bestehende Regeln werden nicht geloescht. Dadurch wird ein Remote-Lockout vermieden.'};
}
sub _fw_apply {
  my($raw)=@_; my $p=_fw_validate_policy($raw); my $st=_fw_service_state(); die 'firewalld ist nicht verfuegbar' unless $st->{backend} eq 'firewalld';
  my($erc,$eout)=_fw_run('/usr/bin/systemctl','enable','--now','firewalld.service'); die "firewalld konnte nicht gestartet werden: $eout" if $erc;
  my @applied;
  eval {
    for my $r (@{$p->{rules}}){
      my @cmd=('/usr/bin/firewall-cmd','--permanent','--zone',$p->{zone});
      if($r->{source}){ my $fam=$r->{source}=~/:/?'ipv6':'ipv4'; push @cmd,'--add-rich-rule',qq{rule family="$fam" source address="$r->{source}" port port="$r->{port}" protocol="$r->{proto}" accept}; }
      else { push @cmd,'--add-port',"$r->{port}/$r->{proto}"; }
      my($rc,$out)=_fw_run(@cmd); die "Firewall-Regel fehlgeschlagen: $out" if $rc && $out !~ /ALREADY_ENABLED/; push @applied,{%$r};
    }
    my($rrc,$rout)=_fw_run('/usr/bin/firewall-cmd','--reload'); die "firewalld Reload fehlgeschlagen: $rout" if $rrc;
    1;
  } or die $@;
  _fw_cache_invalidate();
  return {ok=>true(),applied=>\@applied};
}


# Einzelport oder Portbereich, so wie firewalld ihn selbst ausgibt
# (z. B. "443/tcp" oder "8000-8100/tcp"). Ohne Bereichsunterstuetzung liessen
# sich vorhandene Bereichsregeln weder anlegen noch ueber das Portal loeschen.
sub _fw_check_port_spec {
  my($spec)=@_; $spec='' unless defined $spec;
  die 'Ungueltiger Port' unless $spec =~ /\A([1-9]\d{0,4})(?:-([1-9]\d{0,4}))?\/(tcp|udp|sctp)\z/;
  my($lo,$hi)=($1,$2);
  die 'Ungueltiger Port' if $lo<1 || $lo>65535;
  if(defined $hi){
    die 'Ungueltiger Port' if $hi<1 || $hi>65535;
    die 'Portbereich muss aufsteigend sein' if $hi<=$lo;
  }
  return 1;
}

# Netzwerkschnittstellen des Hosts mit ihrer firewalld-Zone. Ohne diese Liste
# laesst sich eine Zone im Portal nicht sinnvoll aktivieren, weil eine Zone erst
# durch ein zugeordnetes Interface oder eine Quelle wirksam wird.
sub _fw_host_interfaces {
  my($zones)=@_; my %map;
  for my $z (@{$zones||[]}){ $map{$_}=$z->{name} for @{$z->{interfaces}||[]} }
  my @out; my $dir='/sys/class/net';
  if(opendir(my $dh,$dir)){
    for my $n (sort grep { !/\A\.\.?\z/ } readdir($dh)){
      next if $n eq 'lo';
      next unless $n =~ /\A[A-Za-z0-9_.:-]{1,32}\z/;
      my $state=''; if(open(my $fh,'<',"$dir/$n/operstate")){ local $/; $state=<$fh>//''; close $fh; $state =~ s/\s+//g }
      push @out,{name=>$n,zone=>($map{$n}//''),state=>$state};
    }
    closedir $dh;
  }
  return \@out;
}

# Eingebaute firewalld-Zonen duerfen nicht geloescht werden.
sub _fw_builtin_zone {
  my($z)=@_; my %b=map{$_=>1} qw(block dmz docker drop external home internal nm-shared public trusted work);
  return $b{lc($z//'')} ? 1 : 0;
}

sub _fw_zone_admin {
  my($in)=@_; die 'Zonenaktion muss Objekt sein' unless ref($in) eq 'HASH';
  my $action=lc(trim($in->{action}//''));
  die 'Aktion muss create oder delete sein' unless $action eq 'create' || $action eq 'delete';
  my $zone=trim($in->{zone}//'');
  # firewalld begrenzt Zonennamen auf 17 Zeichen.
  die 'Ungueltiger Zonenname' unless $zone =~ /\A[A-Za-z0-9_-]{1,17}\z/;
  _fw_ensure_running();
  if($action eq 'delete'){
    die "Eingebaute Zone $zone kann nicht geloescht werden" if _fw_builtin_zone($zone);
    my($drc,$dz)=_fw_run('/usr/bin/firewall-cmd','--get-default-zone'); chomp $dz;
    die "Standardzone $zone kann nicht geloescht werden" if !$drc && $dz eq $zone;
    my($irc,$iout)=_fw_run('/usr/bin/firewall-cmd','--zone',$zone,'--list-interfaces'); chomp $iout;
    die "Zone $zone hat noch zugeordnete Interfaces: $iout" if !$irc && length $iout;
  }
  my $arg = $action eq 'create' ? "--new-zone=$zone" : "--delete-zone=$zone";
  my($rc,$out)=_fw_run('/usr/bin/firewall-cmd','--permanent',$arg);
  die "Zonenaktion fehlgeschlagen: $out" if $rc && $out !~ /NAME_CONFLICT/;
  my($rrc,$rout)=_fw_run('/usr/bin/firewall-cmd','--reload');
  die "firewalld Reload fehlgeschlagen: $rout" if $rrc;
  _fw_cache_invalidate();
  return {ok=>true(),action=>$action,zone=>$zone,existed=>($out =~ /NAME_CONFLICT/ ? true() : false())};
}

sub _fw_plan_change {
  my($in,$confirm)=@_; die 'Firewall-Aenderung muss Objekt sein' unless ref($in) eq 'HASH';
  my $action=lc(trim($in->{action}//'')); die 'Aktion muss add oder remove sein' unless $action eq 'add'||$action eq 'remove';
  my $zone=trim($in->{zone}//'public'); die 'Ungueltige Zone' unless $zone =~ /\A[A-Za-z0-9_.-]{1,64}\z/;
  my $kind=lc(trim($in->{kind}//'')); die 'Ungueltiger Regeltyp' unless $kind =~ /\A(?:port|service|source|source_port|rich_rule|interface)\z/;
  my $value=trim($in->{value}//''); die 'Wert fehlt' unless length($value); die 'Wert zu lang' if length($value)>1000;
  my @arg;
  if($kind eq 'port'){ _fw_check_port_spec($value); @arg=("--${action}-port=$value"); }
  elsif($kind eq 'service'){ die 'Ungueltiger Service' unless $value =~ /\A[A-Za-z0-9_.-]{1,64}\z/; @arg=("--${action}-service=$value"); }
  elsif($kind eq 'source'){ die 'Ungueltige Quelle' unless $value =~ /\A[0-9A-Fa-f:.\/]{1,128}\z/; @arg=("--${action}-source=$value"); }
  elsif($kind eq 'source_port'){
    my($source,$portproto)=split(/\|/,$value,2); die 'Ungueltige Quelle/Port-Regel' unless defined $source && defined $portproto;
    die 'Ungueltige Quelle' unless $source =~ /\A[0-9A-Fa-f:.\/]{1,128}\z/;
    _fw_check_port_spec($portproto); my($port,$proto)=split('/', $portproto);
    my $fam=$source =~ /:/ ? 'ipv6' : 'ipv4'; my $rule=qq{rule family="$fam" source address="$source" port port="$port" protocol="$proto" accept};
    @arg=("--${action}-rich-rule=$rule");
  }
  elsif($kind eq 'interface'){
    die 'Ungueltiger Interface-Name' unless $value =~ /\A[A-Za-z0-9_.:-]{1,32}\z/;
    # change-interface verschiebt ein bereits zugeordnetes Interface, statt an
    # der bestehenden Zuordnung zu scheitern.
    # Use the canonical firewall-cmd option form.  This avoids hosts/versions
    # where a value passed as a separate argv item is not accepted reliably.
    @arg = $action eq 'add' ? ("--change-interface=$value") : ("--remove-interface=$value");
  }
  else { die 'Ungueltige Rich Rule' if $value =~ /[\r\n\x00]/; @arg=("--${action}-rich-rule=$value"); }

  # Aussperrschutz: der Management-Zugang darf nicht versehentlich entfernt
  # werden. Bewusstes Entfernen bleibt moeglich, dann aber nur mit
  # confirm_lockout und damit als erkennbar gewollte Aktion.
  if($action eq 'remove' && !$confirm){
    my $port=_fw_agent_port();
    my $hit = ($kind eq 'port' && $value eq "$port/tcp") ? "Agent-Port $port/tcp"
            : ($kind eq 'service' && lc($value) eq 'ssh') ? 'Service ssh'
            : ($kind eq 'interface') ? "Interface $value"
            : '';
    die "$hit wuerde den Management-Zugang zu diesem Host entfernen. Aktion nur mit ausdruecklicher Bestaetigung moeglich." if $hit;
  }
  return {action=>$action,zone=>$zone,kind=>$kind,value=>$value,arg=>\@arg};
}

# Sammelanwendung: alle Aenderungen werden zuerst vollstaendig validiert und
# erst danach ausgefuehrt, mit genau einem Reload am Ende. Das vermeidet
# Zwischenzustaende, in denen ein Teil der Regeln aktiv ist und ein anderer nicht.
sub _fw_changes {
  my($in)=@_; die 'Firewall-Aenderungen muessen ein Objekt sein' unless ref($in) eq 'HASH';
  my $raw = ref($in->{changes}) eq 'ARRAY' ? $in->{changes} : [];
  die 'Keine Firewall-Aenderungen uebergeben' unless @$raw;
  die 'Maximal 32 Aenderungen pro Vorgang' if @$raw>32;
  my $confirm = $in->{confirm_lockout} ? 1 : 0;
  my @plan = map { _fw_plan_change($_,$confirm) } @$raw;

  my $run=_fw_ensure_running();
  my @results; my @failed;
  for my $p (@plan){
    my($rc,$out)=_fw_run('/usr/bin/firewall-cmd','--permanent',"--zone=$p->{zone}",@{$p->{arg}});
    my $already = ($out =~ /ALREADY_ENABLED/) ? 1 : 0;
    my $missing = ($out =~ /NOT_ENABLED/) ? 1 : 0;
    my $ok = (!$rc || $already || $missing) ? 1 : 0;
    push @failed, "$p->{zone}/$p->{value}" unless $ok;
    push @results,{zone=>$p->{zone},kind=>$p->{kind},action=>$p->{action},value=>$p->{value},
                   ok=>($ok?true():false()),already=>($already?true():false()),
                   missing=>($missing?true():false()),output=>substr($out,0,2000)};
  }
  my($rrc,$rout)=_fw_run('/usr/bin/firewall-cmd','--reload');
  push @failed,'reload' if $rrc;
  my $ok = @failed ? false() : true();
  my $err = @failed ? ('Nicht anwendbar: '.join(', ',@failed)) : '';
  _fw_cache_invalidate();
  return {ok=>$ok,error=>$err,applied=>scalar(@results),results=>\@results,
          reload_ok=>($rrc?false():true()),self_protect=>$run->{self_protect},
          firewalld_started=>$run->{started}};
}

sub _fw_change {
  my($in)=@_; die 'Firewall-Aenderung muss Objekt sein' unless ref($in) eq 'HASH';
  my $r=_fw_changes({changes=>[$in],confirm_lockout=>$in->{confirm_lockout}});
  my $first=$r->{results}[0] || {};
  die $r->{error} unless $r->{ok};
  return {ok=>true(),action=>$first->{action},zone=>$first->{zone},kind=>$first->{kind},
          value=>$first->{value},already=>$first->{already},missing=>$first->{missing},
          self_protect=>$r->{self_protect},firewalld_started=>$r->{firewalld_started}};
}
get '/firewall/info' => sub { shift->render(json=>_fw_info()); };
post '/firewall/install' => sub { my $c=shift; $c->render_later; my $sp=Mojo::IOLoop::Subprocess->new; $sp->run(sub{_fw_install()},sub{my($sub,$err,$res)=@_; return $c->render(json=>{ok=>false(),error=>"$err"},status=>400) if $err; $c->render(json=>$res)}); };
post '/firewall/preview' => sub { my $c=shift; my $in=$c->req->json; my $r=eval{_fw_preview($in)}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $c->render(json=>$r); };
post '/firewall/apply' => sub { my $c=shift; my $in=$c->req->json; my $r=eval{_fw_apply($in)}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $c->render(json=>$r); };
post '/firewall/zone' => sub { my $c=shift; my $in=$c->req->json; my $r=eval{_fw_zone_admin($in)}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $c->render(json=>$r); };
post '/firewall/changes' => sub { my $c=shift; my $in=$c->req->json; my $r=eval{_fw_changes($in)}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; return $c->render(json=>$r,status=>($r->{ok}?200:400)) };
post '/firewall/service' => sub { my $c=shift; my $in=$c->req->json; my $r=eval{_fw_service_action($in)}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $c->render(json=>$r); };
post '/firewall/change' => sub { my $c=shift; my $in=$c->req->json; my $r=eval{_fw_change($in)}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $c->render(json=>$r); };
1;
