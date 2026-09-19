package main;
use strict;
use warnings;
use utf8;
use Mojo::JSON qw(true false);
use Mojo::IOLoop;
use Fcntl qw(:DEFAULT :flock);
use POSIX ();

our $logger;

my $MODSEC_LOCK='/run/teko-config-agent-modsecurity.lock';

sub _ms_os { return _pkg_read_os(); }

sub _ms_profile {
  my $os=_ms_os();
  return {
    os=>$os,
    apache_service=>($os->{manager} eq 'dnf' ? 'httpd.service' : 'apache2.service'),
    config_dir=>'/etc/modsecurity',
    teko_config=>'/etc/modsecurity/teko-modsecurity.conf',
    mode_override=>'/etc/apache2/conf.d/zz-teko-modsecurity-mode.conf',
    custom_rules=>'/etc/modsecurity/teko-custom-rules.conf',
    custom_rules_include=>'/etc/apache2/conf.d/teko-modsecurity-custom.conf',
    exclusions_file=>($os->{manager} eq 'apt' ? '/etc/modsecurity/crs/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf' : ''),
    packages=>(
      $os->{manager} eq 'apt' ? ['libapache2-mod-security2','modsecurity-crs'] :
      $os->{manager} eq 'zypper' ? ['apache2-mod_security2'] :
      ['mod_security','mod_security_crs']
    ),
    audit_log=>($os->{manager} eq 'dnf' ? '/var/log/httpd/modsec_audit.log' : '/var/log/apache2/modsec_audit.log'),
    base_config=>'/etc/modsecurity/modsecurity.conf',
    recommended_config=>'/etc/modsecurity/modsecurity.conf-recommended',
    security2_config=>'/etc/apache2/mods-available/security2.conf',
    security2_enabled=>'/etc/apache2/mods-enabled/security2.load',
    crs_package=>'modsecurity-crs',
    crs_dir=>'/etc/modsecurity/crs',
    crs_apache_include=>'/etc/apache2/conf.d/teko-modsecurity-crs.conf',
    crs_version=>'4.25.1',
    crs_url=>'https://github.com/coreruleset/coreruleset/archive/refs/tags/v4.25.1.tar.gz',
  };
}

sub _ms_with_lock {
  my($code)=@_;
  sysopen(my $fh,$MODSEC_LOCK,O_RDWR|O_CREAT,0600) or die "ModSecurity Lock kann nicht geöffnet werden: $!";
  flock($fh,LOCK_EX) or die "ModSecurity Lock fehlgeschlagen: $!";
  my($ret,$ok,$err);
  $ok=eval{$ret=$code->();1}; $err=$@ unless $ok;
  flock($fh,LOCK_UN); close $fh;
  die $err unless $ok;
  return $ret;
}

sub _ms_run {
  my(@cmd)=@_;
  die "Leeres Kommando" unless @cmd && defined $cmd[0] && length $cmd[0];

  # open LIST captures stdout only. Apache/systemctl write the useful error
  # diagnostics to stderr, which made API errors look like
  # "... fehlgeschlagen:  at ModSecurity.pm line ...".
  # Fork explicitly and merge stderr into stdout without invoking a shell.
  my $pid=open(my $fh,'-|');
  die "Kommando konnte nicht gestartet werden: $cmd[0]: $!" unless defined $pid;
  if($pid==0){
    open STDERR,'>&',STDOUT or do {
      print STDOUT "STDERR-Umleitung fehlgeschlagen: $!\n";
      POSIX::_exit(126);
    };
    { no warnings 'exec'; exec {$cmd[0]} @cmd; }
    print STDERR "exec fehlgeschlagen ($cmd[0]): $!\n";
    POSIX::_exit(127);
  }

  local $/;
  my $out=<$fh>//'';
  close $fh;
  my $status=$?;
  my $rc = $status == -1 ? 127
         : ($status & 127) ? 128 + ($status & 127)
         : ($status >> 8);
  $out =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
  return($rc,substr($out,0,20000));
}



sub _ms_version_ge {
  my($have,$need)=@_;
  my @h=($have//'') =~ /(\d+)\.(\d+)\.(\d+)/;
  my @n=($need//'') =~ /(\d+)\.(\d+)\.(\d+)/;
  return 0 unless @h==3 && @n==3;
  for my $i (0..2){
    return 1 if $h[$i]>$n[$i];
    return 0 if $h[$i]<$n[$i];
  }
  return 1;
}

sub _ms_ensure_suse_modsecurity_compatible {
  my($profile)=@_;
  return unless $profile->{os}{manager} eq 'zypper';
  my $pkg='apache2-mod_security2';
  my $st=_pkg_check($profile->{os},$pkg);
  return if $st->{installed} && _ms_version_ge($st->{version},'2.9.6');

  my $repo='teko-apache-modules';
  my $ver=$profile->{os}{version_id}//'';
  $ver='15.6' unless $ver =~ /^15\.\d+$/;
  my $repo_url="https://download.opensuse.org/repositories/Apache:/Modules/openSUSE_Leap_${ver}/";
  my($lrc,$lout)=_ms_run('/usr/bin/zypper','--non-interactive','lr','-u');
  die "SUSE Repository-Liste nicht lesbar (rc=$lrc): $lout" if $lrc;

  # v2.2.2 could create the TEKO alias with Apache:Modules.repo as BaseURL.
  # Remove only our own alias and recreate it with the actual repository directory.
  if($lout =~ /\b\Q$repo\E\b/){
    my($drc,$dout)=_ms_run('/usr/bin/zypper','--non-interactive','removerepo',$repo);
    die "Defektes TEKO Apache:Modules Repository konnte nicht entfernt werden (rc=$drc): $dout" if $drc;
  }
  my($arc,$aout)=_ms_run('/usr/bin/zypper','--non-interactive','addrepo','--refresh',$repo_url,$repo);
  die "Apache:Modules Repository konnte nicht hinzugefügt werden (rc=$arc): $aout" if $arc;

  my($rrc,$rout)=_ms_run('/usr/bin/zypper','--non-interactive','--gpg-auto-import-keys','refresh',$repo);
  die "Apache:Modules Repository-Refresh fehlgeschlagen (rc=$rrc): $rout" if $rrc;

  my($irc,$iout)=_ms_run('/usr/bin/zypper','--non-interactive','install','--allow-vendor-change','--from',$repo,$pkg);
  die "Kompatibles ModSecurity konnte nicht installiert werden (rc=$irc): $iout" if $irc;
  $st=_pkg_check($profile->{os},$pkg);
  die "ModSecurity $st->{version} ist zu alt für OWASP CRS 4.x (mindestens 2.9.6 erforderlich)"
    unless $st->{installed} && _ms_version_ge($st->{version},'2.9.6');
}

sub _ms_crs_detected {
  my($profile)=@_;
  return true() if -d '/usr/share/modsecurity-crs' || -d '/usr/share/mod_security_crs';
  my $dir=$profile->{crs_dir}//'/etc/modsecurity/crs';
  return (-f "$dir/crs-setup.conf" && -d "$dir/rules") ? true() : false();
}

sub _ms_install_crs_fallback_zypper {
  my($profile)=@_;
  my $pkg=$profile->{crs_package}//'modsecurity-crs';
  my $pkg_before=eval{_pkg_check($profile->{os},$pkg)};
  if(!$@ && $pkg_before->{installed}){
    return {package=>$pkg,source=>'rpm',state=>$pkg_before};
  }

  # First prefer the distribution package when a configured repository offers it.
  # Missing packages on Leap are not fatal: TEKO then installs the pinned OWASP LTS
  # release below.
  my $pkg_result=eval{_pkg_mutate($profile->{os},'install',$pkg,'')};
  if(!$@ && ref($pkg_result) eq 'HASH' && $pkg_result->{ok}){
    return {package=>$pkg,source=>'rpm',state=>_pkg_check($profile->{os},$pkg)};
  }

  my $version=$profile->{crs_version}//'4.25.1';
  my $url=$profile->{crs_url};
  my $dest=$profile->{crs_dir}//'/etc/modsecurity/crs';
  my $marker="$dest/.teko-crs-version";
  if(-f $marker){
    open my $mf,'<',$marker;
    my $have=<$mf>//''; close $mf; chomp $have;
    return {package=>$pkg,source=>'teko-bundled-download',version=>$have,state=>{installed=>true(),version=>$have}}
      if $have eq $version && _ms_crs_detected($profile);
  }

  die "OWASP CRS Fallback benötigt /usr/bin/curl" unless -x '/usr/bin/curl';
  die "OWASP CRS Fallback benötigt /usr/bin/tar" unless -x '/usr/bin/tar';
  die "OWASP CRS Fallback benötigt /usr/bin/cp" unless -x '/usr/bin/cp';
  die "OWASP CRS Download-URL fehlt" unless defined($url) && length($url);

  my $tmpbase="/tmp/teko-crs-$$";
  my $archive="$tmpbase.tar.gz";
  my $extract="$tmpbase.extract";
  mkdir $extract,0755 or die "CRS Temp-Verzeichnis nicht anlegbar: $!";

  my($crc,$cout)=_ms_run('/usr/bin/curl','--fail','--location','--silent','--show-error',
    '--retry','4','--retry-delay','3','--connect-timeout','10','--max-time','180',
    '-o',$archive,$url);
  die "OWASP CRS Download fehlgeschlagen (rc=$crc): $cout" if $crc;

  my($trc,$tout)=_ms_run('/usr/bin/tar','-xzf',$archive,'-C',$extract);
  die "OWASP CRS Entpacken fehlgeschlagen (rc=$trc): $tout" if $trc;

  my $src="$extract/coreruleset-$version";
  die "OWASP CRS Archivstruktur unerwartet: $src fehlt" unless -d $src;
  die "OWASP CRS Setup-Vorlage fehlt" unless -f "$src/crs-setup.conf.example";
  die "OWASP CRS Rules fehlen" unless -d "$src/rules";

  my $parent=$dest; $parent=~s{/[^/]+$}{};
  mkdir $parent,0755 unless -d $parent;
  my $staging="$dest.new.$$";
  my($cprc,$cpout)=_ms_run('/usr/bin/cp','-a',$src,$staging);
  die "OWASP CRS Kopieren fehlgeschlagen (rc=$cprc): $cpout" if $cprc;
  _ms_copy_file_atomic("$staging/crs-setup.conf.example","$staging/crs-setup.conf");
  _ms_atomic_write("$staging/.teko-crs-version","$version\n");

  my $backup='';
  if(-e $dest){
    $backup="$dest.bak.$$";
    rename($dest,$backup) or die "Bestehendes CRS kann nicht gesichert werden: $!";
  }
  rename($staging,$dest) or do {
    my $e=$!;
    rename($backup,$dest) if $backup && -e $backup;
    die "CRS Aktivierung fehlgeschlagen: $e";
  };

  my $include=$profile->{crs_apache_include}//'/etc/apache2/conf.d/teko-modsecurity-crs.conf';
  _ms_atomic_write($include, join("\n",
    '# Managed by TEKO Config Manager',
    '# OWASP Core Rule Set fallback for openSUSE when no modsecurity-crs RPM exists',
    '<IfModule security2_module>',
    '  IncludeOptional /etc/modsecurity/crs/crs-setup.conf',
    '  IncludeOptional /etc/modsecurity/crs/rules/*.conf',
    '</IfModule>',
    ''
  ));

  unlink $archive;
  _ms_run('/usr/bin/rm','-rf',$extract) if -x '/usr/bin/rm';
  _ms_run('/usr/bin/rm','-rf',$backup) if $backup && -e $backup && -x '/usr/bin/rm';
  return {package=>$pkg,source=>'teko-bundled-download',version=>$version,state=>{installed=>true(),version=>$version}};
}

sub _ms_package_state {
  my($profile)=@_;
  my @states;
  for my $p (@{$profile->{packages}}){
    my $st=eval{_pkg_check($profile->{os},$p)};
    $st={installed=>false(),version=>'',error=>"$@"} if $@;
    push @states,{name=>$p,%$st};
  }
  return \@states;
}

sub _ms_ensure_apache_modules {
  my($profile)=@_;
  return unless $profile->{os}{manager} eq 'apt' || $profile->{os}{manager} eq 'zypper';
  die "Apache a2enmod fehlt; benötigte Module können nicht aktiviert werden" unless -x '/usr/sbin/a2enmod';

  # TEKO vhosts need proxy/proxy_http. ModSecurity needs security2.
  # On openSUSE a2enmod updates APACHE_MODULES in /etc/sysconfig/apache2, while
  # /etc/apache2/sysconfig.d/loadmodule.conf is generated at Apache start time.
  # Therefore a configtest immediately after a2enmod can still see the stale
  # generated module list. Enable first, then force one controlled restart on
  # zypper systems so the generated SUSE module configuration is refreshed.
  for my $module (qw(ssl proxy proxy_http headers rewrite unique_id security2)){
    my($rc,$out)=_ms_run('/usr/sbin/a2enmod',$module);
    die "a2enmod $module fehlgeschlagen (rc=$rc): $out" if $rc;
  }

  if($profile->{os}{manager} eq 'zypper'){
    # Existing TEKO proxy vhosts can make SUSE's service pre-start configtest
    # fail with ProxyPreserveHost before the newly enabled proxy modules have
    # been synchronized. Park only TEKO-owned proxy vhosts for the one sync
    # restart; always restore them before returning/throwing.
    my @parked;
    for my $path ('/etc/apache2/vhosts.d/forgejo-teko.conf','/etc/apache2/vhosts.d/grafana-teko.conf'){
      next unless -f $path;
      my $tmp=$path.'.teko-module-sync-disabled';
      unlink $tmp if -e $tmp;
      rename($path,$tmp) or die "TEKO VHost konnte für Apache-Modulsync nicht geparkt werden ($path): $!";
      push @parked,[$tmp,$path];
    }
    my $restore=sub {
      for my $pair (reverse @parked){
        next unless -e $pair->[0];
        rename($pair->[0],$pair->[1]) or die "TEKO VHost konnte nach Apache-Modulsync nicht wiederhergestellt werden ($pair->[1]): $!";
      }
    };

    my($src,$sout)=_ms_apache_control($profile,'restart');
    if($src){
      my($st_rc,$st_out)=_ms_run('/usr/bin/systemctl','status','--no-pager','-l',$profile->{apache_service}//'apache2.service');
      eval{$restore->();1};
      die "Apache Restart zur SUSE-Modulsynchronisation fehlgeschlagen (rc=$src): $sout $st_out";
    }
    $restore->();

    # Verify the *effective* SUSE module set through start_apache2. This
    # frontend imports /etc/sysconfig/apache2, unlike a direct httpd2 call.
    my($mrc,$mout)=_ms_run('/usr/sbin/start_apache2','-M');
    die "Apache Modulliste konnte nach SUSE-Synchronisation nicht gelesen werden (start_apache2 -M, rc=$mrc): $mout" if $mrc;
    my @required=(
      ['proxy_module','ProxyPreserveHost/mod_proxy'],
      ['proxy_http_module','HTTP Reverse Proxy/mod_proxy_http'],
      ['unique_id_module','ModSecurity dependency/mod_unique_id'],
      ['security2_module','ModSecurity/security2'],
    );
    for my $need (@required){
      die "Apache Modul $need->[0] ist trotz a2enmod/Restart nicht geladen ($need->[1]). Effektive SUSE-Module: $mout"
        unless $mout =~ /(?:^|\s)\Q$need->[0]\E(?:\s|$)/m;
    }
  }
}

sub _ms_apache_test {
  my @candidates=(
    # openSUSE/SLES: this is the authoritative frontend because it imports
    # /etc/sysconfig/apache2 (APACHE_MODULES, flags, MPM).
    ['/usr/sbin/start_apache2','-t'],
    ['/usr/sbin/apachectl','configtest'],
    # Non-SUSE fallback only; direct httpd does not import SUSE sysconfig.
    ['/usr/sbin/httpd','-t'],
  );
  for my $c (@candidates){
    next unless -x $c->[0];
    my($rc,$out)=_ms_run(@$c);
    return($rc,$out,$c->[0]);
  }
  return(127,'Kein unterstütztes Apache Configtest-Binary gefunden','');
}

sub _ms_apache_control {
  my($profile,$action)=@_;
  $action//= 'reload';
  die "Ungültige Apache-Aktion" unless $action =~ /\A(?:reload|restart)\z/;
  if(($profile->{os}{manager}//'') eq 'zypper' && -x '/usr/sbin/rcapache2'){
    return _ms_run('/usr/sbin/rcapache2',$action);
  }
  return _ms_run('/usr/bin/systemctl',$action,$profile->{apache_service});
}

sub _ms_render_mode_override {
  my($cfg)=@_;
  return join("\n",
    '# Managed by TEKO Config Manager - effective ModSecurity engine mode',
    '<IfModule security2_module>',
    '    SecRuleEngine '.$cfg->{rule_engine},
    '</IfModule>',
    ''
  );
}

sub _ms_ensure_mode_override {
  my($profile,$cfg)=@_;
  $cfg//=_ms_parse_teko_config($profile->{teko_config});
  my $path=$profile->{mode_override}//'/etc/apache2/conf.d/zz-teko-modsecurity-mode.conf';
  _ms_atomic_write($path,_ms_render_mode_override($cfg));
}

sub _ms_engine_directives {
  my($profile)=@_;
  my @roots=('/etc/apache2','/etc/modsecurity');
  my @rows;
  my %seen;
  require File::Find;
  for my $root (@roots){
    next unless -d $root;
    File::Find::find({wanted=>sub{
      return unless -f $_;
      my $path=$File::Find::name;
      return if $seen{$path}++;
      open my $fh,'<',$path or return;
      my $ln=0;
      while(my $line=<$fh>){
        $ln++;
        if($line =~ /^\s*SecRuleEngine\s+(On|Off|DetectionOnly)\b/i){
          push @rows,{path=>$path,line=>$ln,mode=>$1,teko_override=>($path eq $profile->{mode_override}?true():false())};
        }
      }
      close $fh;
    },no_chdir=>1},$root);
  }
  @rows=sort { $a->{path} cmp $b->{path} || $a->{line}<=>$b->{line} } @rows;
  return \@rows;
}

sub _ms_runtime_state {
  my($profile)=@_;
  my $cfg=_ms_parse_teko_config($profile->{teko_config});
  my $directives=_ms_engine_directives($profile);
  my($override)=grep { $_->{teko_override} } @$directives;
  my $override_mode=$override ? $override->{mode} : '';
  my @other=grep { !$_->{teko_override} } @$directives;
  my $healthy=($override_mode && lc($override_mode) eq lc($cfg->{rule_engine})) ? true() : false();
  return {
    configured_mode=>$cfg->{rule_engine},
    effective_override_mode=>$override_mode,
    mode_override_path=>$profile->{mode_override},
    override_present=>($override?true():false()),
    override_matches=>$healthy,
    engine_directives=>$directives,
    dependencies=>\@other,
  };
}

sub _ms_module_loaded {
  if(-x '/usr/sbin/start_apache2'){
    my($rc,$out)=_ms_run('/usr/sbin/start_apache2','-M');
    return true() if !$rc && $out =~ /security2_module|mod_security/i;
  }
  if(-x '/usr/sbin/a2enmod'){
    my($rc,$out)=_ms_run('/usr/sbin/a2enmod','-l');
    return true() if !$rc && $out =~ /(?:^|\s)security2(?:\s|$)/m;
  }
  my @candidates=(
    ['/usr/sbin/apachectl','-M'],
    ['/usr/sbin/httpd','-M'],
  );
  for my $c (@candidates){
    next unless -x $c->[0];
    my($rc,$out)=_ms_run(@$c);
    next if $rc;
    return true() if $out =~ /security2_module|mod_security/i;
  }
  return false();
}


sub _ms_rule_dirs {
  my($profile)=@_;
  my @dirs;
  for my $d (
    ($profile->{crs_dir}//''),
    '/usr/share/modsecurity-crs',
    '/usr/share/mod_security_crs',
    '/usr/share/modsecurity-crs/rules',
    '/usr/share/mod_security_crs/rules'
  ){
    next unless defined $d && length $d && -d $d;
    push @dirs, $d unless grep { $_ eq $d } @dirs;
  }
  return \@dirs;
}

sub _ms_loaded_rules {
  my($profile)=@_;
  my $cfg=_ms_parse_teko_config($profile->{teko_config});
  my %excluded=map { (0+$_)=>1 } @{$cfg->{excluded_rule_ids}//[]};
  my @files;
  for my $base (@{_ms_rule_dirs($profile)}){
    if(-d "$base/rules") { push @files, glob("$base/rules/*.conf"); }
    push @files, glob("$base/*.conf") if $base =~ m{/rules$};
  }
  my %seen_file; @files=grep { -f $_ && !$seen_file{$_}++ } sort @files;
  my @rules;
  for my $file (@files){
    open my $fh,'<',$file or next;
    my($buf,$start) = ('',0);
    my $ln=0;
    while(my $line=<$fh>){
      $ln++;
      next if $buf eq '' && $line =~ /^\s*#/;
      next if $buf eq '' && $line =~ /^\s*$/;
      $start=$ln if $buf eq '';
      $buf.=$line;
      my $tmp=$line; $tmp =~ s/[\r\n]+$//;
      next if $tmp =~ /\\\s*$/;
      if($buf =~ /^\s*SecRule\b/s && $buf =~ /(?:^|[,\s'\"])id\s*:\s*['\"]?(\d+)/i){
        my $id=0+$1;
        my $msg=''; my $phase=''; my $severity=''; my $tag=''; my $ver='';
        $msg=$1 if $buf =~ /(?:^|[,\s'\"])msg\s*:\s*'([^']*)'/i;
        $msg=$1 if !$msg && $buf =~ /(?:^|[,\s'\"])msg\s*:\s*\"([^\"]*)\"/i;
        $phase=$1 if $buf =~ /(?:^|[,\s'\"])phase\s*:\s*['\"]?(\d+)/i;
        $severity=$1 if $buf =~ /(?:^|[,\s'\"])severity\s*:\s*['\"]?([^,'\"\s]+)/i;
        my @tags;
        while($buf =~ /(?:^|[,\s'\"])tag\s*:\s*'([^']*)'/ig){ push @tags,$1; }
        while($buf =~ /(?:^|[,\s'\"])tag\s*:\s*\"([^\"]*)\"/ig){ push @tags,$1; }
        my %tag_seen; @tags=grep { defined($_) && length($_) && !$tag_seen{$_}++ } @tags;
        $tag=$tags[0]//'';
        $ver=$1 if $buf =~ /(?:^|[,\s'\"])ver\s*:\s*'([^']*)'/i;
        $ver=$1 if !$ver && $buf =~ /(?:^|[,\s'\"])ver\s*:\s*\"([^\"]*)\"/i;
        my $rel=$file; $rel =~ s{^/etc/modsecurity/crs/}{};
        my($family,$summary,$kind)=('','','CRS-Regel');
        if($rel =~ m{(?:^|/)REQUEST-949-BLOCKING-EVALUATION\.conf}i){
          $family='REQUEST-949'; $kind='CRS intern';
          $summary='Request Blocking Evaluation / Anomaly-Score-Auswertung';
        } elsif($rel =~ m{(?:^|/)RESPONSE-959-BLOCKING-EVALUATION\.conf}i){
          $family='RESPONSE-959'; $kind='CRS intern';
          $summary='Response Blocking Evaluation / Anomaly-Score-Auswertung';
        } elsif($rel =~ m{(?:^|/)(REQUEST|RESPONSE)-(\d+)-([^/]+?)\.conf}i){
          $family=uc($1).'-'.$2;
          my $n=$3; $n =~ s/-/ /g; $n =~ s/\b(\w)/uc($1)/eg;
          $summary=$family.' – '.$n;
        }
        $summary=$msg if length $msg;
        $summary='CRS-Regel ohne eigene msg-Aktion; Details/Originalregel prüfen' unless length $summary;
        my $raw=$buf; $raw =~ s/\s+\z//;
        push @rules,{
          id=>$id, active=>($excluded{$id}?false():true()), phase=>$phase,
          severity=>$severity, tag=>$tag, tags=>\@tags, msg=>$msg,
          summary=>$summary, kind=>$kind, family=>$family, ver=>$ver,
          file=>$rel, line=>$start, raw=>$raw
        };
      }
      $buf=''; $start=0;
    }
    close $fh;
  }
  my %seen; @rules=grep { !$seen{$_->{id}}++ } sort { $a->{id}<=>$b->{id} } @rules;
  return \@rules;
}

sub _ms_read_custom_rules {
  my($profile)=@_;
  my $path=$profile->{custom_rules};
  return '' unless -f $path;
  open my $fh,'<',$path or die "Custom-Rules nicht lesbar: $!";
  local $/; my $raw=<$fh>//''; close $fh;
  return $raw;
}

sub _ms_validate_custom_rules {
  my($raw)=@_;
  $raw='' unless defined $raw;
  die "Custom-Rules zu gross (maximal 128 KiB)" if length($raw)>131072;
  die "NUL-Byte in Custom-Rules ist nicht erlaubt" if $raw =~ /\x00/;
  # Keep this file in ModSecurity directive scope. Apache include/module/vhost
  # directives belong to the managed Apache configuration, not this editor.
  for my $line (split /\n/,$raw){
    next if $line =~ /^\s*(?:#.*)?$/;
    next if $line =~ /^\s*(?:SecRule|SecAction|SecMarker|SecRuleRemoveById|SecRuleRemoveByTag|SecRuleRemoveByMsg|SecRuleUpdateActionById|SecRuleUpdateTargetById|SecRuleUpdateTargetByTag|SecComponentSignature)\b/i;
    next if $line =~ /^\s*(?:["']|\\)/; # continuation of a multi-line SecRule
    die "Nicht erlaubte Direktive in Custom-Rules: $line";
  }
  return $raw;
}

sub _ms_save_custom_rules {
  my($raw)=@_;
  my $profile=_ms_profile();
  $raw=_ms_validate_custom_rules($raw);
  return _ms_with_lock(sub{
    my $path=$profile->{custom_rules};
    my $old=_ms_snapshot_file($path);
    my $content="# Managed by TEKO Config Manager - Custom ModSecurity rules\n".$raw;
    $content.="\n" unless $content =~ /\n\z/;
    _ms_atomic_write($path,$content);
    my($rc,$out,$tool)=_ms_apache_test();
    if($rc){ _ms_restore_snapshot($old); die "Apache Configtest fehlgeschlagen; Custom-Rules zurückgerollt: $out"; }
    my($rrc,$rout)=_ms_apache_control($profile,'reload');
    if($rrc){
      _ms_restore_snapshot($old);
      my($trc)=_ms_apache_test();
      _ms_apache_control($profile,'reload') if $trc==0;
      die "Apache Reload fehlgeschlagen; Custom-Rules zurückgerollt (rc=$rrc): $rout";
    }
    return {ok=>true(),path=>$path,configtest=>$tool};
  });
}

sub _ms_defaults {
  return {
    rule_engine=>'DetectionOnly',
    request_body_access=>true(),
    response_body_access=>false(),
    request_body_limit=>134217728,
    audit_engine=>'RelevantOnly',
    excluded_rule_ids=>[],
  };
}

sub _ms_validate_config {
  my($in)=@_;
  die "JSON-Objekt erforderlich" unless ref($in) eq 'HASH';
  my $engine=$in->{rule_engine}//'DetectionOnly';
  die "Ungültiger Rule Engine Modus" unless $engine =~ /\A(?:On|Off|DetectionOnly)\z/;
  my $audit=$in->{audit_engine}//'RelevantOnly';
  die "Ungültiger Audit Engine Modus" unless $audit =~ /\A(?:On|Off|RelevantOnly)\z/;
  my $limit=$in->{request_body_limit}//134217728;
  die "Ungültiges Request Body Limit" unless "$limit" =~ /\A\d+\z/ && $limit>=1048576 && $limit<=1073741824;
  my @ids; my %seen;
  my $raw=$in->{excluded_rule_ids}//[];
  $raw=[split(/[\s,]+/,$raw)] unless ref($raw) eq 'ARRAY';
  die "excluded_rule_ids muss Array sein" unless ref($raw) eq 'ARRAY';
  for my $id (@$raw){
    next unless defined $id && length "$id";
    die "Ungültige Rule-ID" unless "$id" =~ /\A[1-9][0-9]{0,8}\z/;
    next if $seen{$id}++;
    push @ids,0+$id;
  }
  die "Maximal 200 Rule-Ausnahmen" if @ids>200;
  return {
    rule_engine=>$engine,
    request_body_access=>($in->{request_body_access}?true():false()),
    response_body_access=>($in->{response_body_access}?true():false()),
    request_body_limit=>0+$limit,
    audit_engine=>$audit,
    excluded_rule_ids=>\@ids,
  };
}

sub _ms_render_config {
  my($cfg,$profile)=@_;
  my @l=(
    '# Managed by TEKO Config Manager - do not edit manually',
    'SecRuleEngine '.$cfg->{rule_engine},
    'SecRequestBodyAccess '.($cfg->{request_body_access}?'On':'Off'),
    'SecResponseBodyAccess '.($cfg->{response_body_access}?'On':'Off'),
    'SecRequestBodyLimit '.$cfg->{request_body_limit},
    'SecAuditEngine '.$cfg->{audit_engine},
    'SecAuditLog '.$profile->{audit_log},
  );
  push @l,'SecRuleRemoveById '.join(' ',@{$cfg->{excluded_rule_ids}})
    if $profile->{os}{manager} ne 'apt' && @{$cfg->{excluded_rule_ids}};
  return join("\n",@l)."\n";
}

sub _ms_parse_teko_config {
  my($path)=@_;
  my $cfg=_ms_defaults();
  return $cfg unless -f $path;
  open my $fh,'<',$path or die "ModSecurity TEKO-Konfiguration nicht lesbar: $!";
  while(<$fh>){
    chomp;
    $cfg->{rule_engine}=$1 if /^\s*SecRuleEngine\s+(On|Off|DetectionOnly)\s*$/i;
    $cfg->{request_body_access}=($1 eq 'On'?true():false()) if /^\s*SecRequestBodyAccess\s+(On|Off)\s*$/i;
    $cfg->{response_body_access}=($1 eq 'On'?true():false()) if /^\s*SecResponseBodyAccess\s+(On|Off)\s*$/i;
    $cfg->{request_body_limit}=0+$1 if /^\s*SecRequestBodyLimit\s+(\d+)\s*$/;
    $cfg->{audit_engine}=$1 if /^\s*SecAuditEngine\s+(On|Off|RelevantOnly)\s*$/i;
    if(/^\s*SecRuleRemoveById\s+(.+?)\s*$/){
      my @ids=grep{/^\d+$/}split(/\s+/,$1);
      $cfg->{excluded_rule_ids}=[map{0+$_}@ids];
    }
  }
  close $fh;
  my $profile=_ms_profile();
  if($profile->{os}{manager} eq 'apt' && -f $profile->{exclusions_file}){
    open my $ef,'<',$profile->{exclusions_file} or die "CRS-Ausnahmedatei nicht lesbar: $!";
    local $/; my $eraw=<$ef>; close $ef;
    if($eraw =~ /# BEGIN TEKO MANAGED RULE EXCLUSIONS\s*\n(.*?)# END TEKO MANAGED RULE EXCLUSIONS/s){
      my $block=$1;
      if($block =~ /SecRuleRemoveById\s+([^\r\n]+)/){
        my @ids=grep{/^\d+$/}split(/\s+/,$1);
        $cfg->{excluded_rule_ids}=[map{0+$_}@ids];
      }
    }
  }
  return _ms_validate_config($cfg);
}

sub _ms_atomic_write {
  my($path,$content)=@_;
  my $dir=$path; $dir=~s{/[^/]+$}{};
  mkdir $dir,0755 unless -d $dir;
  my $tmp="$path.tmp.$$";
  open my $fh,'>',$tmp or die "Temporäre ModSecurity-Konfiguration nicht schreibbar: $!";
  print {$fh} $content or die "Schreiben fehlgeschlagen: $!";
  close $fh or die "Close fehlgeschlagen: $!";
  chmod 0644,$tmp or die "chmod fehlgeschlagen: $!";
  rename $tmp,$path or die "Atomarer Rename fehlgeschlagen: $!";
}


sub _ms_update_debian_exclusions {
  my($profile,$ids)=@_;
  return unless $profile->{os}{manager} eq 'apt';
  my $path=$profile->{exclusions_file};
  my $dir=$path; $dir=~s{/[^/]+$}{};
  mkdir $dir,0755 unless -d $dir;
  my $raw='';
  if(-f $path){
    open my $fh,'<',$path or die "CRS-Ausnahmedatei nicht lesbar: $!";
    local $/; $raw=<$fh>//''; close $fh;
  }
  $raw =~ s/\n?# BEGIN TEKO MANAGED RULE EXCLUSIONS.*?# END TEKO MANAGED RULE EXCLUSIONS\n?/\n/sg;
  $raw =~ s/\s+\z/\n/ if length $raw;
  if(@$ids){
    $raw .= "\n# BEGIN TEKO MANAGED RULE EXCLUSIONS\n";
    $raw .= "# Managed by TEKO; existing non-TEKO exclusions are preserved.\n";
    $raw .= "SecRuleRemoveById ".join(' ',@$ids)."\n";
    $raw .= "# END TEKO MANAGED RULE EXCLUSIONS\n";
  }
  _ms_atomic_write($path,$raw);
}

sub _ms_copy_file_atomic {
  my($src,$dst)=@_;
  open my $in,'<',$src or die "Quelle nicht lesbar ($src): $!";
  local $/; my $data=<$in>; close $in;
  _ms_atomic_write($dst,$data);
}

sub _ms_prepare_debian_layout {
  my($profile)=@_;
  return unless $profile->{os}{manager} eq 'apt';

  my $recommended=$profile->{recommended_config}//'/etc/modsecurity/modsecurity.conf-recommended';
  my $active=$profile->{base_config}//'/etc/modsecurity/modsecurity.conf';
  if(!-f $active){
    die "Debian ModSecurity Basisdatei fehlt: $recommended" unless -f $recommended;
    _ms_copy_file_atomic($recommended,$active);
  }

  my $security2=$profile->{security2_config}//'/etc/apache2/mods-available/security2.conf';
  if(-f $security2){
    open my $fh,'<',$security2 or die "security2.conf nicht lesbar: $!";
    local $/; my $raw=<$fh>; close $fh;
    if($raw !~ m{IncludeOptional\s+/etc/modsecurity/\*\.conf}){
      my $updated=$raw;
      $updated .= "\n# TEKO: lokale ModSecurity-Konfigurationen\nIncludeOptional /etc/modsecurity/*.conf\n";
      _ms_atomic_write($security2,$updated);
    }
  }
}


sub _ms_snapshot_file {
  my($path)=@_;
  return {path=>$path,existed=>0,data=>undef,mode=>undef} unless defined($path) && length($path) && -f $path;
  open my $fh,'<',$path or die "Snapshot nicht lesbar ($path): $!";
  local $/; my $data=<$fh>; close $fh;
  my @st=stat($path);
  return {path=>$path,existed=>1,data=>$data,mode=>($st[2]&07777)};
}

sub _ms_restore_snapshot {
  my($snap)=@_;
  return unless ref($snap) eq 'HASH' && defined($snap->{path}) && length($snap->{path});
  if($snap->{existed}){
    _ms_atomic_write($snap->{path},$snap->{data}//'');
    chmod($snap->{mode},$snap->{path}) if defined $snap->{mode};
  } else {
    unlink($snap->{path}) if -e $snap->{path} || -l $snap->{path};
  }
}


sub _ms_ensure_custom_rules_include {
  my($profile)=@_;
  my $include=$profile->{custom_rules_include}//'/etc/apache2/conf.d/teko-modsecurity-custom.conf';
  _ms_atomic_write($include, join("\n",
    '# Managed by TEKO Config Manager',
    '<IfModule security2_module>',
    '  IncludeOptional /etc/modsecurity/teko-custom-rules.conf',
    '</IfModule>',
    ''
  ));
}

sub _ms_save_config {
  my($in)=@_;
  my $profile=_ms_profile();
  my $cfg=_ms_validate_config($in);
  my $path=$profile->{teko_config};
  my $pkgstate=_ms_package_state($profile);
  die "ModSecurity Apache-Modul ist nicht installiert" unless @$pkgstate && $pkgstate->[0]{installed};
  return _ms_with_lock(sub{
    my $old=(-f $path) ? do { open my $f,'<',$path or die $!; local $/; <$f> } : undef;
    my $modesnap=_ms_snapshot_file($profile->{mode_override});
    my $epath=$profile->{exclusions_file}//'';
    my $eold=($epath && -f $epath) ? do { open my $f,'<',$epath or die $!; local $/; <$f> } : undef;
    my $eexisted=($epath && -f $epath)?1:0;
    _ms_atomic_write($path,_ms_render_config($cfg,$profile));
    _ms_ensure_mode_override($profile,$cfg);
    _ms_update_debian_exclusions($profile,$cfg->{excluded_rule_ids});
    my($rc,$out,$tool)=_ms_apache_test();
    if($rc!=0){
      defined($old) ? _ms_atomic_write($path,$old) : unlink($path);
      _ms_restore_snapshot($modesnap);
      if($epath){ $eexisted ? _ms_atomic_write($epath,$eold) : unlink($epath); }
      die "Apache Configtest fehlgeschlagen; Änderung zurückgerollt: $out";
    }
    my($rrc,$rout)=_ms_apache_control($profile,'reload');
    if($rrc!=0){
      defined($old) ? _ms_atomic_write($path,$old) : unlink($path);
      _ms_restore_snapshot($modesnap);
      if($epath){ $eexisted ? _ms_atomic_write($epath,$eold) : unlink($epath); }
      my($trc)=_ms_apache_test();
      _ms_apache_control($profile,'reload') if $trc==0;
      die "Apache Reload fehlgeschlagen (rc=$rrc); Änderung zurückgerollt: $rout";
    }
    return {ok=>true(),config=>$cfg,configtest=>$tool,reloaded=>$profile->{apache_service}};
  });
}

sub _ms_install {
  my $profile=_ms_profile();
  return _ms_with_lock(sub{
    my @result;
    my @snapshots;
    my $module_was_enabled=0;
    if($profile->{os}{manager} eq 'zypper'){
      push @snapshots,_ms_snapshot_file($profile->{crs_apache_include});
    }
    push @snapshots,_ms_snapshot_file($profile->{custom_rules_include}//'/etc/apache2/conf.d/teko-modsecurity-custom.conf');
    push @snapshots,_ms_snapshot_file($profile->{mode_override}//'/etc/apache2/conf.d/zz-teko-modsecurity-mode.conf');
    if($profile->{os}{manager} eq 'apt'){
      push @snapshots,_ms_snapshot_file($profile->{base_config});
      push @snapshots,_ms_snapshot_file($profile->{security2_config});
    }
    if($profile->{os}{manager} eq 'apt' || $profile->{os}{manager} eq 'zypper'){
      $module_was_enabled=_ms_module_loaded()?1:0;
    }

    for my $p (@{$profile->{packages}}){
      my $before=_pkg_check($profile->{os},$p);
      if(!$before->{installed}){
        my $r=_pkg_mutate($profile->{os},'install',$p,'');
        die "Installation von $p fehlgeschlagen: ".($r->{output}//'') unless $r->{ok};
      }
      push @result,{package=>$p,state=>_pkg_check($profile->{os},$p)};
    }

    if($profile->{os}{manager} eq 'zypper'){
      _ms_ensure_suse_modsecurity_compatible($profile);
      # Refresh reported module state after a possible Apache:Modules upgrade.
      $result[0]{state}=_pkg_check($profile->{os},'apache2-mod_security2') if @result;
      push @result,_ms_install_crs_fallback_zypper($profile);
    }

    # Paketinstallation und heruntergeladene CRS-Dateien bleiben bei Fehlern bewusst
    # bestehen. Apache-Includes und Debian-Basisdateien werden dagegen bei einem
    # Configtest-/Reload-Fehler auf ihren vorherigen Stand restauriert.

    my($tool,$failure);
    my $ok=eval{
      _ms_prepare_debian_layout($profile);
      _ms_ensure_custom_rules_include($profile);
      _ms_ensure_mode_override($profile,_ms_parse_teko_config($profile->{teko_config}));
      _ms_ensure_apache_modules($profile);
      my($tc,$to,$t)=_ms_apache_test(); $tool=$t;
      die "Apache Configtest nach Installation fehlgeschlagen (rc=$tc): $to" if $tc;
      die "Apache ModSecurity-Modul security2_module ist nach a2enmod nicht geladen" unless _ms_module_loaded();
      my($rc,$out)=_ms_apache_control($profile,'reload');
      die "Apache Reload nach Installation fehlgeschlagen (rc=$rc): $out" if $rc;
      1;
    };
    $failure=$@ unless $ok;

    if(!$ok){
      my @rollback_errors;
      for my $snap (reverse @snapshots){
        eval{_ms_restore_snapshot($snap);1} or push @rollback_errors,"Datei-Rollback $snap->{path}: $@";
      }
      if(($profile->{os}{manager} eq 'apt' || $profile->{os}{manager} eq 'zypper') && !$module_was_enabled && -x '/usr/sbin/a2dismod'){
        my($drc,$dout)=_ms_run('/usr/sbin/a2dismod','security2');
        push @rollback_errors,"a2dismod security2 rc=$drc: $dout" if $drc;
      }
      my($rtc,$rto)=_ms_apache_test();
      if($rtc==0){
        my($rrc,$rout)=_ms_apache_control($profile,'reload');
        push @rollback_errors,"Rollback-Reload rc=$rrc: $rout" if $rrc;
      } else {
        push @rollback_errors,"Rollback-Configtest rc=$rtc: $rto";
      }
      $failure =~ s/\s+\z//;
      $failure .= "; Rollback-Probleme: ".join(' | ',@rollback_errors) if @rollback_errors;
      die "$failure\n";
    }

    return {ok=>true(),packages=>\@result,configtest=>$tool};
  });
}

get '/modsecurity/info' => sub {
  my $c=shift;
  my $profile=eval{_ms_profile()};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>501) if $@;
  my $packages=_ms_package_state($profile);
  $c->render(json=>{
    ok=>true(), os=>$profile->{os}, packages=>$packages,
    installed=>(@$packages && $packages->[0]{installed}?true():false()),
    module_loaded=>_ms_module_loaded(), config_file=>$profile->{teko_config},
    crs_detected=>_ms_crs_detected($profile),
    runtime=>_ms_runtime_state($profile),
  });
};

get '/modsecurity/config' => sub {
  my $c=shift;
  my $profile=eval{_ms_profile()};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>501) if $@;
  my $cfg=eval{_ms_parse_teko_config($profile->{teko_config})};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>500) if $@;
  $c->render(json=>{ok=>true(),config=>$cfg,path=>$profile->{teko_config}});
};

post '/modsecurity/install' => sub {
  my $c=shift; $c->render_later;
  my $sp=Mojo::IOLoop::Subprocess->new;
  $sp->run(sub{_ms_install()},sub{
    my($sub,$err,$res)=@_;
    if($err){my $m="$err";$m=~s/[\r\n]+/ /g;return $c->render(json=>{ok=>false(),error=>$m},status=>500);}
    $logger->info("MODSECURITY install "._fmt_req($c));
    $c->render(json=>$res);
  });
};

post '/modsecurity/config' => sub {
  my $c=shift; my $in=$c->req->json;
  return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in) eq 'HASH';
  $c->render_later;
  my $sp=Mojo::IOLoop::Subprocess->new;
  $sp->run(sub{_ms_save_config($in)},sub{
    my($sub,$err,$res)=@_;
    if($err){my $m="$err";$m=~s/[\r\n]+/ /g;return $c->render(json=>{ok=>false(),error=>$m},status=>400);}
    $logger->info("MODSECURITY config-save "._fmt_req($c));
    $c->render(json=>$res);
  });
};


get '/modsecurity/rules' => sub {
  my $c=shift;
  my $profile=eval{_ms_profile()};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>501) if $@;
  my $rules=eval{_ms_loaded_rules($profile)};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>500) if $@;
  $c->render(json=>{ok=>true(),rules=>$rules,count=>scalar(@$rules)});
};

get '/modsecurity/custom-rules' => sub {
  my $c=shift;
  my $profile=eval{_ms_profile()};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>501) if $@;
  my $raw=eval{_ms_read_custom_rules($profile)};
  return $c->render(json=>{ok=>false(),error=>"$@"},status=>500) if $@;
  $raw =~ s/^# Managed by TEKO Config Manager - Custom ModSecurity rules\n//;
  $c->render(json=>{ok=>true(),content=>$raw,path=>$profile->{custom_rules}});
};

post '/modsecurity/custom-rules' => sub {
  my $c=shift; my $in=$c->req->json;
  return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in) eq 'HASH';
  my $content=defined($in->{content}) ? "$in->{content}" : '';
  $c->render_later;
  my $sp=Mojo::IOLoop::Subprocess->new;
  $sp->run(sub{_ms_save_custom_rules($content)},sub{
    my($sub,$err,$res)=@_;
    if($err){my $m="$err";$m=~s/[\r\n]+/ /g;return $c->render(json=>{ok=>false(),error=>$m},status=>400);}
    $logger->info("MODSECURITY custom-rules-save "._fmt_req($c));
    $c->render(json=>$res);
  });
};

1;
