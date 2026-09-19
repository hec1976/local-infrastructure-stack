package main;
use strict;
use warnings;
use utf8;

# Mojolicious::Lite wird absichtlich nur in config-agent.pl geladen.
# Dieses Modul laeuft in package main und registriert seine Routen
# in derselben bereits initialisierten Lite-App.
use Mojo::JSON qw(true false);

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
  $git_config_backup_dir, $git_settings_backup_dir,
  $git_upload_enabled, $git_upload_valid, $git_upload_error,
  $git_upload_token_file, $git_upload_workspace_root
);
our (%cfgmap);

get '/' => sub {
  my $c = shift;
  my $git_state = _load_git_configuration();
  $c->render(json => {
    ok=>1, name=>'config-manager', version=>$VERSION,
    status=>(($git_state->{valid} && $managed_configs_valid && (!$git_upload_enabled || ($git_upload_valid && -f $git_upload_token_file))) ? 'running' : 'degraded'),
    managed_configs=>{
      file=>$configsfile, canonical_file=>$managed_configs_file,
      legacy=>($using_legacy_configs ? true() : false()),
      valid=>($managed_configs_valid ? true() : false()),
      (length($managed_configs_error) ? (error=>$managed_configs_error) : ()),
    },
    git_deploy=>{
      enabled=>($git_deploy_enabled ? true() : false()),
      settings_file=>$globalfile,
      profiles_file=>$gitfile,
      profiles_exists=>($git_config_exists ? true() : false()),
      config_valid=>($git_config_valid ? true() : false()),
      degraded=>($git_config_valid ? false() : true()),
      generation=>$git_config_generation,
      (length($git_settings_error) ? (settings_error=>$git_settings_error) : ()),
      (length($git_profiles_error) ? (profiles_error=>$git_profiles_error) : ()),
      (length($git_config_error) ? (error=>$git_config_error) : ()),
    },
    git_upload=>{
      enabled=>($git_upload_enabled ? true() : false()),
      valid=>($git_upload_valid ? true() : false()),
      degraded=>(($git_upload_enabled && (!$git_upload_valid || !-f $git_upload_token_file)) ? true() : false()),
      workspace_root=>$git_upload_workspace_root,
      (length($git_upload_error) ? (error=>$git_upload_error) : ()),
    },
  });
};


# Health-Check
#
# Wichtig: Config-spezifische Backup-Unterverzeichnisse werden absichtlich
# lazy erzeugt. Bei auto_create_backups=true ist ein noch nicht vorhandenes
# Unterverzeichnis deshalb KEIN Fehler, sondern bedeutet lediglich, dass fuer
# diese Config noch kein Backup angelegt wurde. Nur der Backup-Root selbst muss
# vorhanden und beschreibbar sein.
get '/health' => sub {
  my $c = shift;
  my (@errors, @warnings, @info);
  my ($backup_dirs_present, $backup_dirs_lazy) = (0, 0);

  push @errors, "managed_configs.json ungueltig: $managed_configs_error" unless $managed_configs_valid;

  if (!-d $backupRoot) {
    push @errors, "Backup-Verzeichnis fehlt: $backupRoot";
  } elsif (!-w $backupRoot) {
    push @errors, "Backup-Verzeichnis nicht beschreibbar: $backupRoot";
  }

  if (!-d $tmpDir) {
    push @errors, "Tmp-Verzeichnis fehlt: $tmpDir";
  } elsif (!-w $tmpDir) {
    push @errors, "Tmp-Verzeichnis nicht beschreibbar: $tmpDir";
  }

  if ($git_upload_enabled) {
    push @errors, "Git Upload ungueltig: $git_upload_error" unless $git_upload_valid;
    push @errors, "Forgejo Token-Datei fehlt: $git_upload_token_file" unless -f $git_upload_token_file;
    push @errors, "Git Upload Workspace fehlt: $git_upload_workspace_root" unless -d $git_upload_workspace_root;
  }

  for my $name (sort keys %cfgmap) {
    my $f = $cfgmap{$name}{path};
    my $required = exists($cfgmap{$name}{required}) ? ($cfgmap{$name}{required} ? 1 : 0) : 1;
    if (!-f $f) {
      if ($required) {
        push @errors, "$name → fehlt: $f";
      } else {
        push @info, "$name → optional/nicht installiert: $f";
      }
    } elsif ($path_guard ne 'off' && ! _is_allowed_path($f)) {
      push @errors, "$name → Pfad nicht erlaubt (Guard=$path_guard): $f";
    }

    my $bd = $cfgmap{$name}{backup_dir};
    if (-d $bd) {
      $backup_dirs_present++;
      push @errors, "$name → Backup-Dir nicht beschreibbar: $bd" unless -w $bd;
    } elsif ($auto_create_backup_subdirs) {
      $backup_dirs_lazy++;
      push @info, "$name → noch kein Backup; Verzeichnis wird beim ersten Backup angelegt: $bd";
    } else {
      push @errors, "$name → Backup-Dir fehlt und auto_create_backups ist deaktiviert: $bd";
    }
  }

  my $status = @errors ? 'error' : (@warnings ? 'warning' : 'ok');
  my %body = (
    ok       => @errors ? false() : true(),
    status   => $status,
    errors   => \@errors,
    warnings => \@warnings,
    info     => \@info,
    summary  => {
      managed_configs      => scalar(keys %cfgmap),
      backup_dirs_present  => $backup_dirs_present,
      backup_dirs_lazy     => $backup_dirs_lazy,
      auto_create_backups  => $auto_create_backup_subdirs ? true() : false(),
    },
  );
  $body{error} = join('; ', @errors) if @errors; # Backward compatibility

  return $c->render(json=>\%body, status=>(@errors ? 503 : 200));
};


# Read-only Forgejo-Browser fuer den Deployment-Profil-Assistenten.
# Die Registrierung liegt bewusst im zentralen Routes-Modul direkt vor dem
# Catch-all. Dadurch kann keine ältere oder bedingt geladene Upload-Route den
# Assistenten mit einem 404 blockieren.
get '/git_deploy/repositories' => sub {
  my $c = shift;
  my $force = ($c->param('refresh') // '') =~ /^(?:1|true)$/i ? 1 : 0;
  my $repos = eval { _gu_repositories($force, 0) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>503) if $@;
  $c->render(json=>{ok=>true(), repositories=>$repos});
};

get '/git_deploy/repositories/:owner/:repository/scan' => sub {
  my $c = shift;
  my $owner = $c->stash('owner');
  my $repository = $c->stash('repository');
  my $branch = $c->param('branch') // '';
  $c->render_later;
  my $sp = Mojo::IOLoop::Subprocess->new;
  $sp->run(
    sub { return _gu_repo_scan_execute($owner, $repository, $branch); },
    sub {
      my ($sub, $err, $result) = @_;
      if ($err || ref($result) ne 'HASH') {
        return $c->render(json=>{ok=>false(),error=>_gu_error_message($err // 'Ungueltiges Scan-Ergebnis')},status=>400);
      }
      $logger->info(sprintf('GIT_DEPLOY_REPOSITORY_SCAN %s repo=%s/%s branch=%s files=%d warnings=%d', _fmt_req($c), $owner, $repository, $branch, ($result->{summary}{files}//0), ($result->{summary}{warnings}//0)));
      $c->render(json=>$result);
    }
  );
};

get '/git_deploy/repositories/:owner/:repository/branches' => sub {
  my $c = shift;
  my $data = eval { _gu_branches($c->stash('owner'), $c->stash('repository')) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  $c->render(json=>{ok=>true(), %$data});
};

# Catch-all
any '/*whatever' => sub {
  my $c = shift;
  $c->render(json=>{ok=>0,error=>"Unbekannte Route: ".$c->req->method." ".$c->req->url->to_string}, status=>404);
};


1;
