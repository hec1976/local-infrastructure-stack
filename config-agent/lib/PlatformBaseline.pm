package main;
use strict;
use warnings;
use utf8;
use Mojo::JSON qw(true false decode_json);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(strftime);
use Digest::SHA ();

our ($global, $logger, $VERSION, $api_token);

sub _pb_run {
  my (@cmd)=@_;
  my $pid=open(my $fh,'-|');
  die "fork fehlgeschlagen: $!" unless defined $pid;
  if($pid==0){ open STDERR,'>&STDOUT'; exec @cmd; POSIX::_exit(127); }
  local $/; my $out=<$fh>//''; close $fh; my $rc=$? >> 8;
  return ($rc,$out);
}
sub _pb_service {
  my($unit)=@_;
  my($erc,$e)=_pb_run('systemctl','is-enabled',$unit); $e=~s/\s+$//;
  my($arc,$a)=_pb_run('systemctl','is-active',$unit); $a=~s/\s+$//;
  return {unit=>$unit,enabled=>($erc==0?true():false()),active=>($arc==0?true():false()),enabled_state=>$e||'unknown',active_state=>$a||'unknown'};
}
sub _pb_command_version {
  my($cmd,@args)=@_; my($rc,$out)=_pb_run($cmd,@args); $out=~s/[\r\n]+/ /g; $out=~s/^\s+|\s+$//g; return $rc==0?$out:'';
}
sub _pb_package_state {
  my($name,$with_available)=@_; $with_available=1 unless defined $with_available;
  my $os=_pkg_read_os(); my $check=_pkg_check($os,$name); my $available=false();
  if($with_available){
    my $preview=eval{_pkg_preview($os,$name)}||{};
    $available=(ref($preview->{available}) eq 'ARRAY' && @{$preview->{available}})?true():false();
  }
  return {name=>$name,installed=>$check->{installed}?true():false(),version=>$check->{version}//'',available=>$available,availability_checked=>($with_available?true():false()),install_supported=>true(),manager=>$os->{manager},os=>$os};
}

sub _pb_monit_secret_file { return '/var/lib/service/config-agent/secrets/monit-status.env'; }
sub _pb_read_monit_secret {
  my $file=_pb_monit_secret_file();
  my $legacy='/opt/service/env/monit-status.env';
  my $readfile=(-f $file && -r $file && !-l $file) ? $file : ((-f $legacy && -r $legacy && !-l $legacy) ? $legacy : '');
  return {file=>$file,present=>false(),username=>'',legacy=>false()} unless $readfile;
  open my $fh,'<',$readfile or return {file=>$file,present=>false(),username=>'',legacy=>false()};
  my($u,$p)=('',''); while(my $line=<$fh>){ $line=~s/[\r\n]+$//; my($k,$v)=split(/=/,$line,2); next unless defined $v; $u=$v if $k eq 'MONIT_USER'; $p=$v if $k eq 'MONIT_PASSWORD'; } close $fh;
  return {file=>$file,present=>(length($u)&&length($p)?true():false()),username=>$u,legacy=>($readfile eq $legacy?true():false())};
}
sub _pb_monit_current {
  my($main,$drop)=_pb_monit_paths(); my($bind,$port,$user)=('127.0.0.1',2812,'monitadmin');
  if(-f $drop && !-l $drop){ open my $fh,'<',$drop; local $/; my $txt=<$fh>//''; close $fh; $bind=$1 if $txt =~ /^\s*use address\s+(\S+)/m; $port=0+$1 if $txt =~ /^\s*set httpd port\s+(\d+)/m; $user=$1 if $txt =~ /^\s*allow\s+([A-Za-z0-9_.-]+):/m; }
  my $sec=_pb_read_monit_secret(); $user=$sec->{username} if $sec->{present} && $sec->{username};
  return {bind=>$bind,port=>$port,username=>$user,secret_present=>$sec->{present},secret_file=>$sec->{file},config_path=>$drop};
}
sub _pb_write_monit_secret {
  my($user,$password)=@_; my $file=_pb_monit_secret_file(); make_path(dirname($file),{mode=>0750}) unless -d dirname($file);
  safe_write_file($file,"MONIT_USER=$user\nMONIT_PASSWORD=$password\n",1); chmod 0600,$file; return $file;
}
sub _pb_monit_paths {
  if(-d '/etc/monit/conf-enabled' || -d '/etc/monit/conf-available'){ return ('/etc/monit/monitrc','/etc/monit/conf-enabled/cm-baseline.monitrc'); }
  return ('/etc/monitrc','/etc/monit.d/cm-baseline.monitrc');
}
sub _pb_monit_config {
  my($bind,$port,$user,$password)=@_;
  die 'Monit Bind-Adresse ungueltig' unless $bind =~ /\A(?:127\.0\.0\.1|0\.0\.0\.0|[A-Za-z0-9_.:-]{1,128})\z/;
  die 'Monit Port ungueltig' unless $port =~ /^\d+$/ && $port>=1024 && $port<=65535;
  die 'Monit Benutzer ungueltig' unless $user =~ /\A[A-Za-z0-9_.-]{1,64}\z/;
  die 'Monit Passwort muss mindestens 12 Zeichen haben' unless length($password)>=12 && length($password)<=256;
  die 'Monit Passwort enthaelt ungueltige Zeichen' unless $password =~ /\A[A-Za-z0-9._!@%+=:-]{12,256}\z/;
  return "# Managed by Config Manager client baseline\nset httpd port $port\n    use address $bind\n    allow localhost\n    allow $user:\"$password\"\n";
}
sub _pb_write_monit {
  my($cfg,$user,$password)=@_; my($main,$drop)=_pb_monit_paths(); my $dir=dirname($drop); make_path($dir,{mode=>0755}) unless -d $dir;
  my($main_txt,$main_mode,$main_backup,$drop_backup,$secret_backup);
  my $secret_file=_pb_monit_secret_file();
  if(-f $main){
    open my $fh,'<',$main or die "Monit Hauptkonfiguration nicht lesbar: $!"; local $/; $main_txt=<$fh>//''; close $fh;
    $main_mode=(stat($main))[2]&07777;
    # Bestehende HTTP-Definitionen aus der Hauptkonfiguration werden beim
    # Speichern automatisch in die von der Baseline verwaltete Drop-in-Datei
    # migriert. Das verhindert doppelte `set httpd`-Bloecke und erspart eine
    # manuelle Vorbereinigung ueber Managed Configs. Die Hauptdatei wird vor
    # jeder Aenderung gesichert und bei einem fehlgeschlagenen Configtest
    # vollstaendig zurueckgerollt.
  }
  if(-f $drop){ $drop_backup=$drop.'.bak.'.strftime('%Y%m%d_%H%M%S',localtime); my($rc,$out)=_pb_run('cp','-a','--',$drop,$drop_backup); die "Monit Backup fehlgeschlagen: $out" if $rc; }
  if(-f $main){ $main_backup=$main.'.bak.'.strftime('%Y%m%d_%H%M%S',localtime); my($rc,$out)=_pb_run('cp','-a','--',$main,$main_backup); die "Monit Hauptconfig-Backup fehlgeschlagen: $out" if $rc; }
  if(-f $secret_file){ $secret_backup=$secret_file.'.bak.'.strftime('%Y%m%d_%H%M%S',localtime); my($rc,$out)=_pb_run('cp','-a','--',$secret_file,$secret_backup); die "Monit Secret-Backup fehlgeschlagen: $out" if $rc; }
  my $ok=eval {
    safe_write_file($drop,$cfg,1); chmod 0600,$drop;
    if(defined $main_txt){
      my $new=$main_txt;
      # Einen bereits vorhandenen aktiven HTTP-Block aus der Hauptdatei
      # entfernen. Er wird ab jetzt ausschliesslich durch $drop verwaltet.
      # Der Block beginnt bei `set httpd` und endet vor der naechsten
      # nicht eingerueckten Direktive. Kommentare/Leerzeilen innerhalb des
      # Blocks bleiben Teil des entfernten Abschnitts.
      $new =~ s{(?ms)^[ \t]*set[ \t]+httpd\b.*?(?=^\S|\z)}{# Monit HTTP endpoint managed by Config Manager baseline ($drop)\n}g;
      my $need = ($drop =~ m{/conf-enabled/}) ? q{} : 'include /etc/monit.d/*.monitrc';
      if($need ne '' && $new !~ /^\s*include\s+\/etc\/monit\.d\/\*\.monitrc\s*$/m){
        $new.="\n" unless $new =~ /\n\z/; $new.="$need\n";
      }
      if($new ne $main_txt){ safe_write_file($main,$new,1); chmod($main_mode||0600,$main); }
    }
    my($trc,$tout)=_pb_run('monit','-t'); die "Monit Configtest fehlgeschlagen: $tout" if $trc;
    _pb_write_monit_secret($user,$password);
    my($rrc,$rout)=_pb_run('systemctl','enable','--now','monit.service'); die "Monit Start fehlgeschlagen: $rout" if $rrc;
    _pb_run('systemctl','reload','monit.service');
    my $exp=_pb_monit_exporter_info();
    if($exp->{installed}){
      my($erc,$eout)=_pb_run('systemctl','enable','--now','monit-prometheus-exporter.service'); die "Monit Exporter Start fehlgeschlagen: $eout" if $erc;
      _pb_run('systemctl','restart','monit-prometheus-exporter.service');
    }
    1;
  };
  if(!$ok){
    my $err=$@;
    if(defined $drop_backup && -f $drop_backup){ _pb_run('cp','-a','--',$drop_backup,$drop); } else { unlink $drop if -f $drop; }
    if(defined $main_backup && -f $main_backup){ _pb_run('cp','-a','--',$main_backup,$main); }
    if(defined $secret_backup && -f $secret_backup){ _pb_run('cp','-a','--',$secret_backup,$secret_file); } else { unlink $secret_file if -f $secret_file; }
    die $err;
  }
  return {ok=>true(),path=>$drop};
}


sub _pb_monit_exporter_info {
  my $os=_pkg_read_os();
  my $pkg=_pkg_check($os,'monit-prometheus-exporter');
  my $svc=_pb_service('monit-prometheus-exporter.service');
  my $healthy=false();
  if($svc->{active}){
    my($rc,$out)=_pb_run('curl','-fsS','--max-time','2','http://127.0.0.1:9108/metrics');
    $healthy=($rc==0 && $out =~ /^monit_up\s+1(?:\.0+)?\s*$/m)?true():false();
  }
  return {installed=>($pkg->{installed}?true():false()),version=>$pkg->{version}//'',package=>'monit-prometheus-exporter',binary=>'/usr/bin/monit-prometheus-exporter',unit=>'monit-prometheus-exporter.service',service=>$svc,listen=>'127.0.0.1:9108',metrics_url=>'http://127.0.0.1:9108/metrics',healthy=>$healthy,owner=>'rpm'};
}

sub _pb_baseline_repo_state {
  my $os=_pkg_read_os();
  my $meta=_pkg_check($os,'client-baseline');
  my $enabled=false(); my $url='';
  if(($os->{manager}//'') eq 'zypper'){
    my($rc,$out)=_pb_run('zypper','--non-interactive','lr','-u');
    if($rc==0){
      for my $line (split /\n/,$out){
        next unless $line =~ /\|\s*infrastructure-baseline\s*\|/;
        $enabled=true();
        my @f=split /\|/,$line; $url=$f[-1]//''; $url=~s/^\s+|\s+$//g;
        last;
      }
    }
  }
  return {repository_id=>'infrastructure-baseline',enabled=>$enabled,url=>$url,meta_package=>'client-baseline',meta_installed=>($meta->{installed}?true():false()),meta_version=>$meta->{version}//'',manager=>$os->{manager}};
}
sub _pb_validate_repo_url {
  my($url)=@_; $url//=q{};
  die 'Baseline Repository URL fehlt' unless length($url);
  die 'Baseline Repository muss HTTPS verwenden' unless $url =~ m{\Ahttps://[A-Za-z0-9._:-]+/[A-Za-z0-9._~:/-]*/?\z};
  return $url;
}
sub _pb_ensure_baseline_repo {
  my($url)=@_; $url=_pb_validate_repo_url($url); my $os=_pkg_read_os();
  die 'Baseline Repository wird derzeit nur fuer zypper/SLES/openSUSE unterstuetzt' unless ($os->{manager}//'') eq 'zypper';
  my($lrc,$list)=_pb_run('zypper','--non-interactive','lr','-u');
  if($lrc==0 && $list =~ /\|\s*teko-baseline\s*\|/){ _pb_run('zypper','--non-interactive','removerepo','teko-baseline'); } # legacy repository id
  my $have=($lrc==0 && $list =~ /\|\s*infrastructure-baseline\s*\|/) ? 1 : 0;
  if($have){
    my($rrc,$rout)=_pb_run('zypper','--non-interactive','removerepo','infrastructure-baseline');
    die "Bestehendes Baseline Repository konnte nicht aktualisiert werden: $rout" if $rrc;
  }
  my($arc,$aout)=_pb_run('zypper','--non-interactive','addrepo','-G','--check','--refresh',$url,'infrastructure-baseline');
  die "Baseline Repository konnte nicht eingerichtet werden: $aout" if $arc;
  my($rrc,$rout)=_pb_run('zypper','--non-interactive','refresh','infrastructure-baseline');
  die "Baseline Repository konnte nicht aktualisiert werden: $rout" if $rrc;
  return {changed=>true(),repository_id=>'infrastructure-baseline',url=>$url};
}

sub _pb_job_dir { return '/var/lib/service/config-agent/jobs/baseline'; }
sub _pb_job_file { my($id)=@_; die 'ungueltige Job-ID' unless defined($id) && $id =~ /\Abl-[A-Za-z0-9_.-]{8,96}\z/; return _pb_job_dir()."/$id.json"; }
sub _pb_job_write {
  my($job)=@_; make_path(_pb_job_dir(),{mode=>0700}) unless -d _pb_job_dir();
  my $file=_pb_job_file($job->{job_id}); $job->{updated_at}=time();
  safe_write_file($file,Mojo::JSON::encode_json($job)."\n",1); chmod 0600,$file; return $job;
}
sub _pb_job_read {
  my($id)=@_; my $file=_pb_job_file($id); return undef unless -f $file && -r $file && !-l $file;
  open my $fh,'<',$file or return undef; local $/; my $raw=<$fh>//''; close $fh; my $x=eval{decode_json($raw)}; return ref($x) eq 'HASH'?$x:undef;
}
sub _pb_job_update {
  my($job,$pct,$stage,$message,$state)=@_; $job->{progress_percent}=0+$pct; $job->{stage}=$stage; $job->{stage_message}=$message; $job->{state}=$state if defined $state; _pb_job_write($job);
}
sub _pb_run_install_job {
  my($job)=@_;
  eval {
    _pb_job_update($job,5,'prepare','Baseline-Paketinstallation wird vorbereitet.','running');
    my $url=$job->{repository_url}//'';
    _pb_job_update($job,15,'repository','Internes Baseline Repository wird eingerichtet.');
    $job->{repository}=_pb_ensure_baseline_repo($url);
    _pb_job_update($job,35,'package_check','Meta-Paket client-baseline wird geprueft.');
    my $os=_pkg_read_os(); my $check=_pkg_check($os,'client-baseline');
    if(!$check->{installed}){
      _pb_job_update($job,50,'install','Monit, Grafana Alloy und Go Monit Exporter werden ueber das interne Repository installiert.');
      my $res=_pkg_execute({action=>'install',package=>'client-baseline'}); die ($res->{output}//'Baseline-Paketinstallation fehlgeschlagen') unless $res->{ok}; $job->{package_result}=$res;
    } else {
      _pb_job_update($job,60,'package_present','Meta-Paket ist bereits installiert; Paketinstallation wird uebersprungen.');
    }
    _pb_job_update($job,78,'verify','Installierte Baseline-Pakete werden geprueft.');
    for my $pkg (qw(monit alloy monit-prometheus-exporter client-baseline)){
      my $p=_pkg_check($os,$pkg); die "Baseline-Paket fehlt nach Installation: $pkg" unless $p->{installed};
      $job->{packages}{$pkg}=$p->{version}//'';
    }
    _pb_job_update($job,90,'services','Paket-Units werden neu eingelesen.');
    _pb_run('systemctl','daemon-reload');
    _pb_job_update($job,100,'done','Baseline-Pakete sind installiert. Jetzt Monit- und Alloy-Konfiguration anwenden.','completed');
    1;
  } or do {
    my $e=$@||'Unbekannter Installationsfehler'; $e=~s/[\r\n]+/ /g; $job->{error}=$e; _pb_job_update($job,100,'failed',$e,'failed');
  };
  return $job;
}

sub _pb_identity_file { return '/var/lib/service/config-agent/identity.json'; }
sub _pb_identity {
  my $file=_pb_identity_file();
  my $fallback={host_id=>($ENV{CONFIG_AGENT_HOST_ID}//''),hostname=>'',labels=>{},groups=>[]};
  my($rc,$hn)=_pb_run('hostname','-f'); $hn=~s/[\r\n]+$//; $fallback->{hostname}=$hn if $rc==0;
  $fallback->{host_id}='host-'.substr(Digest::SHA::sha256_hex(lc($fallback->{hostname}||'unknown')),0,16) unless $fallback->{host_id};
  return $fallback unless -f $file && -r $file && !-l $file;
  open my $fh,'<',$file or return $fallback; local $/; my $raw=<$fh>//''; close $fh;
  my $x=eval{decode_json($raw)}; return $fallback unless ref($x) eq 'HASH';
  $x->{labels}={} unless ref($x->{labels}) eq 'HASH'; $x->{groups}=[] unless ref($x->{groups}) eq 'ARRAY';
  $x->{hostname}//=$fallback->{hostname}; $x->{host_id}//=$fallback->{host_id}; return $x;
}

sub _pb_write_identity {
  my($x)=@_; return _pb_identity() unless ref($x) eq 'HASH';
  my $cur=_pb_identity();
  my $host_id=$x->{host_id}//$cur->{host_id}//''; my $hostname=$x->{hostname}//$cur->{hostname}//'';
  die 'host_id ungueltig' unless $host_id =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
  die 'hostname ungueltig' unless $hostname =~ /\A[A-Za-z0-9._:-]{1,255}\z/;
  my %labels; if(ref($x->{labels}) eq 'HASH'){ for my $k(keys %{$x->{labels}}){ next unless $k =~ /\A[A-Za-z0-9._-]{1,64}\z/; my $v="$x->{labels}{$k}"; next if length($v)>128 || $v =~ /[\x00\r\n]/; $labels{$k}=$v; } }
  my @groups; if(ref($x->{groups}) eq 'ARRAY'){ for my $g(@{$x->{groups}}){ $g="$g"; push @groups,$g if $g =~ /\A[A-Za-z0-9._-]{1,64}\z/; } }
  my $file=_pb_identity_file(); make_path(dirname($file),{mode=>0700}) unless -d dirname($file);
  my $raw=Mojo::JSON::encode_json({schema_version=>1,host_id=>$host_id,hostname=>$hostname,labels=>\%labels,groups=>\@groups});
  safe_write_file($file,$raw."\n",1); chmod 0600,$file; return _pb_identity();
}
sub _pb_alloy_labels {
  my($id)=@_; my %l=(host_id=>$id->{host_id}//'',hostname=>$id->{hostname}//'',source=>'alloy',job=>'systemd-journal');
  if(ref($id->{labels}) eq 'HASH'){
    for my $k(sort keys %{$id->{labels}}){
      next unless $k =~ /\A[A-Za-z_][A-Za-z0-9_]{0,62}\z/;
      my $v="$id->{labels}{$k}"; next if length($v)>128; $l{$k}=$v; last if scalar(keys %l)>=20;
    }
  }
  my @p; for my $k(sort keys %l){ my $v=$l{$k}; $v =~ s/([\\"])/\\$1/g; push @p, qq{$k = "$v"}; }
  return '{ '.join(', ',@p).' }';
}
sub _pb_alloy_paths { return ('/etc/alloy/config.alloy','alloy.service'); }
sub _pb_alloy_secret_file { return '/var/lib/service/config-agent/secrets/alloy-observability.env'; }
sub _pb_alloy_current {
  my($path,$unit)=_pb_alloy_paths(); my($loki,$prom)=('','');
  if(-f $path && -r $path && !-l $path){
    open my $fh,'<',$path; local $/; my $txt=<$fh>//''; close $fh;
    $loki=$1 if $txt =~ /loki\.write\s+"central".*?endpoint\s*\{.*?url\s*=\s*"([^"]+)"/s;
    $prom=$1 if $txt =~ /prometheus\.remote_write\s+"central".*?endpoint\s*\{.*?url\s*=\s*"([^"]+)"/s;
  }
  return {path=>$path,loki_url=>$loki,prometheus_remote_write_url=>$prom,secret_file=>_pb_alloy_secret_file(),configured=>(length($loki)||length($prom)?true():false())};
}
sub _pb_write_alloy_secret {
  my($user,$password)=@_; my $file=_pb_alloy_secret_file(); make_path(dirname($file),{mode=>0750}) unless -d dirname($file);
  safe_write_file($file,"OBSERVABILITY_INGEST_USER=$user\nOBSERVABILITY_INGEST_PASSWORD=$password\n",1); chmod 0600,$file;
  return $file;
}
sub _pb_alloy_config {
  my($loki,$prom,$use_auth,$identity)=@_;
  $identity=_pb_identity() unless ref($identity) eq 'HASH';
  my $labels=_pb_alloy_labels($identity);
  for($loki,$prom){ die 'Observability Endpoint ungueltig' if defined($_) && length($_) && $_ !~ m{\Ahttps?://[A-Za-z0-9_.:\-\[\]/]+\z}; }
  my $txt="// Managed by Config Manager generic client baseline\n// Control Plane != Observability Data Plane\nlogging { level = \"info\" }\n\n";
  if($loki){
    my $auth=$use_auth ? qq{\n    basic_auth {\n      username = sys.env("OBSERVABILITY_INGEST_USER")\n      password = sys.env("OBSERVABILITY_INGEST_PASSWORD")\n    }} : q{};
    $txt.=qq{loki.source.journal "system" {\n  forward_to = [loki.write.central.receiver]\n}\n\nloki.write "central" {\n  external_labels = $labels\n  endpoint {\n    url = "$loki"$auth\n  }\n}\n\n};
  }
  if($prom){
    my $auth=$use_auth ? qq{\n    basic_auth {\n      username = sys.env("OBSERVABILITY_INGEST_USER")\n      password = sys.env("OBSERVABILITY_INGEST_PASSWORD")\n    }} : q{};
    $txt.=qq{prometheus.exporter.unix "host" { }\n\nprometheus.scrape "host" {\n  targets = prometheus.exporter.unix.host.targets\n  forward_to = [prometheus.remote_write.central.receiver]\n}\n\nprometheus.scrape "monit" {\n  targets = [{ "__address__" = "127.0.0.1:9108", "job" = "monit" }]\n  forward_to = [prometheus.remote_write.central.receiver]\n}\n\nprometheus.remote_write "central" {\n  external_labels = $labels\n  endpoint {\n    url = "$prom"$auth\n  }\n}\n};
  }
  $txt.="// Workload-specific log sources and exporters belong in Git-managed config fragments.\n";
  return $txt;
}
sub _pb_write_alloy {
  my($cfg,$user,$password)=@_; my($path,$unit)=_pb_alloy_paths(); make_path(dirname($path),{mode=>0755}) unless -d dirname($path);
  safe_write_file($path,$cfg,1); chown 0,0,$path; chmod 0644,$path;
  _pb_write_alloy_secret($user,$password) if defined($user) && length($user) && defined($password) && length($password);
  my $bin=''; $bin='/usr/bin/alloy' if -x '/usr/bin/alloy'; $bin='/usr/local/bin/alloy' if !$bin && -x '/usr/local/bin/alloy';
  if(!$bin){
    return {ok=>true(),path=>$path,unit=>$unit,staged=>true(),message=>'Alloy-Konfiguration vorbereitet. Das Alloy-Paket ist auf diesem Host noch nicht installiert/verfuegbar.'};
  }
  my($rc,$out)=_pb_run($bin,'validate',$path); die "Alloy Configtest fehlgeschlagen: $out" if $rc;
  my($src,$sout)=_pb_run('systemctl','enable','--now',$unit); die "Alloy Start fehlgeschlagen: $sout" if $src;
  _pb_run('systemctl','restart',$unit);
  return {ok=>true(),path=>$path,unit=>$unit,staged=>false()};
}
sub _pb_info {
  # Die Client-Baseline ist bewusst klein: Identitaet/Config-Agent und der
  # lokale Monit-Zugang fuer Server Health. Software-Rollout (Monit-Paket,
  # Alloy, Exporter) gehoert ausschliesslich in Deploy-Profile / Git Deploy.
  # Deshalb werden hier keine Repositorys und keine Alloy-Paketquellen abgefragt.
  my $monit=_pb_package_state('monit',0);
  $monit->{service}=_pb_service('monit.service');
  $monit->{configuration}=_pb_monit_current();
  # Nur informativ: zeigt, ob der via Git Deploy verteilte Exporter bereits da ist.
  $monit->{exporter}=_pb_monit_exporter_info();
  return {
    ok=>true(),
    identity=>_pb_identity(),
    baseline=>{
      config_agent=>{installed=>true(),version=>$VERSION,service=>_pb_service('config-agent.service')},
      monit=>$monit,
    },
    principle=>{
      baseline=>[qw(config-agent monit-access)],
      deployment=>[qw(monit grafana-alloy monit-prometheus-exporter)],
      deploy_profile=>'observability-client',
    }
  };
}

get '/baseline/info' => sub { my $c=shift; my $r=eval{_pb_info()}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>500) if $@; $c->render(json=>$r); };
get '/baseline/job/:id' => sub {
  my $c=shift; my $id=$c->param('id')//''; my $job=eval{_pb_job_read($id)};
  return $c->render(json=>{ok=>false(),error=>($@||'Baseline-Job nicht gefunden')},status=>404) if $@ || !ref($job);
  $c->render(json=>{ok=>true(),job=>$job});
};
post '/baseline/install-job' => sub {
  my $c=shift; my $in=$c->req->json; return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in) eq 'HASH';
  my $component=lc($in->{component}//''); return $c->render(json=>{ok=>false(),error=>'Nur baseline-packages erlaubt'},status=>400) unless $component eq 'baseline-packages';
  my $repo_url=eval{_pb_validate_repo_url($in->{repository_url}//'')}; return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;
  my $id='bl-'.time().'-'.substr(Digest::SHA::sha256_hex(rand().$$.$component.time()),0,12);
  my $job={schema_version=>1,job_id=>$id,component=>$component,repository_url=>$repo_url,state=>'queued',stage=>'queued',stage_message=>'Job angenommen.',progress_percent=>0,created_at=>time()}; _pb_job_write($job);
  Mojo::IOLoop::Subprocess->new->run(sub{ _pb_run_install_job($job); return 1; },sub{ my($sp,$err,$res)=@_; if($err){ my $j=_pb_job_read($id)||$job; $j->{error}="$err"; _pb_job_update($j,100,'failed',"$err",'failed'); } });
  $logger->info("BASELINE_PACKAGE_JOB id=$id "._fmt_req($c)); $c->render(json=>{ok=>true(),job_id=>$id,state=>'queued'},status=>202);
};
post '/baseline/monit-config' => sub {
  my $c=shift; my $in=$c->req->json; return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in) eq 'HASH';
  my $cur=_pb_read_monit_secret(); my $pass=$in->{password}//'';
  if($pass eq '' && $cur->{present}){ open my $fh,'<',$cur->{file}; while(my $line=<$fh>){ $line=~s/[\r\n]+$//; my($k,$v)=split(/=/,$line,2); $pass=$v if defined($v) && $k eq 'MONIT_PASSWORD'; } close $fh; }
  my $user=$in->{username}//($cur->{username}||'monitadmin');
  my $res=eval{_pb_write_monit(_pb_monit_config($in->{bind}//'127.0.0.1',$in->{port}//2812,$user,$pass),$user,$pass)};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $logger->info('BASELINE_MONIT_CONFIG '._fmt_req($c)); $c->render(json=>{%$res,credentials=>{present=>true(),username=>$user,file=>_pb_monit_secret_file()}});
};
post '/baseline/monit-test' => sub {
  my $c=shift; my $data=eval{_monit_fetch_status()};
  if($@ || ref($data) ne 'HASH'){ my $e=$@||'Monit-Test fehlgeschlagen'; $e=~s/[\r\n]+/ /g; return $c->render(json=>{ok=>false(),error=>$e},status=>400); }
  $c->render(json=>{ok=>true(),version=>$data->{server}{version}//'',hostname=>$data->{server}{hostname}//'',summary=>$data->{summary}//{}});
};
post '/baseline/alloy-config' => sub {
  my $c=shift; my $in=$c->req->json; return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in) eq 'HASH';
  my $use_auth=exists($in->{use_agent_auth}) ? ($in->{use_agent_auth}?1:0) : 1;
  my $identity=ref($in->{identity}) eq 'HASH' ? _pb_write_identity($in->{identity}) : _pb_identity(); my($user,$password)=($identity->{host_id}//'config-agent',$api_token//'');
  my $res=eval{_pb_write_alloy(_pb_alloy_config($in->{loki_url}//'', $in->{prometheus_remote_write_url}//'', $use_auth,$identity),$use_auth?$user:'',$use_auth?$password:'')};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@; $logger->info('BASELINE_ALLOY_CONFIG '._fmt_req($c)); $c->render(json=>$res);
};

1;
