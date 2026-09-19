package main;
use strict;
use warnings;
use utf8;

# Mojolicious::Lite wird absichtlich nur in config-agent.pl geladen.
# Dieses Modul laeuft in package main und registriert seine Routen
# in derselben bereits initialisierten Lite-App.
use Mojo::JSON qw(encode_json decode_json true false);
use Mojo::File qw(path);
use Fcntl qw(:flock);

our (
  $VERSION, $SYSTEMCTL, $SYSTEMCTL_FLAGS,
  $Bin, $globalfile, $managed_configs_file, $legacy_configs_file,
  $configsfile, $using_legacy_configs, $gitfile,
  $global, $configs, $logger, $log_level,
  $api_token, $allowed_ips, $tmpDir, $backupRoot, $maxBackups, $backupRetentionDays, $minimumBackups,
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

$managed_configs_valid = 1;
$managed_configs_error = '';
$configs = undef;

sub _validate_registry_security_or_die {
  my ($cfg) = @_;
  die "managed_configs.json muss ein Objekt (HASH) sein" unless ref($cfg) eq 'HASH';
  for my $name (keys %$cfg) {
    die "Ungueltige Config-ID: $name"
      if !defined($name) || !length($name) || $name =~ m{[/\\]} || $name =~ m{\.\.};
    my $entry = $cfg->{$name};
    die "Config-Eintrag $name muss ein Objekt sein" unless ref($entry) eq 'HASH';
    my $target = $entry->{path};
    die "Config-Eintrag $name: path fehlt oder ist nicht absolut"
      unless defined($target) && !ref($target) && $target =~ m{^/};
    die "Config-Eintrag $name: geschuetzter Systempfad ist verboten: $target"
      if _is_declared_hard_protected_path($target);
    die "Config-Eintrag $name: Ziel-Symlink ist verboten: $target" if -l $target;
    if (exists $entry->{desired_status}) {
      my $desired = $entry->{desired_status};
      die "Config-Eintrag $name: desired_status muss ein String sein" if ref($desired);
      $desired = lc($desired // '');
      die "Config-Eintrag $name: desired_status ungueltig: $desired"
        unless $desired =~ /^(?:running|stopped|disabled)$/;
    }
  }
  return $cfg;
}

sub _load_managed_configs_or_die {
  my $raw = read_all($configsfile);
  my $cfg = decode_json($raw);
  return _validate_registry_security_or_die($cfg);
}

$configs = eval { _load_managed_configs_or_die() };
if ($@) {
  $managed_configs_valid = 0;
  $managed_configs_error = "$@";
  $managed_configs_error =~ s/\s+$//;
  $configs = {};
  $logger->error("MANAGED_CONFIG degraded file=$configsfile error=$managed_configs_error");
}

# ==================================================
# Konfigurations-Mapping (managed_configs.json) — Actions-Normalisierung
# ==================================================
%cfgmap = ();

sub _derive_actions {
  my ($entry) = @_;
  my %actions;

  if (ref($entry->{actions}) eq 'HASH') {
    while (my ($k,$v)=each %{$entry->{actions}}) { $actions{$k} = (ref($v) eq 'ARRAY') ? [@$v] : []; }
    return \%actions;
  }
  if (ref($entry->{commands}) eq 'HASH') {
    while (my ($k,$v)=each %{$entry->{commands}}) { $actions{$k} = (ref($v) eq 'ARRAY') ? [@$v] : []; }
    return \%actions;
  }
  if (ref($entry->{command_args}) eq 'HASH') {
    my @tokens = ref($entry->{commands}) eq 'ARRAY' ? @{$entry->{commands}} : keys %{$entry->{command_args}};
    for my $t (@tokens) { my $arr = $entry->{command_args}{$t}; $actions{$t} = (ref($arr) eq 'ARRAY') ? [@$arr] : []; }
    return \%actions;
  }
  if (ref($entry->{commands}) eq 'ARRAY' && grep { $_ eq 'run' } @{$entry->{commands}}) {
    $actions{run} = [];
  }
  return \%actions;
}

sub _rebuild_cfgmap_from {
  my ($cfg) = @_;
  %cfgmap = ();
  while (my ($name,$entry) = each %{$cfg}) {
    next if !defined $name || $name =~ m{[/\\]} || $name =~ m{\.\.};

    my $actions = _derive_actions($entry);
    my $path    = $entry->{path};

    $cfgmap{$name} = {
      %$entry,
      id         => $name,
      service    => $entry->{service}  // $name,
      category   => $entry->{category} // 'uncategorized',
      path       => $path,
      actions    => $actions,
      backup_dir => _backup_dir_for($name),
      # legacy Felder (Anzeige/Audit)
      commands      => $entry->{commands},
      command_args  => $entry->{command_args},
    };
  }
}


sub _render_managed_configs_degraded {
  my ($c) = @_;
  return 0 if $managed_configs_valid;
  $c->render(
    status => 503,
    json => {
      ok => 0,
      error => 'managed_configs.json ist ungueltig',
      config_error => $managed_configs_error,
      file => $configsfile,
      degraded => true(),
    }
  );
  return 1;
}

# Liste der Konfigurationen (Metadaten)
get '/configs' => sub {
  my $c = shift;
  return if _render_managed_configs_degraded($c);
  my @list;
  for my $name (sort keys %cfgmap) {
    my $e = $cfgmap{$name};
    my $filename = $e->{path} =~ m{/([^/]+)$} ? $1 : $e->{path};
    my ($ext) = $filename =~ /\.([^.]+)$/;
    my $actions = $e->{actions} // {};
    my @tokens  = sort keys %{$actions};
    my $service = $e->{service} // '';
    my $desired_status = $e->{desired_status} // '';
    if (!length($desired_status) && length($service) && exists $actions->{status}) {
      # Fuer verwaltete Services ist "running" der konservative Portal-Sollwert.
      # Ein explizites desired_status im Registry-Eintrag ueberschreibt diesen Default.
      $desired_status = 'running';
    }
    push @list, {
      id=>$name, filename=>$filename, filetype=>lc($ext // 'txt'),
      category=>$e->{category}, service=>$service, actions=>\@tokens,
      desired_status=>$desired_status
    };
  }
  $c->res->headers->content_type('application/json');
  $c->render(json => { ok=>1, configs => \@list });
};

# Datei-Inhalt abrufen
get '/config/*name' => sub {
  my $c = shift;
  return if _render_managed_configs_degraded($c);
  my $name = $c->stash('name');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.};
  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $p = $e->{path};
  return $c->render(json=>{ok=>0,error=>"Pfad nicht erlaubt"}, status=>400) unless _is_allowed_path($p);
  $logger->info(sprintf('READ %s name=%s path=%s', _fmt_req($c), $name, $p));
  return $c->render(json=>{ok=>0,error=>"Datei $p nicht vorhanden"}, status=>404) unless -f $p;
  open my $fh, "<:raw", $p or return $c->render(json=>{ok=>0,error=>"Kann Datei nicht lesen: $!"}, status=>500);
  my $data = do { local $/; <$fh> }; close $fh;
  $c->res->headers->content_type('application/octet-stream');
  $c->render(data => $data);
};

# Datei speichern (+ Backup)
post '/config/*name' => sub {
  my $c = shift;
  return if _render_managed_configs_degraded($c);
  my $name = $c->stash('name');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.};
  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);

  my $path  = $e->{path};
  return $c->render(json=>{ok=>0,error=>"Pfad nicht erlaubt"}, status=>400) unless _is_allowed_path($path);
  $logger->info(sprintf('SAVE begin %s name=%s path=%s', _fmt_req($c), $name, $path));

  my $content = eval { _read_body_or_die($c) };
  if (my $exc = $@) {
    if (ref($exc) eq 'RequestTooLarge') {
      return $c->render(json=>{ok=>0,error=>'Anfrage zu gross (max_message_size überschritten), Body wurde nicht vollständig empfangen'}, status=>413);
    }
    my $msg = ref($exc) ? "$exc" : $exc;
    return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $msg"}, status=>500);
  }
  if (($c->req->headers->content_type // '') =~ m{application/json}i) {
    my $j = eval { $c->req->json };
    if (!$@ && ref($j) eq 'HASH' && exists $j->{content}) { $content = $j->{content} // ''; }
  }

  # Backup, Schreiben und apply_meta serialisiert unter demselben Pfad-Lock,
  # damit zwei nahezu gleichzeitige Saves auf dieselbe Config sich nicht
  # ueberholen koennen.
  my ($method, $meta_error);
  eval {
    _with_config_file_lock($path, sub {
      _ensure_backup_dir($e);
      _create_current_backup($e, $path, 'SAVE');
      $method = safe_write_file($path, $content, 1);
      eval { _apply_meta($e, $path); 1 } or do { $meta_error = "$@"; $logger->warn("apply_meta Fehler: $meta_error"); };
    });
    1;
  } or return $c->render(json=>{ok=>0,error=>"Kann Datei nicht speichern: $@"}, status=>500);

  # Loggen, ob Meta angewendet würde
  my $meta_wanted = defined $e->{apply_meta} ? $e->{apply_meta}
                  : ($apply_meta_enabled || defined($e->{user}) || defined($e->{group}) || defined($e->{mode}));
  $logger->info("SAVE meta_wanted=".($meta_wanted?1:0)." user=".($e->{user}//'')." group=".($e->{group}//'')." mode=".($e->{mode}//''));

  my $applied_mode = _mode_str($path);
  my ($uid,$gid)   = ((stat($path))[4], (stat($path))[5]);
  my $size         = -s $path;

  $logger->info(sprintf('SAVE done %s method=%s size=%s mode=%s', _fmt_req($c), ($method//'unknown'), ($size//'?'), ($applied_mode//'----')));

  $c->render(json => {
    ok=>1,
    saved     => $name, path => $path, method => $method,
    requested => { user=>$e->{user}, group=>$e->{group}, mode=>$e->{mode}, apply_meta => ($meta_wanted ? true() : false()) },
    applied   => { uid=>$uid, gid=>$gid, mode=>$applied_mode },
    (defined $meta_error ? (meta_error => $meta_error) : ()),
  });
};

# Backup-Liste fuer einen Config-Eintrag.
# Ein fehlender Unterordner ist beim Lesen kein Fehler, sondern bedeutet,
# dass fuer diese Konfiguration noch kein Backup angelegt wurde.
sub _list_backups_for_entry {
  my ($e) = @_;
  my $bdir = $e->{backup_dir};
  return [] unless defined $bdir && -d $bdir;

  my $base = path($e->{path})->basename;
  my @files = sort { $b cmp $a } grep { defined } glob("$bdir/$base.bak.*");
  @files = map { s{^\Q$bdir\E/}{}r } @files;
  return \@files;
}

# Backup-Listen fuer mehrere Konfigurationen in einem Request.
post '/backups/batch' => sub {
  my $c = shift;
  return if _render_managed_configs_degraded($c);

  my $body = eval { _read_body_or_die($c) };
  if (my $exc = $@) {
    if (ref($exc) eq 'RequestTooLarge') {
      return $c->render(
        json   => {ok=>0,error=>'Anfrage zu gross (max_message_size überschritten), Body wurde nicht vollständig empfangen'},
        status => 413
      );
    }
    my $msg = ref($exc) ? "$exc" : $exc;
    return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $msg"}, status=>500);
  }

  my $payload = eval { decode_json($body) };
  return $c->render(json=>{ok=>0,error=>'Ungültiges JSON'}, status=>400)
    if $@ || ref($payload) ne 'HASH';

  my $ids = $payload->{ids};
  return $c->render(json=>{ok=>0,error=>'ids muss ein Array sein'}, status=>400)
    unless ref($ids) eq 'ARRAY';
  return $c->render(json=>{ok=>0,error=>'Zu viele IDs (Maximum 1000)'}, status=>400)
    if @$ids > 1000;

  my (%seen, %backups);
  for my $id (@$ids) {
    return $c->render(json=>{ok=>0,error=>'Ungültige Config-ID'}, status=>400)
      unless defined $id && !ref($id) && length($id)
          && $id !~ m{[/\\]} && $id !~ m{\.\.};
    next if $seen{$id}++;

    # Bei einer zwischen /configs und diesem Request entfernten ID bleibt
    # die Batch-Antwort robust und liefert fuer diese ID eine leere Liste.
    my $e = $cfgmap{$id};
    $backups{$id} = $e ? _list_backups_for_entry($e) : [];
  }

  $c->render(json => {ok=>1, backups=>\%backups});
};

# Liste der Backups (Dateinamen)
get '/backups/*name' => sub {
  my $c = shift;
  return if _render_managed_configs_degraded($c);
  my $name = $c->stash('name');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400) if $name =~ m{[/\\]} || $name =~ m{\.\.};
  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  $c->render(json => {ok=>1, backups=>_list_backups_for_entry($e)});
};

# Download der Backup-Datei
get '/backupfile/*name/*filename' => sub {
  my $c = shift;
  return if _render_managed_configs_degraded($c);
  my $name = $c->stash('name');
  my $filename = $c->stash('filename');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Filename'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.} || $filename =~ m{[/\\]} || $filename =~ m{\.\.};

  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $bdir = $e->{backup_dir};
  my $base = path($e->{path})->basename;
  return $c->render(json=>{ok=>0,error=>'Ungültiger Backup-Name'}, status=>400)
    unless $filename =~ /^\Q$base\E\.bak\.\d{8}_\d{6}_\d{3}$/;

  my $file = "$bdir/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'}, status=>404) unless -f $file;

  $c->res->headers->content_type('application/octet-stream');
  $c->res->headers->content_disposition("attachment; filename=\"$filename\"");
  return $c->reply->file($file);
};

# Inhalt der Backup-Datei als Text (Preview)
get '/backupcontent/*name/*filename' => sub {
  my $c = shift;
  return if _render_managed_configs_degraded($c);
  my $name = $c->stash('name');
  my $filename = $c->stash('filename');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Filename'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.} || $filename =~ m{[/\\]} || $filename =~ m{\.\.};

  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $bdir = $e->{backup_dir};
  my $base = path($e->{path})->basename;
  return $c->render(json=>{ok=>0,error=>'Ungültiger Backup-Name'}, status=>400)
    unless $filename =~ /^\Q$base\E\.bak\.\d{8}_\d{6}_\d{3}$/;

  my $file = "$bdir/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'}, status=>404) unless -f $file;

  open my $fh, '<:raw', $file or return $c->render(json=>{ok=>0,error=>"Die Backup-Datei konnte nicht geöffnet werden: $!"}, status=>500);
  my $content = do { local $/; <$fh> }; close $fh;
  $c->render(json => { ok=>1, content => $content });
};

# Restore: Backup → Ziel
post '/restore/*name/*filename' => sub {
  my $c = shift;
  return if _render_managed_configs_degraded($c);
  my $name = $c->stash('name');
  my $filename = $c->stash('filename');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Filename'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.} || $filename =~ m{[/\\]} || $filename =~ m{\.\.};

  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $base = path($e->{path})->basename;
  my $bdir = $e->{backup_dir};
  return $c->render(json=>{ok=>0,error=>'Ungültiger Backup-Name'}, status=>400)
    unless $filename =~ /^\Q$base\E\.bak\.\d{8}_\d{6}_\d{3}$/;

  my $src  = "$bdir/$filename";
  my $dest = $e->{path};
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'}, status=>404) unless -f $src;
  return $c->render(json=>{ok=>0,error=>'Backup-Quelle ist ein Symlink, verweigert'}, status=>400) if -l $src;
  if ($path_guard ne 'off') {
    my $nlink_src = (stat($src))[3];
    return $c->render(json=>{ok=>0,error=>'Backup-Quelle hat mehr als einen Hardlink, verweigert'}, status=>400)
      if defined $nlink_src && $nlink_src > 1;
  }
  return $c->render(json=>{ok=>0,error=>'Pfad nicht erlaubt'}, status=>400) unless _is_allowed_path($dest);

  $logger->info(sprintf('RESTORE begin %s name=%s from=%s dest=%s', _fmt_req($c), $name, $src, $dest));

  my ($restore_backup, $restore_method, $meta_error);
  eval {
    _with_config_file_lock($dest, sub {
      # Quelle ZUERST lesen: sonst kann die Rotation des Pre-Restore-Backups
      # (bei bereits erreichtem maxBackups) genau die Restore-Quelle löschen,
      # falls sie das älteste vorhandene Backup ist.
      my $restore_content = read_all($src);

      # Vor dem Restore immer den aktuellen Stand sichern.
      $restore_backup = _create_current_backup($e, $dest, 'RESTORE-PRE');

      # Restore strikt atomar: kein Plain-Write-Fallback.
      $restore_method = safe_write_file($dest, $restore_content, 1);

      eval { _apply_meta($e, $dest); 1 } or do { $meta_error = "$@"; $logger->warn("apply_meta Fehler: $meta_error"); };
    });
    1;
  } or return $c->render(json=>{ok=>0,error=>"Wiederherstellung fehlgeschlagen: $@"}, status=>500);

  my $applied_mode = _mode_str($dest);
  my ($uid,$gid)   = ((stat($dest))[4], (stat($dest))[5]);

  $logger->info("RESTORE done $filename -> $dest");

  my $meta_wanted = defined $e->{apply_meta} ? $e->{apply_meta}
                  : ($apply_meta_enabled || defined($e->{user}) || defined($e->{group}) || defined($e->{mode}));

  $c->render(json => {
    ok=>1,
    restored  => $name, from => $filename, method => $restore_method, pre_restore_backup => $restore_backup,
    requested => { user=>$e->{user}, group=>$e->{group}, mode=>$e->{mode}, apply_meta => ($meta_wanted ? true() : false()) },
    applied   => { uid=>$uid, gid=>$gid, mode=>$applied_mode },
    (defined $meta_error ? (meta_error => $meta_error) : ()),
  });
};


# Backups der Registry-Datei managed_configs.json. Diese Backups sind
# getrennt von den Backups der durch die Registry verwalteten Nutzdateien.
sub _managed_configs_backup_dir {
  return "$backupRoot/managed-configs";
}

sub _ensure_managed_configs_backup_dir {
  my $dir = _managed_configs_backup_dir();
  die "Managed-Configs-Backup-Verzeichnis darf kein Symlink sein: $dir" if -l $dir;
  die "Managed-Configs-Backup-Pfad ist kein Verzeichnis: $dir" if -e $dir && !-d $dir;
  unless (-d $dir) {
    mkdir $dir or die "Managed-Configs-Backup-Verzeichnis konnte nicht angelegt werden: $!";
    chmod(0770, $dir) or die "Managed-Configs-Backup-Rechte konnten nicht gesetzt werden: $!";
  }
  return $dir;
}

sub _create_managed_configs_backup {
  return undef unless -f $configsfile;
  die "managed_configs.json darf kein Symlink sein: $configsfile" if -l $configsfile;
  if ($path_guard ne 'off') {
    my $nlink = (stat($configsfile))[3];
    die "managed_configs.json hat mehr als einen Hardlink" if defined $nlink && $nlink > 1;
  }

  my $dir = _ensure_managed_configs_backup_dir();
  my ($candidate, $attempts) = ('', 0);
  while (1) {
    $candidate = "$dir/managed_configs.json.bak." . _backup_timestamp();
    last unless -e $candidate;
    die "Managed-Configs-Backup mehrfach kollidiert: $candidate" if ++$attempts >= 5;
    Time::HiRes::sleep(0.001);
  }

  path($configsfile)->copy_to($candidate);
  chmod(0660, $candidate) or die "Managed-Configs-Backup-Rechte konnten nicht gesetzt werden: $!";

  _rotate_backup_files($dir, 'managed_configs.json');
  $logger->info("MANAGED_CONFIG backup file=$candidate");
  return path($candidate)->basename;
}

sub _list_managed_configs_backups {
  my $dir = _managed_configs_backup_dir();
  return [] unless -d $dir;
  my @files = sort { $b cmp $a } grep { defined } glob("$dir/managed_configs.json.bak.*");
  @files = map { s{^\Q$dir\E/}{}r } @files;
  return \@files;
}

sub _validate_managed_configs_content {
  my ($content) = @_;
  my $cfg = decode_json($content);
  return _validate_registry_security_or_die($cfg);
}

# Rohzugriff auf managed_configs.json (lesen)
get '/raw/managed-configs' => sub {
  my $c = shift;
  my $json;
  eval { $json = _with_configs_lock(LOCK_SH, sub { read_all($configsfile) }); 1 }
    or return $c->render(json=>{ok=>0,error=>"Fehler beim Lesen: $@"}, status=>500);
  $c->res->headers->content_type('application/json');
  $c->render(data => $json);
};

# Rohzugriff auf managed_configs.json (schreiben)
post '/raw/managed-configs' => sub {
  my $c = shift;
  my $newdata = eval { _read_body_or_die($c) };
  if (my $exc = $@) {
    if (ref($exc) eq 'RequestTooLarge') {
      return $c->render(json=>{ok=>0,error=>'Anfrage zu gross (max_message_size überschritten), Body wurde nicht vollständig empfangen'}, status=>413);
    }
    my $msg = ref($exc) ? "$exc" : $exc;
    return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $msg"}, status=>500);
  }
  my $parsed;
  eval { $parsed = decode_json($newdata); 1 } or return $c->render(json=>{ok=>0,error=>"Ungültiges JSON: $@"}, status=>400);
  return $c->render(json=>{ok=>0,error=>'JSON muss ein Objekt (HASH) sein'}, status=>400) unless ref($parsed) eq 'HASH';
  eval { _validate_registry_security_or_die($parsed); 1 }
    or return $c->render(json=>{ok=>0,error=>"Security-Validierung fehlgeschlagen: $@"}, status=>400);

  my $backup;
  eval {
    _with_configs_lock(LOCK_EX, sub {
      $backup = _create_managed_configs_backup();
      safe_write_file($configsfile, $newdata, 1);
    });
    1;
  } or do {
    return $c->render(json=>{ok=>0,error=>"Fehler beim Schreiben: $@"}, status=>500);
  };

  $configs = $parsed;
  $managed_configs_valid = 1;
  $managed_configs_error = '';
  _rebuild_cfgmap_from($parsed);
  $c->render(json => { ok=>1, saved => 1, reload => 1, file=>$configsfile, backup=>$backup });
};

# Backup-Liste der Registry-Datei.
get '/raw/managed-configs/backups' => sub {
  my $c = shift;
  $c->render(json=>{ok=>1,file=>$configsfile,backups=>_list_managed_configs_backups()});
};

# Backup-Inhalt fuer eine Vorschau im Portal.
# Relaxed placeholder (#filename) erlaubt Punkte im geprüften Backup-Dateinamen.
get '/raw/managed-configs/backup/#filename' => sub {
  my $c = shift;
  my $filename = $c->stash('filename') // '';
  return $c->render(json=>{ok=>0,error=>'Ungueltiger Backup-Name'},status=>400)
    unless $filename =~ /^managed_configs\.json\.bak\.\d{8}_\d{6}_\d{3}$/;
  my $src = _managed_configs_backup_dir() . "/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'},status=>404) unless -f $src && !-l $src;
  my $content = eval { read_all($src) };
  return $c->render(json=>{ok=>0,error=>"Backup konnte nicht gelesen werden: $@"},status=>500) if $@;
  my $cfg = eval { _validate_managed_configs_content($content) };
  return $c->render(json=>{ok=>0,error=>"Backup enthaelt ungueltiges JSON: $@"},status=>400) if $@;
  $c->render(json=>{ok=>1,filename=>$filename,content=>$content,entries=>scalar(keys %$cfg)});
};

# Restore der Registry-Datei mit Pre-Restore-Backup und sofortigem Reload.
post '/raw/managed-configs/restore/#filename' => sub {
  my $c = shift;
  my $filename = $c->stash('filename') // '';
  return $c->render(json=>{ok=>0,error=>'Ungueltiger Backup-Name'},status=>400)
    unless $filename =~ /^managed_configs\.json\.bak\.\d{8}_\d{6}_\d{3}$/;
  my $src = _managed_configs_backup_dir() . "/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'},status=>404) unless -f $src && !-l $src;

  my ($pre_backup, $cfg);
  eval {
    _with_configs_lock(LOCK_EX, sub {
      my $content = read_all($src);
      $cfg = _validate_managed_configs_content($content);
      $pre_backup = _create_managed_configs_backup();
      safe_write_file($configsfile, $content, 1);
    });
    1;
  } or return $c->render(json=>{ok=>0,error=>"Restore fehlgeschlagen: $@"},status=>500);

  $configs = $cfg;
  $managed_configs_valid = 1;
  $managed_configs_error = '';
  _rebuild_cfgmap_from($cfg);
  $logger->info("MANAGED_CONFIG restore source=$filename pre_backup=" . ($pre_backup // 'none'));
  $c->render(json=>{ok=>1,restored=>$filename,pre_restore_backup=>$pre_backup,file=>$configsfile,entries=>scalar(keys %$cfg)});
};

# managed_configs.json neu laden (ohne schreiben)
post '/raw/managed-configs/reload' => sub {
  my $c = shift;
  my $json;
  eval { $json = _with_configs_lock(LOCK_SH, sub { read_all($configsfile) }); 1 }
    or return $c->render(json=>{ok=>0,error=>"Fehler beim Lesen: $@"}, status=>500);
  my $cfg = eval { decode_json($json) } or return $c->render(json=>{ok=>0,error=>'Ungültiges JSON im File'}, status=>500);
  return $c->render(json=>{ok=>0,error=>'managed_configs.json muss ein Objekt (HASH) sein'}, status=>500) unless ref($cfg) eq 'HASH';
  $configs = $cfg;
  $managed_configs_valid = 1;
  $managed_configs_error = '';
  _rebuild_cfgmap_from($cfg);
  $c->render(json => { ok=>1, reloaded => 1, file=>$configsfile });
};

# managed_configs.json: Eintrag löschen
del '/raw/managed-configs/:name' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  my ($cfg, $new);

  eval {
    _with_configs_lock(LOCK_EX, sub {
      my $json = read_all($configsfile);
      $cfg = decode_json($json);
      die "managed_configs.json muss ein Objekt (HASH) sein" unless ref($cfg) eq 'HASH';
      die "Eintrag $name existiert nicht" unless exists $cfg->{$name};

      _create_managed_configs_backup();
      delete $cfg->{$name};
      $new = encode_json($cfg);
      safe_write_file($configsfile, $new, 1);
    });
    1;
  } or do {
    my $err = $@ // 'unbekannter Fehler';
    my $status = $err =~ /existiert nicht/ ? 404 : $err =~ /Objekt \(HASH\)/ ? 400 : 500;
    return $c->render(json=>{ok=>0,error=>$err}, status=>$status);
  };

  $configs = $cfg;
  $managed_configs_valid = 1;
  $managed_configs_error = '';
  _rebuild_cfgmap_from($cfg);
  $c->render(json => { ok=>1, deleted => $name, reload => 1, file=>$configsfile });
};


# Legacy API aliases through 2.x; Portal 2.0 uses /raw/managed-configs.
# Rohzugriff auf managed_configs.json (lesen)
get '/raw/configs' => sub {
  my $c = shift;
  my $json;
  eval { $json = _with_configs_lock(LOCK_SH, sub { read_all($configsfile) }); 1 }
    or return $c->render(json=>{ok=>0,error=>"Fehler beim Lesen: $@"}, status=>500);
  $c->res->headers->content_type('application/json');
  $c->render(data => $json);
};

# Rohzugriff auf managed_configs.json (schreiben)
post '/raw/configs' => sub {
  my $c = shift;
  my $newdata = eval { _read_body_or_die($c) };
  if (my $exc = $@) {
    if (ref($exc) eq 'RequestTooLarge') {
      return $c->render(json=>{ok=>0,error=>'Anfrage zu gross (max_message_size überschritten), Body wurde nicht vollständig empfangen'}, status=>413);
    }
    my $msg = ref($exc) ? "$exc" : $exc;
    return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $msg"}, status=>500);
  }
  my $parsed;
  eval { $parsed = decode_json($newdata); 1 } or return $c->render(json=>{ok=>0,error=>"Ungültiges JSON: $@"}, status=>400);
  return $c->render(json=>{ok=>0,error=>'JSON muss ein Objekt (HASH) sein'}, status=>400) unless ref($parsed) eq 'HASH';
  eval { _validate_registry_security_or_die($parsed); 1 }
    or return $c->render(json=>{ok=>0,error=>"Security-Validierung fehlgeschlagen: $@"}, status=>400);

  my $backup;
  eval {
    _with_configs_lock(LOCK_EX, sub {
      $backup = _create_managed_configs_backup();
      safe_write_file($configsfile, $newdata, 1);
    });
    1;
  } or do {
    return $c->render(json=>{ok=>0,error=>"Fehler beim Schreiben: $@"}, status=>500);
  };

  $configs = $parsed;
  $managed_configs_valid = 1;
  $managed_configs_error = '';
  _rebuild_cfgmap_from($parsed);
  $c->render(json => { ok=>1, saved => 1, reload => 1, file=>$configsfile, backup=>$backup });
};

# managed_configs.json neu laden (ohne schreiben)
post '/raw/configs/reload' => sub {
  my $c = shift;
  my $json;
  eval { $json = _with_configs_lock(LOCK_SH, sub { read_all($configsfile) }); 1 }
    or return $c->render(json=>{ok=>0,error=>"Fehler beim Lesen: $@"}, status=>500);
  my $cfg = eval { decode_json($json) } or return $c->render(json=>{ok=>0,error=>'Ungültiges JSON im File'}, status=>500);
  return $c->render(json=>{ok=>0,error=>'managed_configs.json muss ein Objekt (HASH) sein'}, status=>500) unless ref($cfg) eq 'HASH';
  $configs = $cfg;
  $managed_configs_valid = 1;
  $managed_configs_error = '';
  _rebuild_cfgmap_from($cfg);
  $c->render(json => { ok=>1, reloaded => 1, file=>$configsfile });
};

# managed_configs.json: Eintrag löschen
del '/raw/configs/:name' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  my ($cfg, $new);

  eval {
    _with_configs_lock(LOCK_EX, sub {
      my $json = read_all($configsfile);
      $cfg = decode_json($json);
      die "managed_configs.json muss ein Objekt (HASH) sein" unless ref($cfg) eq 'HASH';
      die "Eintrag $name existiert nicht" unless exists $cfg->{$name};

      _create_managed_configs_backup();
      delete $cfg->{$name};
      $new = encode_json($cfg);
      safe_write_file($configsfile, $new, 1);
    });
    1;
  } or do {
    my $err = $@ // 'unbekannter Fehler';
    my $status = $err =~ /existiert nicht/ ? 404 : $err =~ /Objekt \(HASH\)/ ? 400 : 500;
    return $c->render(json=>{ok=>0,error=>$err}, status=>$status);
  };

  $configs = $cfg;
  $managed_configs_valid = 1;
  $managed_configs_error = '';
  _rebuild_cfgmap_from($cfg);
  $c->render(json => { ok=>1, deleted => $name, reload => 1, file=>$configsfile });
};


_rebuild_cfgmap_from($configs);
$logger->info(sprintf(
  'BOOT version=%s managed_configs=%s legacy=%d umask=%04o path_guard=%s apply_meta_default=%d log_level=%s',
  $VERSION, $configsfile, $using_legacy_configs?1:0,
  _cur_umask(), $path_guard, $apply_meta_enabled?1:0, $log_level
));

1;
