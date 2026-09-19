package main;
use strict;
use warnings;
use utf8;
use Mojo::JSON qw(true false);
use Mojo::IOLoop;
use File::Basename qw(dirname);

our $logger;

my $F2B_JAIL_FILE='/etc/fail2ban/jail.d/config-manager.local';
my $F2B_FILTER_DIR='/etc/fail2ban/filter.d';

sub _f2b_run {
  my(@cmd)=@_;
  my $pid=open(my $fh,'-|',@cmd); die "Kommando konnte nicht gestartet werden" unless defined $pid;
  local $/; my $out=<$fh>//''; close $fh; my $rc=$?>>8;
  $out =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
  return($rc,substr($out,0,250000));
}
sub _f2b_atomic_write {
  my($path,$content,$mode)=@_; $mode//=0644;
  my $dir=dirname($path); die "Verzeichnis fehlt: $dir" unless -d $dir;
  my $tmp="$path.new.$$";
  open my $fh,'>',$tmp or die "Temporäre Datei nicht schreibbar: $!";
  print {$fh} $content; close $fh or die "Temporäre Datei konnte nicht geschlossen werden: $!";
  chmod $mode,$tmp; rename($tmp,$path) or die "Datei konnte nicht aktiviert werden: $!";
}
sub _f2b_read_file { my($p)=@_; return '' unless -f $p; open my $fh,'<',$p or return ''; local $/; my $s=<$fh>//''; close $fh; return $s; }
sub _f2b_installed { return (-x '/usr/bin/fail2ban-client' || -x '/usr/local/bin/fail2ban-client') ? true() : false(); }
sub _f2b_client { return -x '/usr/bin/fail2ban-client' ? '/usr/bin/fail2ban-client' : '/usr/local/bin/fail2ban-client'; }
sub _f2b_install_info {
  # Status refresh must never trigger package/repository metadata lookups when
  # fail2ban is already installed. On SLES/openSUSE those lookups can dominate
  # the complete GUI load time although fail2ban-client itself is fast.
  if (_f2b_installed()) {
    return {supported=>true(),package=>'fail2ban',installed=>true(),available=>true(),versions=>[]};
  }
  my $os=eval{_pkg_read_os()}; return {supported=>false(),available=>false(),error=>"$@"} if $@;
  my $preview=eval{_pkg_preview($os,'fail2ban')};
  return {supported=>true(),package=>'fail2ban',os=>$os,available=>false(),error=>"$@"} if $@;
  return {supported=>true(),package=>'fail2ban',os=>$os,installed=>$preview->{installed},available=>(@{$preview->{available}||[]}?true():false()),versions=>$preview->{available}||[]};
}
sub _f2b_service_state {
  my($arc,$active)=_f2b_run('/usr/bin/systemctl','is-active','fail2ban.service'); chomp $active;
  my($erc,$enabled)=_f2b_run('/usr/bin/systemctl','is-enabled','fail2ban.service'); chomp $enabled;
  return {active=>($arc==0?true():false()),active_state=>$active||'unknown',enabled=>($erc==0?true():false()),enabled_state=>$enabled||'unknown'};
}
sub _f2b_parse_status {
  my $client=_f2b_client(); my($rc,$out)=_f2b_run($client,'status'); return {ok=>false(),jails=>[],raw=>$out} if $rc;
  my($list)=$out =~ /Jail list:\s*(.+)$/m; my @jails=grep {length} map {s/^\s+|\s+$//gr} split(/\s*,\s*/,$list//''); my @rows;
  for my $j (@jails){ next unless $j =~ /\A[A-Za-z0-9_.-]+\z/; my($jrc,$jo)=_f2b_run($client,'status',$j); next if $jrc; my($cur)=$jo =~ /Currently banned:\s*(\d+)/; my($total)=$jo =~ /Total banned:\s*(\d+)/; my($ips)=$jo =~ /Banned IP list:\s*(.*)$/m; my @ips=grep {/^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f:]+)$/} split(/\s+/,$ips//''); push @rows,{name=>$j,current_banned=>0+($cur//0),total_banned=>0+($total//0),banned_ips=>\@ips,raw=>$jo}; }
  return {ok=>true(),jails=>\@rows,raw=>$out};
}
sub _f2b_templates {
  return [
    {id=>'sshd',label=>'SSH',filter=>'sshd',backend=>'systemd',port=>'ssh',logpath=>'',maxretry=>5,findtime=>600,bantime=>3600},
    {id=>'apache-auth',label=>'Apache Auth',filter=>'apache-auth',backend=>'auto',port=>'http,https',logpath=>'/var/log/apache2/error_log',maxretry=>5,findtime=>600,bantime=>1800},
    {id=>'nginx-http-auth',label=>'Nginx HTTP Auth',filter=>'nginx-http-auth',backend=>'auto',port=>'http,https',logpath=>'/var/log/nginx/error.log',maxretry=>5,findtime=>600,bantime=>1800},
    {id=>'postfix-sasl',label=>'Postfix SASL',filter=>'postfix-sasl',backend=>'systemd',port=>'smtp,submission,465',logpath=>'',maxretry=>5,findtime=>600,bantime=>3600},
    {id=>'dovecot',label=>'Dovecot',filter=>'dovecot',backend=>'systemd',port=>'pop3,pop3s,imap,imaps,submission,465,sieve',logpath=>'',maxretry=>5,findtime=>600,bantime=>3600},
    {id=>'recidive',label=>'Recidive',filter=>'recidive',backend=>'auto',port=>'all',logpath=>'/var/log/fail2ban.log',maxretry=>5,findtime=>86400,bantime=>604800},
    {id=>'modsecurity',label=>'ModSecurity Blocking',filter=>'cm-modsecurity',backend=>'auto',port=>'http,https',logpath=>'/var/log/apache2/error_log',maxretry=>5,findtime=>600,bantime=>7200,managed_regex=>'ModSecurity: Access denied'},
    {id=>'web-scanner',label=>'Web Scanner',filter=>'cm-web-scanner',backend=>'auto',port=>'http,https',logpath=>'/var/log/apache2/access_log',maxretry=>4,findtime=>600,bantime=>3600,managed_regex=>'web-scanner'},
    {id=>'custom',label=>'Custom',filter=>'',backend=>'auto',port=>'all',logpath=>'',maxretry=>5,findtime=>600,bantime=>1800}
  ];
}
sub _f2b_defaults { return {ignoreip=>'127.0.0.1/8 ::1',jails=>[]}; }
sub _f2b_filter_file_for { my($name)=@_; return "$F2B_FILTER_DIR/cm-managed-$name.conf"; }
sub _f2b_read_filter_regex {
  my($filter)=@_; return ('','') unless $filter =~ /^cm-(?:managed-[a-z0-9_.-]+|modsecurity|web-scanner|apache-auth)$/;
  my $p = $filter =~ /^cm-managed-(.+)$/ ? _f2b_filter_file_for($1) : "$F2B_FILTER_DIR/$filter.conf";
  my $s=_f2b_read_file($p); my($fr)=$s =~ /^\s*failregex\s*=\s*(.*?)\s*$/m; my($ir)=$s =~ /^\s*ignoreregex\s*=\s*(.*?)\s*$/m; return($fr//'',$ir//'');
}
sub _f2b_parse_managed_config {
  my $cfg=_f2b_defaults(); my $s=_f2b_read_file($F2B_JAIL_FILE); return $cfg unless length $s;
  my($section,$row)=('',undef); my @jails;
  for my $line(split /\n/,$s){
    my $raw=$line; $line=~s/[;#].*$//; next unless $line =~ /\S/;
    if($line =~ /^\s*\[([^\]]+)\]/){
      if($row){ push @jails,$row; }
      $section=$1; $row=undef;
      if($section ne 'DEFAULT' && $section =~ /^[A-Za-z0-9_.-]+$/){ $row={name=>$section,enabled=>false(),filter=>$section,backend=>'auto',port=>'all',logpath=>'',maxretry=>5,findtime=>600,bantime=>1800,action=>'',failregex=>'',ignoreregex=>''}; }
      next;
    }
    next unless $line =~ /^\s*([A-Za-z0-9_.-]+)\s*=\s*(.*?)\s*$/; my($k,$v)=(lc($1),$2);
    if($section eq 'DEFAULT'){ $cfg->{ignoreip}=$v if $k eq 'ignoreip'; next; }
    next unless $row;
    $row->{enabled}=($v=~/^(?:true|1|yes)$/i?true():false()) if $k eq 'enabled';
    $row->{filter}=$v if $k eq 'filter'; $row->{backend}=$v if $k eq 'backend'; $row->{port}=$v if $k eq 'port'; $row->{logpath}=$v if $k eq 'logpath'; $row->{action}=$v if $k eq 'action';
    $row->{maxretry}=0+$v if $k eq 'maxretry'&&$v=~/^\d+$/; $row->{findtime}=0+$v if $k eq 'findtime'&&$v=~/^\d+$/; $row->{bantime}=0+$v if $k eq 'bantime'&&$v=~/^\d+$/;
  }
  push @jails,$row if $row;
  for my $j (@jails){ my($fr,$ir)=_f2b_read_filter_regex($j->{filter}//''); $j->{failregex}=$fr; $j->{ignoreregex}=$ir; }
  $cfg->{jails}=\@jails; return $cfg;
}
sub _f2b_safe_name { my($s)=@_; $s=lc($s//''); $s =~ s/^\s+|\s+$//g; die 'Jail-Name erforderlich' unless length $s; die 'Ungültiger Jail-Name' unless $s =~ /\A[a-z0-9][a-z0-9_.-]{0,47}\z/; return $s; }
sub _f2b_validate_cfg {
  my($in)=@_; die 'Konfiguration muss Objekt sein' unless ref($in) eq 'HASH';
  my $ignore=join(' ',grep {length} map {s/^\s+|\s+$//gr} split(/[\s,]+/,$in->{ignoreip}//'127.0.0.1/8 ::1'));
  die 'Allowlist ist zu lang' if length($ignore)>2048; die 'Ungültige Zeichen in Allowlist' unless $ignore =~ /\A[0-9A-Fa-f:.\/\s]+\z/;
  my $raw=ref($in->{jails}) eq 'ARRAY' ? $in->{jails} : []; die 'Maximal 64 verwaltete Fail2ban-Jails' if @$raw>64;
  my @jails; my %seen;
  for my $src (@$raw){
    die 'Ungültige Jail' unless ref($src) eq 'HASH'; my $name=_f2b_safe_name($src->{name}); die "Jail doppelt: $name" if $seen{$name}++;
    my $filter=lc($src->{filter}//$name); die "Ungültiger Filter für $name" unless $filter =~ /\A[a-z0-9][a-z0-9_.-]{0,63}\z/;
    my $backend=lc($src->{backend}//'auto'); die "Ungültiges Backend für $name" unless $backend =~ /\A(?:auto|systemd|polling|pyinotify|gamin)\z/;
    my $port=$src->{port}//'all'; die "Ungültiger Port für $name" if length($port)>200 || $port !~ /\A[a-zA-Z0-9_,:\/-]+\z/;
    my $logpath=$src->{logpath}//''; die "Ungültiger Logpfad für $name" if length($logpath)>512 || $logpath =~ /[\r\n]/; die "Logpfad muss unter /var/log liegen" if length($logpath) && $logpath !~ m{\A/var/log/[A-Za-z0-9_./*?@%:+-]+\z};
    my $action=$src->{action}//''; die "Ungültige Action für $name" if length($action)>160 || $action =~ /[\r\n;`|&<>]/;
    my ($max,$ft,$bt)=(int($src->{maxretry}//5),int($src->{findtime}//600),int($src->{bantime}//1800));
    die "Ungültiges maxretry für $name" if $max<1||$max>1000; die "Ungültiges findtime für $name" if $ft<1||$ft>2592000; die "Ungültiges bantime für $name" if $bt<1||$bt>31536000;
    my ($fr,$ir)=($src->{failregex}//'',$src->{ignoreregex}//'');
    for([$fr,'Failregex'],[$ir,'Ignoreregex']){ die "$_->[1] für $name zu lang" if length($_->[0])>4000; die "$_->[1] für $name darf keine Zeilenumbrüche enthalten" if $_->[0] =~ /[\r\n]/; }
    if(length($fr)){ die "Failregex für $name muss <HOST> enthalten" unless index($fr,'<HOST>')>=0; $filter='cm-managed-'.$name; }
    push @jails,{name=>$name,enabled=>($src->{enabled}?true():false()),filter=>$filter,backend=>$backend,port=>$port,logpath=>$logpath,action=>$action,maxretry=>$max,findtime=>$ft,bantime=>$bt,failregex=>$fr,ignoreregex=>$ir};
  }
  return {ignoreip=>$ignore,jails=>\@jails};
}
sub _f2b_render {
  my($cfg)=@_; my @x=('# Managed by Local Infrastructure Stack - Config Manager','[DEFAULT]','ignoreip = '.$cfg->{ignoreip},'usedns = no','');
  for my $j (@{$cfg->{jails}}){ push @x,"[$j->{name}]",'enabled = '.($j->{enabled}?'true':'false'),'filter = '.$j->{filter},'backend = '.$j->{backend},'port = '.$j->{port}; push @x,'logpath = '.$j->{logpath} if length $j->{logpath}; push @x,'action = '.$j->{action} if length $j->{action}; push @x,'maxretry = '.$j->{maxretry},'findtime = '.$j->{findtime},'bantime = '.$j->{bantime},''; }
  return join("\n",@x)."\n";
}
sub _f2b_filters {
  my($cfg)=@_; my %out;
  for my $j (@{$cfg->{jails}}){ next unless length($j->{failregex}//''); my $p=_f2b_filter_file_for($j->{name}); $out{$p}="# Managed by Local Infrastructure Stack\n[Definition]\nfailregex = $j->{failregex}\nignoreregex = ".($j->{ignoreregex}//'')."\n"; }
  return \%out;
}
sub _f2b_existing_managed_filters {
  my @x; return \@x unless -d $F2B_FILTER_DIR; opendir(my $dh,$F2B_FILTER_DIR) or return \@x; while(my $f=readdir $dh){ push @x,"$F2B_FILTER_DIR/$f" if $f =~ /^cm-managed-[a-z0-9_.-]+\.conf$/; } closedir $dh; return \@x;
}
sub _f2b_install {
  my $os=_pkg_read_os(); return {ok=>true(),installed=>true(),already_installed=>true(),os=>$os} if _f2b_installed(); my @steps;
  if($os->{manager} eq 'zypper'){
    my $ed=_pkg_check($os,'ed'); my $busy=_pkg_check($os,'busybox-ed');
    if(!$ed->{installed} && $busy->{installed}){ my $rm=_pkg_mutate($os,'remove','busybox-ed',''); die "busybox-ed konnte fuer die Fail2ban-Abhaengigkeit nicht entfernt werden: $rm->{output}" unless $rm->{ok}; push @steps,'busybox-ed entfernt'; }
    if(!_pkg_check($os,'ed')->{installed}){ my $ei=_pkg_mutate($os,'install','ed',''); die "ed konnte nicht installiert werden: $ei->{output}" unless $ei->{ok}; push @steps,'ed installiert'; }
  }
  my $r=_pkg_mutate($os,'install','fail2ban',''); die "Fail2ban-Installation fehlgeschlagen: $r->{output}" unless $r->{ok}; push @steps,'fail2ban installiert'; die 'fail2ban-client fehlt nach Installation' unless _f2b_installed(); return {ok=>true(),installed=>true(),os=>$os,steps=>\@steps,output=>$r->{output}};
}
sub _f2b_save {
  my($raw)=@_; die 'Fail2ban ist nicht installiert' unless _f2b_installed(); my $cfg=_f2b_validate_cfg($raw); my $content=_f2b_render($cfg); my $old=_f2b_read_file($F2B_JAIL_FILE); my $filters=_f2b_filters($cfg); my $existing=_f2b_existing_managed_filters(); my %oldf=map {$_=>_f2b_read_file($_)} (@$existing,keys %$filters);
  eval {
    my %keep=map {$_=>1} keys %$filters; for my $p (@$existing){ unlink $p unless $keep{$p}; }
    for my $p(keys %$filters){_f2b_atomic_write($p,$filters->{$p},0644)} _f2b_atomic_write($F2B_JAIL_FILE,$content,0644);
    my($trc,$tout)=_f2b_run(_f2b_client(),'-t'); die "Fail2ban Configtest fehlgeschlagen: $tout" if $trc;
    my($erc,$eout)=_f2b_run('/usr/bin/systemctl','enable','--now','fail2ban.service'); die "Fail2ban konnte nicht gestartet werden: $eout" if $erc;
    my($rrc,$rout)=_f2b_run(_f2b_client(),'reload'); die "Fail2ban Reload fehlgeschlagen: $rout" if $rrc; 1;
  } or do {
    my $e=$@||'Unbekannter Fehler'; if(length $old){_f2b_atomic_write($F2B_JAIL_FILE,$old,0644)}else{unlink $F2B_JAIL_FILE if -e $F2B_JAIL_FILE}
    for my $p (keys %oldf){ if(length $oldf{$p}){_f2b_atomic_write($p,$oldf{$p},0644)}else{unlink $p if -e $p} } eval{_f2b_run(_f2b_client(),'reload')}; die $e;
  };
  return {ok=>true(),config=>$cfg};
}
sub _f2b_unban {
  my($jail,$ip)=@_; die 'Ungültiger Jail-Name' unless $jail =~ /\A[A-Za-z0-9_.-]{1,64}\z/; die 'Ungültige IP-Adresse' unless $ip =~ /\A(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f:]+)\z/; die 'Fail2ban ist nicht installiert' unless _f2b_installed(); my($rc,$out)=_f2b_run(_f2b_client(),'set',$jail,'unbanip',$ip); die "Entsperren fehlgeschlagen: $out" if $rc; return {ok=>true(),jail=>$jail,ip=>$ip};
}

get '/fail2ban/info' => sub { my $c=shift; my $installed=_f2b_installed(); my $service=$installed?_f2b_service_state():{active=>false(),enabled=>false()}; my $status=$installed&&$service->{active}?_f2b_parse_status():{ok=>false(),jails=>[]}; $c->render(json=>{ok=>true(),installed=>$installed,install=>_f2b_install_info(),service=>$service,status=>$status,config=>_f2b_parse_managed_config(),templates=>_f2b_templates()}); };
post '/fail2ban/install' => sub { my $c=shift; $c->render_later; my $sp=Mojo::IOLoop::Subprocess->new; $sp->run(sub{_f2b_install()},sub{my($sub,$err,$res)=@_; return $c->render(json=>{ok=>false(),error=>"$err"},status=>400) if $err; $c->render(json=>$res)}); };
post '/fail2ban/config' => sub { my $c=shift; my $in=$c->req->json; return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in) eq 'HASH'; my $r=eval{_f2b_save($in)}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $c->render(json=>$r); };
post '/fail2ban/unban' => sub { my $c=shift; my $in=$c->req->json; return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in) eq 'HASH'; my $r=eval{_f2b_unban($in->{jail}//'', $in->{ip}//'')}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $c->render(json=>$r); };

1;
