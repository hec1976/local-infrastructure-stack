package main;
use strict;
use warnings;
use utf8;

# Mojolicious::Lite wird absichtlich nur in config-agent.pl geladen.
# Dieses Modul laeuft in package main und registriert seine Routen
# in derselben bereits initialisierten Lite-App.
use Mojo::JSON qw(true);
use Mojo::File qw(path);
use Mojo::IOLoop::Subprocess;
use Text::ParseWords qw(shellwords);
use Time::HiRes qw(time);
use POSIX ();
use Errno qw(EINTR);

our (
  $VERSION, $SYSTEMCTL, $SYSTEMCTL_FLAGS,
  $Bin, $globalfile, $managed_configs_file, $legacy_configs_file,
  $configsfile, $using_legacy_configs, $gitfile,
  $global, $configs, $logger, $log_level,
  $api_token, $allowed_ips, $tmpDir, $backupRoot, $maxBackups,
  $lockTimeoutS, $configs_lockfile, $path_guard, $ALLOWED,
  $apply_meta_enabled, $auto_create_backup_subdirs, $fsync_dir_enabled,
  $managed_configs_valid, $managed_configs_error,
  $git_cfg, $git_settings_cfg, $git_profiles_cfg,
  $git_deploy_enabled, $git_allow_direct_request,
  $git_require_api_token, $git_require_ip_acl,
  $git_require_guard_enforce, $git_require_allowed_ref,
  $git_allow_proxy_env, $git_bin, $tar_bin, $mv_bin,
  $git_state_dir, $git_cache_root, $git_status_root, $git_home_dir,
  $git_timeout, $git_default_keep_releases, $git_default_max_files,
  $git_default_max_bytes, $git_default_deploy_user,
  $git_default_auth_scheme, $git_default_ca_info,
  $git_allowed_hosts, $git_profiles_raw, $git_path_guard, $GIT_ALLOWED,
  $git_config_generation, $git_config_digest, $git_settings_digest,
  $git_profiles_digest, $git_config_valid, $git_config_error,
  $git_settings_error, $git_profiles_error, $git_config_exists,
  $git_config_backup_dir, $git_settings_backup_dir
);
our (%cfgmap);

# Security helper for configured service units and script runners.
sub _action_validate_service_name {
  my ($svc) = @_;
  return 0 unless defined $svc && !ref($svc) && length($svc) <= 255;
  return 0 unless $svc =~ /^[A-Za-z0-9_.\@:-]+$/;
  my $base = lc($svc);
  $base =~ s/\.service$//;
  my %deny = map { $_ => 1 } qw(
    poweroff reboot halt kexec rescue emergency default graphical multi-user
    shutdown systemd-poweroff systemd-reboot systemd-halt systemd-kexec
  );
  return $deny{$base} ? 0 : 1;
}

sub _action_script_roots {
  my $raw = ref($global->{action_script_roots}) eq 'ARRAY'
    ? $global->{action_script_roots} : ['/opt/service_script'];
  my @roots;
  for my $root (@$raw) {
    next unless defined $root && !ref($root) && $root =~ m{^/};
    my $rr = eval { path($root)->realpath->to_string };
    next unless defined $rr && -d $rr;
    $rr =~ s{/+$}{} unless $rr eq '/';
    push @roots, $rr;
  }
  return \@roots;
}

sub _action_validate_script {
  my ($runner, $script) = @_;
  return (0, 'Script-Pfad muss absolut sein') unless defined($script) && $script =~ m{^/};
  return (0, 'Script-Symlinks sind verboten') if -l $script;
  return (0, "Script nicht gefunden: $script") unless -f $script;
  my $real = eval { path($script)->realpath->to_string };
  return (0, 'Script-Pfad konnte nicht kanonisiert werden') unless defined $real;

  # /usr/bin/systemctl ist fuer den expliziten exec:-Sonderfall zugelassen.
  if ($runner eq 'exec' && $real eq $SYSTEMCTL) {
    return (1, $real);
  }

  my $roots = _action_script_roots();
  return (0, 'Keine gueltigen action_script_roots konfiguriert') unless @$roots;
  my $inside = 0;
  for my $root (@$roots) {
    if ($real eq $root || index($real, "$root/") == 0) { $inside = 1; last; }
  }
  return (0, "Script liegt ausserhalb action_script_roots: $real") unless $inside;

  my @st = stat($real);
  return (0, 'Script konnte nicht stat() geprueft werden') unless @st;
  return (0, 'Script muss root gehoeren') unless $st[4] == 0;
  return (0, 'Script darf nicht gruppen-/welt-schreibbar sein') if ($st[2] & 0022);
  return (0, 'Script hat mehrere Hardlinks und wird verweigert') if defined($st[3]) && $st[3] > 1;
  return (1, $real);
}

# Fuehrt einen externen Befehl in einem separaten Prozess aus und erfasst
# stdout/stderr ohne IPC::Open3. Diese Funktion wird innerhalb eines
# Mojo::IOLoop::Subprocess-Kindprozesses aufgerufen, sodass der Mojolicious-
# Event-Loop im Webprozess nicht blockiert wird.
sub _run_argv_capture {
  my ($argv, $cwd, $timeout, $env_delta, $capture_limit) = @_;
  die "argv fehlt" unless ref($argv) eq 'ARRAY' && @$argv;
  die "env_delta muss ein HASH sein" if defined($env_delta) && ref($env_delta) ne 'HASH';
  $capture_limit = MAX_SCRIPT_OUTPUT
    unless defined($capture_limit) && $capture_limit =~ /^\d+$/ && $capture_limit >= 1024;

  pipe(my $out_r, my $out_w) or die "pipe(stdout) fehlgeschlagen: $!";
  pipe(my $err_r, my $err_w) or die "pipe(stderr) fehlgeschlagen: $!";

  my $pid = fork();
  die "fork fehlgeschlagen: $!" unless defined $pid;

  if ($pid == 0) {
    close $out_r;
    close $err_r;

    open STDOUT, '>&', $out_w or POSIX::_exit(126);
    open STDERR, '>&', $err_w or POSIX::_exit(126);
    close $out_w;
    close $err_w;

    # Eigene Session/Prozessgruppe: Timeout kann den gesamten Prozessbaum
    # derselben Gruppe beenden. Ein Fehlschlag ist nicht fatal; der direkte
    # Prozess wird im Timeout-Fall zusaetzlich immer einzeln beendet.
    eval { POSIX::setsid() };

    # Nur im Kindprozess anwenden. Ein undef-Wert entfernt die Variable.
    # Dadurch bleiben Token und Git-Härtungsvariablen vollständig aus dem
    # langlebigen Webprozess heraus.
    if (ref($env_delta) eq 'HASH') {
      for my $key (keys %$env_delta) {
        next unless defined $key && $key =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
        if (defined $env_delta->{$key}) {
          $ENV{$key} = $env_delta->{$key};
        } else {
          delete $ENV{$key};
        }
      }
    }

    if (defined $cwd && length $cwd) {
      unless (chdir $cwd) {
        print STDERR "chdir fehlgeschlagen: $!\n";
        POSIX::_exit(126);
      }
    }

    {
      no warnings 'exec'; # Code nach exec ist bewusst der Fallback fuer den
                          # Fall dass exec selbst nicht mal starten konnte
                          # (z.B. Binary fehlt/nicht ausfuehrbar); Perl kann
                          # das statisch nicht von totem Code unterscheiden
                          # und würde sonst bei jedem Start eine Warnung ins
                          # Log schreiben, obwohl kein Fehler vorliegt.
      exec @$argv;
      print STDERR "exec fehlgeschlagen: $!\n";
      POSIX::_exit(127);
    }
  }

  close $out_w;
  close $err_w;

  my ($buf_out, $buf_err) = ('', '');
  my ($bytes_out_total, $bytes_err_total) = (0, 0);
  my ($timed_out, $status, $error) = (0, undef, undef);

  my $ok = eval {
    local $SIG{ALRM} = sub { die bless({}, 'ScriptTimeout') };
    alarm $timeout;

    my %done = (out => 0, err => 0);
    while (!$done{out} || !$done{err}) {
      my $rin = '';
      vec($rin, fileno($out_r), 1) = 1 unless $done{out};
      vec($rin, fileno($err_r), 1) = 1 unless $done{err};

      my $n = select($rin, undef, undef, 1);
      next if $n == 0;
      if ($n < 0) {
        next if $!{EINTR};
        die "select fehlgeschlagen: $!";
      }

      my $tmp = '';
      unless ($done{out}) {
        if (vec($rin, fileno($out_r), 1)) {
          my $r = sysread($out_r, $tmp, 8192);
          if (!defined $r) {
            next if $!{EINTR};
            die "sysread(stdout) fehlgeschlagen: $!";
          } elsif ($r == 0) {
            $done{out} = 1;
          } else {
            $bytes_out_total += $r;
            my $remaining = $capture_limit - length($buf_out);
            $buf_out .= substr($tmp, 0, $remaining) if $remaining > 0;
          }
        }
      }

      $tmp = '';
      unless ($done{err}) {
        if (vec($rin, fileno($err_r), 1)) {
          my $r = sysread($err_r, $tmp, 8192);
          if (!defined $r) {
            next if $!{EINTR};
            die "sysread(stderr) fehlgeschlagen: $!";
          } elsif ($r == 0) {
            $done{err} = 1;
          } else {
            $bytes_err_total += $r;
            my $remaining = $capture_limit - length($buf_err);
            $buf_err .= substr($tmp, 0, $remaining) if $remaining > 0;
          }
        }
      }
    }

    waitpid($pid, 0);
    $status = $?;
    alarm 0;
    1;
  };

  unless ($ok) {
    my $exc = $@;
    $timed_out = ref($exc) eq 'ScriptTimeout' ? 1 : 0;
    $error = $timed_out ? 'timeout' : (ref($exc) ? "$exc" : ($exc // 'unbekannter Fehler'));
    kill 9, -$pid;
    kill 9,  $pid;
    waitpid($pid, 0);
    $status = $?;
    alarm 0;
  }

  close $out_r;
  close $err_r;

  my $rc = defined($status) ? ($status >> 8) : 255;
  return {
    ok              => $ok ? 1 : 0,
    timeout         => $timed_out,
    error           => $error,
    rc              => $rc,
    stdout          => ($bytes_out_total > $capture_limit ? $buf_out . '...[truncated]' : $buf_out),
    stderr          => ($bytes_err_total > $capture_limit ? $buf_err . '...[truncated]' : $buf_err),
    bytes_out_total => $bytes_out_total,
    bytes_err_total => $bytes_err_total,
  };
}



sub _capture_simple {
  my (@argv) = @_;
  my $pid = open(my $fh, '-|');
  return (255, '') unless defined $pid;
  if ($pid == 0) {
    open STDERR, '>&', STDOUT;
    exec @argv;
    exit 127;
  }
  local $/;
  my $out = <$fh> // '';
  close $fh;
  my $rc = $? >> 8;
  return ($rc, $out);
}


# Service-/Job-Aktionen (actions) + Unit-Steuerung
post '/action/*name/*cmd' => sub {
  my $c = shift;
  if (!$managed_configs_valid) {
    return $c->render(status=>503, json=>{ok=>0,error=>'managed_configs.json ist ungueltig',config_error=>$managed_configs_error,degraded=>true()});
  }
  my ($name, $cmd) = ($c->stash('name'), $c->stash('cmd'));

  return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Befehl'}, status=>400)
    if !defined $name || !defined $cmd || $name =~ m{[/\\]} || $name =~ m{\.\.} || $cmd  =~ m{[/\\]} || $cmd  =~ m{\.\.};

  my $tool  = $SYSTEMCTL;
  my $flags = $SYSTEMCTL_FLAGS // '';
  my @ctl = ($tool, shellwords($flags));

  $logger->info(sprintf('ACTION begin %s name=%s cmd=%s', _fmt_req($c), $name, $cmd));

  # Globaler systemctl-Aufruf ohne Dienst nur noch explizit opt-in.
  # Normalerweise erfolgt daemon-reload automatisch bei freigegebenen Service-Aktionen.
  if ($cmd eq 'daemon-reload') {
    return $c->render(json=>{ok=>0,error=>'Globales daemon-reload ist deaktiviert'}, status=>403)
      unless $global->{allow_global_daemon_reload};
    my $rc = system(@ctl, 'daemon-reload');
    $logger->info("ACTION systemctl daemon-reload rc=$rc");
    return $rc == 0
      ? $c->render(json=>{ok=>1, action=>'daemon-reload', status=>'ok'})
      : $c->render(json=>{ok=>0,error=>"daemon-reload fehlgeschlagen (rc=$rc)"}, status=>500);
  }

  # Konfig-Eintrag laden
  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $svc = $e->{service} // $name;

  # Whitelist (actions)
  my $actmap = $e->{actions};
  return $c->render(json=>{ok=>0,error=>'Aktion nicht erlaubt'}, status=>400)
    unless (ref($actmap) eq 'HASH' && exists $actmap->{$cmd});

  my $raw_args = $actmap->{$cmd};
  return $c->render(json=>{ok=>0,error=>"actions[$cmd] muss Array sein"}, status=>400)
    unless ref($raw_args) eq 'ARRAY';

  my @extra = @$raw_args;
  for my $a (@extra) {
    return $c->render(json=>{ok=>0,error=>"Ungültiges Argument in actions[$cmd]"}, status=>400)
      unless defined $a && $a =~ /^[A-Za-z0-9._:+@\/=\-,]+$/;
  }

  # Runner (bash:/..., perl:/..., exec:/...) — nutzt @extra
  if ($svc =~ m{^(bash|sh|perl|exec):(/.+)$}) {
    my ($runner, $script) = ($1, $2);

    my ($script_ok, $script_checked) = _action_validate_script($runner, $script);
    return $c->render(json=>{ok=>0,error=>$script_checked}, status=>400) unless $script_ok;
    $script = $script_checked;
    if ($runner eq 'exec') {
      return $c->render(json=>{ok=>0,error=>"Binary nicht ausführbar: $script"}, status=>400) unless -x $script;
    } else {
      return $c->render(json=>{ok=>0,error=>"Script nicht lesbar: $script"}, status=>400) unless -r $script;
    }

    my $is_systemctl_exec = ($runner eq 'exec' && $script eq $SYSTEMCTL);
    if ($is_systemctl_exec) {
      my %deny = map { $_ => 1 } qw(
        poweroff reboot halt kexec rescue emergency default isolate exit switch-root
        set-environment unset-environment
      );
      my $sub = $extra[0] // '';
      return $c->render(json=>{ok=>0,error=>'Subcommand verboten'}, status=>400) if $deny{$sub};

      if (($e->{category} // '') eq 'service' && $cmd =~ /^(start|restart|reload|stop_start)$/) {
        my $rc = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'daemon-reload');
        $logger->info("ACTION auto daemon-reload (exec:systemctl) rc=$rc");
        return $c->render(json=>{ok=>0,error=>"daemon-reload (auto) fehlgeschlagen (rc=$rc)"}, status=>500) unless $rc == 0;
      }
    }

    my @argv =
        $runner eq 'perl' ? ('/usr/bin/perl', $script, @extra)
      : ($runner eq 'bash' || $runner eq 'sh') ? ('/bin/bash', $script, @extra)
      : ($runner eq 'exec') ? ($script, @extra)
      : return $c->render(json=>{ok=>0,error=>"Unbekannter Runner: $runner"}, status=>400);

    my ($script_dir) = $script =~ m{^(.+)/[^/]+$};
    my $timeout = ($global->{script_timeout} && $global->{script_timeout} =~ /^\d+$/)
      ? 0 + $global->{script_timeout} : DEFAULT_SCRIPT_TIMEOUT;
    my $start = time();

    $logger->info(sprintf('SCRIPT begin %s runner=%s script=%s args=%s mode=Mojo::IOLoop::Subprocess',
      _fmt_req($c), $runner, $script, (join(' ', @extra) || '-')));

    $c->render_later;
    my $sp = Mojo::IOLoop::Subprocess->new;
    $sp->run(
      sub {
        return _run_argv_capture(\@argv, $script_dir, $timeout);
      },
      sub {
        my ($subprocess, $sub_err, $result) = @_;
        my $dur = time() - $start;

        if ($sub_err || ref($result) ne 'HASH') {
          my $msg = $sub_err // 'ungültiges Subprozess-Ergebnis';
          $logger->warn(sprintf('SCRIPT failed %s runner=%s script=%s after=%.3fs err=%s',
            _fmt_req($c), $runner, $script, $dur, $msg));
          return $c->render(status=>500, json=>{ok=>0,error=>"Script-Ausführung fehlgeschlagen: $msg"});
        }

        if ($result->{timeout}) {
          $logger->warn(sprintf('SCRIPT timeout %s runner=%s script=%s after=%.3fs',
            _fmt_req($c), $runner, $script, $dur));
          return $c->render(status=>504, json=>{ok=>0,error=>"Script timeout nach ${timeout}s"});
        }

        unless ($result->{ok}) {
          my $msg = $result->{error} // 'unbekannter Fehler';
          $logger->warn(sprintf('SCRIPT failed %s runner=%s script=%s after=%.3fs err=%s',
            _fmt_req($c), $runner, $script, $dur, $msg));
          return $c->render(status=>500, json=>{ok=>0,error=>"Script-Ausführung fehlgeschlagen: $msg"});
        }

        my $rc = $result->{rc} // 255;
        $logger->info(sprintf('SCRIPT done %s rc=%d time=%.3fs bytes_out=%d bytes_err=%d mode=Mojo::IOLoop::Subprocess',
          _fmt_req($c), $rc, $dur, ($result->{bytes_out_total}//0), ($result->{bytes_err_total}//0)));

        if ($is_systemctl_exec) {
          my $sub = $extra[0] // '';
          if ($sub eq 'is-active' && defined $extra[1]) {
            my $u = $extra[1];
            my $status2 = ($rc == 0) ? 'running' : 'stopped';
            return $c->render(json=>{ok=>1, action=>"exec-systemctl $cmd", unit=>$u, status=>$status2, rc=>$rc});
          }
        }

        if ($rc == 0) {
          return $c->render(json=>{
            ok=>1, action=>'script', runner=>$runner, script=>$script, args=>\@extra, rc=>$rc,
            stdout=>($result->{stdout}//''), stderr=>($result->{stderr}//''),
          });
        }

        return $c->render(status=>500, json=>{
          ok=>0, error=>"Script fehlgeschlagen (rc=$rc)", rc=>$rc,
          stdout=>($result->{stdout}//''), stderr=>($result->{stderr}//''),
        });
      }
    );
    return;
  }

  # Sonderfall: "service":"systemctl" — Subcommand ohne Unit
  if ($svc eq 'systemctl') {
    return $c->render(json=>{ok=>0,error=>'Ungültiger systemctl-Subcommand'}, status=>400) unless $cmd =~ /^[A-Za-z0-9._:\@-]+$/;
    my %deny = map { $_ => 1 } qw(poweroff reboot halt kexec rescue emergency set-environment unset-environment default isolate exit switch-root);
    return $c->render(json=>{ok=>0,error=>'Subcommand verboten'}, status=>400) if $deny{$cmd};
    my $rc = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), $cmd);
    $logger->info("ACTION systemctl $cmd rc=$rc");
    return $rc == 0
      ? $c->render(json=>{ok=>1, action=>"systemctl $cmd", status=>'ok'})
      : $c->render(json=>{ok=>0,error=>"systemctl $cmd fehlgeschlagen (rc=$rc)"} , status=>500);
  }

  # Echte Dienste mit Unit-Namen
  return $c->render(json=>{ok=>0,error=>'Ungueltiger oder sicherheitskritischer Service-Name'}, status=>400)
    unless _action_validate_service_name($svc);
  my $run = sub { my ($subcmd) = @_; system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), $subcmd, $svc) == 0 };

  my $is_service_cat = ( ($e->{category} // '') eq 'service' );
  my $cmd_triggers   = ($cmd =~ /^(start|restart|reload|stop_start)$/);
  if ($is_service_cat && $cmd_triggers) {
    my $rc = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'daemon-reload');
    $logger->info("ACTION auto daemon-reload for category=service svc=$svc rc=$rc");
    return $c->render(json=>{ok=>0,error=>"daemon-reload (auto) fehlgeschlagen (rc=$rc)"}, status=>500) unless $rc == 0;
  }

  if ($cmd eq 'stop_start') {
    $run->('stop')   or return $c->render(json=>{ok=>0,error=>'Stop fehlgeschlagen'}, status=>500);
    $run->('start')  or return $c->render(json=>{ok=>0,error=>'Start fehlgeschlagen'}, status=>500);
    my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'is-active', $svc) == 0;
    $logger->info("ACTION $svc stop_start active=".($active?1:0));
    return $active ? $c->render(json=>{ok=>1,action=>'stop_start',status=>'running'})
                   : $c->render(json=>{ok=>0,error=>'Dienst nicht aktiv nach stop_start'}, status=>500);
  }
  elsif ($cmd eq 'restart') {
    $run->('restart') or return $c->render(json=>{ok=>0,error=>'Restart fehlgeschlagen'}, status=>500);
    my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'is-active', $svc) == 0;
    $logger->info("ACTION $svc restart active=".($active?1:0));
    return $active ? $c->render(json=>{ok=>1,action=>'restart',status=>'running'})
                   : $c->render(json=>{ok=>0,error=>'Dienst nicht aktiv nach restart'}, status=>500);
  }
  elsif ($cmd eq 'status') {
    my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'is-active', $svc) == 0;
    $logger->info("ACTION $svc status=".($active?'running':'stopped'));
    return $c->render(json=>{ok=>1,action=>'status',status=>($active?'running':'stopped')});
  }
  elsif ($cmd eq 'journal') {
    my $lines = 80;
    if (@extra && defined $extra[0] && $extra[0] =~ /^\d+$/) {
      $lines = 0 + $extra[0];
    }
    $lines = 20 if $lines < 20;
    $lines = 300 if $lines > 300;
    my ($rc, $out) = _capture_simple('/usr/bin/journalctl', '-u', $svc, '-n', $lines, '--no-pager', '-o', 'short-iso');
    $logger->info("ACTION $svc journal rc=$rc lines=$lines");
    return $c->render(json=>{ok=>1,action=>'journal',unit=>$svc,rc=>$rc,stdout=>($out // '')});
  }
  elsif ($cmd =~ /^(start|stop|reload)$/) {
    $run->($cmd) or return $c->render(json=>{ok=>0,error=>"Aktion $cmd fehlgeschlagen"}, status=>500);
    $logger->info("ACTION $svc $cmd ok=1");
    return $c->render(json=>{ok=>1,action=>$cmd,status=>'ok'});
  }
  else {
    return $c->render(json=>{ok=>0,error=>"Unbekannter Befehl: $cmd"}, status=>400);
  }
};


1;
