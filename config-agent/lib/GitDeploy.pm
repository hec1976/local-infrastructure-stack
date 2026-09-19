package main;
use strict;
use warnings;
use utf8;

# Mojolicious::Lite wird absichtlich nur in config-agent.pl geladen.
# Dieses Modul laeuft in package main und registriert seine Routen
# in derselben bereits initialisierten Lite-App.
use Mojo::JSON qw(encode_json decode_json true false);
use Mojo::File qw(path);
use Mojo::URL;
use MIME::Base64 qw(encode_base64);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use Fcntl qw(:DEFAULT :mode :flock O_RDONLY O_WRONLY O_APPEND O_CREAT O_NONBLOCK);
use Time::HiRes qw(time sleep);
use Digest::SHA qw(sha256_hex);
use Text::ParseWords qw(shellwords);
use Config ();
use Scalar::Util qw(blessed);

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
  $git_allow_proxy_env, $git_allow_http, $git_verify_tls,
  $git_deploy_token_source, $git_deploy_token_file,
  $git_bin, $tar_bin, $mv_bin,
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

# -------- Git-Pull-Deploy (global settings + separate profiles, optional) --------
# Allgemeine Git-Werte liegen in global.json unter "git_deploy". Die Datei
# git_deploy.json enthaelt nur schema_version und profiles. Beide Quellen
# werden getrennt bearbeitet, aber gemeinsam validiert. Fehler legen nur das
# optionale Git-Modul still; der allgemeine Config-Agent bleibt verfuegbar.
$git_cfg = {};
$git_settings_cfg = {};
$git_profiles_cfg = {profiles=>{}};
$git_deploy_enabled = 0;
$git_allow_direct_request = 0;
$git_require_api_token = 1;
$git_require_ip_acl = 1;
$git_require_guard_enforce = 1;
$git_require_allowed_ref = 1;
$git_allow_proxy_env = 0;
$git_allow_http = 0;
$git_verify_tls = 1;
$git_deploy_token_source = 'file';
$git_deploy_token_file = '/opt/service/env/forgejo-api.token';
$git_bin = '/usr/bin/git';
$tar_bin = '/bin/tar';
$mv_bin = '/usr/bin/mv';
$git_state_dir = "$tmpDir/git-deploy";
$git_cache_root = "$git_state_dir/cache";
$git_status_root = "$git_state_dir/status";
$git_home_dir = "$git_state_dir/home";
$git_timeout = DEFAULT_GIT_TIMEOUT;
$git_default_keep_releases = DEFAULT_GIT_KEEP_RELEASES;
$git_default_max_files = DEFAULT_GIT_MAX_FILES;
$git_default_max_bytes = DEFAULT_GIT_MAX_BYTES;
$git_default_deploy_user = undef;
$git_default_auth_scheme = 'basic';
$git_default_ca_info = undef;
$git_allowed_hosts = [];
$git_profiles_raw = {};
$git_path_guard = 'off';
$GIT_ALLOWED = [];
$git_config_generation = 0;
$git_config_digest = '';
$git_settings_digest = '';
$git_profiles_digest = '';
$git_config_valid = 1;
$git_config_error = '';
$git_settings_error = '';
$git_profiles_error = '';
$git_config_exists = 0;
$git_config_backup_dir = "$backupRoot/git-deploy-config";
$git_settings_backup_dir = "$backupRoot/git-deploy-settings";

sub _json_bool_or_throw {
  my ($value, $label) = @_;
  $label //= 'Boolean-Wert';

  if (ref($value)) {
    my $class = blessed($value) // '';
    return $value ? 1 : 0 if $class =~ /Boolean$/;
    _deploy_throw('validation', "$label muss boolean sein");
  }

  # 0/1 bleiben aus Kompatibilitaetsgruenden erlaubt. Textwerte wie
  # "true" oder "false" sind dagegen gefaehrlich, weil Perl jeden
  # nicht-leeren String als wahr behandelt.
  return 0 if defined($value) && "$value" eq '0';
  return 1 if defined($value) && "$value" eq '1';
  _deploy_throw('validation', "$label muss boolean sein");
}

sub _uint_or_throw {
  my ($value, $label, $min, $max) = @_;
  _deploy_throw('validation', "$label muss eine Ganzzahl sein")
    unless defined($value) && !ref($value) && "$value" =~ /^\d+$/;
  my $n = 0 + $value;
  _deploy_throw('validation', "$label muss zwischen $min und $max liegen")
    if $n < $min || $n > $max;
  return $n;
}

sub _known_keys_or_throw {
  my ($hash, $allowed, $label) = @_;
  return unless ref($hash) eq 'HASH';
  my %allowed = map { $_ => 1 } @$allowed;
  for my $key (sort keys %$hash) {
    _deploy_throw('validation', "$label enthaelt ein unbekanntes Feld: $key")
      unless $allowed{$key};
  }
}

sub _pretty_json_text {
  my ($value) = @_;
  my $raw = encode_json($value);
  my ($out, $indent, $in_string, $escape) = ('', 0, 0, 0);
  for my $ch (split //, $raw) {
    if ($in_string) {
      $out .= $ch;
      if ($escape) { $escape = 0; next; }
      if ($ch eq '\\') { $escape = 1; next; }
      $in_string = 0 if $ch eq '"';
      next;
    }
    if ($ch eq '"') { $in_string = 1; $out .= $ch; next; }
    if ($ch eq '{' || $ch eq '[') {
      $out .= $ch . "\n";
      $indent++;
      $out .= '  ' x $indent;
    } elsif ($ch eq '}' || $ch eq ']') {
      $out .= "\n";
      $indent-- if $indent > 0;
      $out .= ('  ' x $indent) . $ch;
    } elsif ($ch eq ',') {
      $out .= ",\n" . ('  ' x $indent);
    } elsif ($ch eq ':') {
      $out .= ': ';
    } else {
      $out .= $ch;
    }
  }
  return $out . "\n";
}

sub _normalize_git_settings {
  my ($settings) = @_;
  my %out = ref($settings) eq 'HASH' ? %$settings : ();
  my $shared = ref($global->{forgejo}) eq 'HASH' ? $global->{forgejo} : {};

  my $forgejo_url = $shared->{url} // $shared->{base_url};
  if (defined($forgejo_url) && !ref($forgejo_url) && length($forgejo_url)) {
    my $u = eval { Mojo::URL->new($forgejo_url) };
    die "global.json: forgejo.url ist ungueltig" unless $u && length($u->host // '');
    my $scheme = lc($u->scheme // '');
    die "global.json: forgejo.url muss HTTP oder HTTPS verwenden"
      unless $scheme eq 'http' || $scheme eq 'https';
    my $port = $u->port // ($scheme eq 'http' ? 80 : 443);
    $out{allowed_git_hosts} = [lc($u->host) . ":$port"]
      unless ref($out{allowed_git_hosts}) eq 'ARRAY' && @{$out{allowed_git_hosts}};
    $out{allow_http} = 1 if $scheme eq 'http' && !exists($out{allow_http});
  }

  $out{deploy_token_file} = $shared->{token_file}
    if !exists($out{deploy_token_file}) && defined($shared->{token_file});
  $out{verify_tls} = $shared->{verify_tls}
    if !exists($out{verify_tls}) && exists($shared->{verify_tls});
  $out{ca_info} = $shared->{ca_file}
    if !exists($out{ca_info}) && defined($shared->{ca_file}) && length($shared->{ca_file});

  if ($out{enabled}) {
    $out{require_api_token} = 1 unless exists $out{require_api_token};
    $out{require_ip_acl} = 1 unless exists $out{require_ip_acl};
    $out{require_path_guard_enforce} = 1 unless exists $out{require_path_guard_enforce};
    $out{allow_direct_request} = 0 unless exists $out{allow_direct_request};
    $out{require_allowed_ref} = 1 unless exists $out{require_allowed_ref};
    $out{allow_proxy_env} = 0 unless exists $out{allow_proxy_env};
    $out{path_guard} = 'enforce' unless exists $out{path_guard};
    $out{deploy_token_source} = 'file' unless exists $out{deploy_token_source};
    $out{auth_scheme} = 'basic' unless exists $out{auth_scheme};
    $out{deploy_user} = 'config-agent' unless exists $out{deploy_user};
  }
  return \%out;
}

sub _git_settings_from_global {
  return _normalize_git_settings({}) unless exists $global->{git_deploy};
  die "global.json: git_deploy muss ein JSON-Objekt enthalten"
    unless ref($global->{git_deploy}) eq 'HASH';
  return _normalize_git_settings({%{$global->{git_deploy}}});
}

sub _normalize_simple_preserve {
  my ($items) = @_;
  return undef unless defined $items;
  die "preserve muss ein Array sein" unless ref($items) eq 'ARRAY';
  my @out;
  for my $item (@$items) {
    if (defined($item) && !ref($item)) {
      push @out, {path=>"$item", policy=>'preserve_existing', required=>0};
      next;
    }
    die "preserve enthaelt einen ungueltigen Eintrag" unless ref($item) eq 'HASH';
    my %copy = %$item;
    $copy{user} = delete($copy{owner}) if !exists($copy{user}) && exists($copy{owner});
    $copy{policy} = 'preserve_existing' unless exists $copy{policy};
    $copy{required} = 0 unless exists $copy{required};
    push @out, \%copy;
  }
  return \@out;
}

sub _normalize_post_deploy {
  my ($raw) = @_;
  return undef unless defined $raw;

  my $spec;
  if (!ref($raw)) {
    $spec = {script=>"$raw"};
  } elsif (ref($raw) eq 'ARRAY') {
    $spec = {argv=>[map { "$_" } @$raw]};
  } elsif (ref($raw) eq 'HASH') {
    $spec = {%$raw};
  } else {
    die "post_deploy muss ein String, Array oder JSON-Objekt sein";
  }

  _known_keys_or_throw($spec, [qw(script args argv cwd timeout run_on_rollback)], 'post_deploy');

  if (exists $spec->{script}) {
    my $script = $spec->{script};
    die "post_deploy.script muss ein relativer Pfad sein"
      unless defined($script) && !ref($script) && length($script) &&
             $script !~ /\0/ && $script !~ m{^/} &&
             $script !~ m{(?:^|/)\.\.(?:/|$)};
    $script =~ s{^\./+}{};
    my $args = $spec->{args};
    $args = [] unless defined $args;
    die "post_deploy.args muss ein Array sein" unless ref($args) eq 'ARRAY';
    $spec->{argv} = ["{release}/$script", @$args];
    delete @{$spec}{qw(script args)};
  }

  die "post_deploy.argv muss ein nicht leeres Array sein"
    unless ref($spec->{argv}) eq 'ARRAY' && @{$spec->{argv}};
  $spec->{cwd} = '{release}' unless defined($spec->{cwd}) && length($spec->{cwd});
  $spec->{timeout} = 120 unless defined $spec->{timeout};
  $spec->{run_on_rollback} = 1 unless exists $spec->{run_on_rollback};
  $spec->{run_on_rollback} = _json_bool_or_throw($spec->{run_on_rollback}, 'post_deploy.run_on_rollback');
  return $spec;
}


sub _normalize_package_repositories {
  my ($raw) = @_;
  return [] unless defined $raw;
  die "package_repositories muss ein Array sein" unless ref($raw) eq 'ARRAY';
  my @out;
  for my $r (@$raw) {
    die "package_repositories enthaelt einen ungueltigen Eintrag" unless ref($r) eq 'HASH';
    _known_keys_or_throw($r, [qw(id url local_path gpg_check refresh)], 'package_repositories');
    my $id = $r->{id}//''; my $url=$r->{url}//''; my $local=$r->{local_path}//'';
    die "package_repositories.id ist ungueltig" unless $id =~ /\A[A-Za-z0-9._-]{1,64}\z/;
    die "package_repositories.url muss https:// verwenden" if length($url) && $url !~ m{\Ahttps://}i;
    die "package_repositories benoetigt url oder local_path" unless length($url) || length($local);
    die "package_repositories.local_path muss absolut sein" if length($local) && $local !~ m{\A/};
    push @out, {
      id=>$id, url=>$url, local_path=>$local,
      gpg_check=>(exists($r->{gpg_check}) ? _json_bool_or_throw($r->{gpg_check}, 'package_repositories.gpg_check') : 0),
      refresh=>(exists($r->{refresh}) ? _json_bool_or_throw($r->{refresh}, 'package_repositories.refresh') : 1),
    };
  }
  return \@out;
}

sub _normalize_packages {
  my ($raw) = @_;
  return [] unless defined $raw;
  die "packages muss ein Array sein" unless ref($raw) eq 'ARRAY';
  my @out;
  for my $item (@$raw) {
    my $p = !ref($item) ? {name=>"$item", state=>'present'} : $item;
    die "packages enthaelt einen ungueltigen Eintrag" unless ref($p) eq 'HASH';
    _known_keys_or_throw($p, [qw(name state version)], 'packages');
    my $name=$p->{name}//''; my $state=lc($p->{state}//'present'); my $version=$p->{version}//'';
    die "packages.name ist ungueltig" unless $name =~ /\A[A-Za-z0-9][A-Za-z0-9+_.:@-]{0,127}\z/;
    die "packages.state muss present oder latest sein" unless $state eq 'present' || $state eq 'latest';
    die "packages.version ist ungueltig" if length($version) && $version !~ /\A[A-Za-z0-9][A-Za-z0-9+_.:~^-]{0,127}\z/;
    push @out,{name=>$name,state=>$state,(length($version)?(version=>$version):())};
  }
  return \@out;
}

sub _load_repository_package_plan {
  my ($cache_dir, $commit, $profile, $secrets) = @_;
  return undef unless $profile->{allow_repository_package_plan};
  my $res = eval {
    _deploy_run_command(
      stage=>'repo_package_manifest',
      argv=>[$git_bin, "--git-dir=$cache_dir", 'show', "$commit:deploy-profile.json"],
      timeout=>30, env=>_git_base_env(), secrets=>$secrets,
    );
  };
  return undef if $@ || !defined($res) || !defined($res->{stdout}) || $res->{stdout} eq '';
  my $doc = eval { decode_json($res->{stdout}) };
  _deploy_throw('repo_package_manifest', 'deploy-profile.json ist kein gueltiges JSON-Objekt')
    if $@ || ref($doc) ne 'HASH';
  my %allowed = map { $_=>1 } qw(schema_version id description package_repositories packages);
  for my $k (keys %$doc) {
    _deploy_throw('repo_package_manifest', "deploy-profile.json enthaelt unerlaubtes Feld: $k") unless $allowed{$k};
  }
  if (defined($doc->{id}) && length($doc->{id}) && $doc->{id} ne ($profile->{id}//$doc->{id})) {
    _deploy_throw('repo_package_manifest', 'deploy-profile.json id passt nicht zum Deploy-Profil');
  }
  my $repos = _normalize_package_repositories($doc->{package_repositories});
  my $pkgs  = _normalize_packages($doc->{packages});
  _deploy_throw('repo_package_manifest', 'deploy-profile.json enthaelt keinen Paketplan')
    unless @$repos || @$pkgs;
  $profile->{package_repositories} = $repos;
  $profile->{packages} = $pkgs;
  return {source=>'repository:deploy-profile.json', package_repositories=>$repos, packages=>$pkgs};
}

sub _run_package_plan {
  my ($profile, $secrets) = @_;
  my $repos=$profile->{package_repositories}; my $packages=$profile->{packages};
  return undef unless (ref($repos) eq 'ARRAY' && @$repos) || (ref($packages) eq 'ARRAY' && @$packages);
  die "PackageMgmt ist nicht geladen" unless defined &_pkg_read_os && defined &_pkg_execute;
  my $os=_pkg_read_os();
  my @repo_results;
  if (ref($repos) eq 'ARRAY' && @$repos) {
    _deploy_throw('packages', 'package_repositories werden derzeit nur fuer zypper/SLES/openSUSE unterstuetzt')
      unless ($os->{manager}//'') eq 'zypper';
    for my $r (@$repos) {
      my $url=$r->{url}//'';
      if (($r->{local_path}//'') ne '' && -f "$r->{local_path}/repodata/repomd.xml") {
        $url='file://'.$r->{local_path}; $url.='/' unless $url =~ m{/$};
      }
      _deploy_throw('packages', "Repository-URL fehlt fuer $r->{id}") unless length($url);
      _pkg_run('zypper','--non-interactive','removerepo',$r->{id});
      my @add=('zypper','--non-interactive','addrepo');
      push @add,'-G' unless $r->{gpg_check};
      push @add,'--check'; push @add,'--refresh' if $r->{refresh};
      push @add,$url,$r->{id};
      my($arc,$aout)=_pkg_run(@add);
      _deploy_throw('packages', "Repository $r->{id} konnte nicht eingerichtet werden: $aout") if $arc;
      if ($r->{refresh}) {
        my($rrc,$rout)=_pkg_run('zypper','--non-interactive','refresh',$r->{id});
        _deploy_throw('packages', "Repository $r->{id} konnte nicht aktualisiert werden: $rout") if $rrc;
      }
      push @repo_results,{id=>$r->{id},url=>$url,ok=>true()};
    }
  }
  my @pkg_results;
  for my $p (@{ref($packages) eq 'ARRAY' ? $packages : []}) {
    my $before=_pkg_check($os,$p->{name});
    my $action = $p->{state} eq 'latest' && $before->{installed} ? 'upgrade' : 'install';
    if ($p->{state} eq 'present' && $before->{installed} && (!defined($p->{version}) || !length($p->{version}) || ($before->{version}//'') eq $p->{version})) {
      push @pkg_results,{name=>$p->{name},state=>$p->{state},version=>$before->{version}//'',changed=>false(),ok=>true()};
      next;
    }
    my $res=eval{_pkg_execute({action=>$action,package=>$p->{name},(defined($p->{version})?(version=>$p->{version}):())})};
    _deploy_throw('packages', "Paket $p->{name} konnte nicht installiert werden: $@") if $@;
    _deploy_throw('packages', "Paket $p->{name} konnte nicht installiert werden: ".($res->{output}//'')) unless $res->{ok};
    push @pkg_results,{name=>$p->{name},state=>$p->{state},version=>$res->{after}{version}//'',changed=>true(),ok=>true()};
  }
  return {ok=>true(),repositories=>\@repo_results,packages=>\@pkg_results};
}

sub _normalize_deploy_profile {
  my ($id, $raw) = @_;
  die "Profil $id muss ein JSON-Objekt sein" unless ref($raw) eq 'HASH';
  my %p = %$raw;
  my $simple = exists($p{repository}) || exists($p{branch}) || exists($p{tag}) ||
    exists($p{ref}) || exists($p{target}) || exists($p{owner}) ||
    exists($p{service}) || exists($p{preserve}) || exists($p{post_deploy}) || exists($p{packages}) || exists($p{package_repositories}) || exists($p{allow_repository_package_plan}) ||
    exists($p{install}) || (($p{format}//'') eq 'simple');

  if (ref($p{advanced}) eq 'HASH') {
    for my $key (keys %{$p{advanced}}) {
      $p{$key} = $p{advanced}{$key} unless exists $p{$key};
    }
  }

  $p{git_url} = $p{repository} if !exists($p{git_url}) && defined($p{repository});
  $p{target_path} = $p{target} if !exists($p{target_path}) && defined($p{target});
  $p{user} = $p{owner} if !exists($p{user}) && defined($p{owner});
  $p{restart_service} = $p{service} if !exists($p{restart_service}) && defined($p{service});

  if (!exists($p{allowed_ref})) {
    if (defined($p{branch}) && !ref($p{branch}) && length($p{branch})) {
      $p{allowed_ref} = $p{branch} =~ m{^refs/} ? $p{branch} : "refs/heads/$p{branch}";
    } elsif (defined($p{tag}) && !ref($p{tag}) && length($p{tag})) {
      $p{allowed_ref} = $p{tag} =~ m{^refs/} ? $p{tag} : "refs/tags/$p{tag}";
    } elsif (defined($p{ref}) && !ref($p{ref}) && length($p{ref})) {
      $p{allowed_ref} = $p{ref} =~ m{^refs/} ? $p{ref} : "refs/heads/$p{ref}";
    }
  }

  if (!exists($p{preserve_paths}) && exists($p{preserve})) {
    $p{preserve_paths} = _normalize_simple_preserve($p{preserve});
  }

  if (ref($p{preflight}) eq 'ARRAY') {
    $p{preflight} = {argv=>$p{preflight}, cwd=>'{release}', timeout=>30};
  }

  $p{post_deploy} = delete($p{install}) if !exists($p{post_deploy}) && exists($p{install});
  $p{post_deploy} = _normalize_post_deploy($p{post_deploy}) if exists $p{post_deploy};
  $p{package_repositories} = _normalize_package_repositories($p{package_repositories}) if exists $p{package_repositories};
  $p{packages} = _normalize_packages($p{packages}) if exists $p{packages};
  $p{allow_repository_package_plan} = _json_bool_or_throw($p{allow_repository_package_plan}, 'allow_repository_package_plan') if exists $p{allow_repository_package_plan};

  $p{enabled} = 1 unless exists $p{enabled};
  $p{deploy_mode} = 'directory_swap' if $simple && !exists($p{deploy_mode});
  if ($simple && !exists($p{ref_policy}) && defined($p{allowed_ref})) {
    $p{ref_policy} = $p{allowed_ref} =~ m{^refs/tags/} ? 'exact' : 'ancestor';
  }

  if (($p{deploy_mode}//'') eq 'directory_swap' &&
      (!defined($p{releases_dir}) || !length($p{releases_dir}//'')) &&
      defined($p{target_path}) && !ref($p{target_path}) && $p{target_path} =~ m{^/}) {
    my $parent = path($p{target_path})->dirname->to_string;
    $p{releases_dir} = "$parent/.git-deploy/$id/releases";
  }

  delete @p{qw(repository branch tag ref target owner service preserve install advanced format)};
  return \%p;
}

sub _git_profiles_only_or_die {
  my ($cfg) = @_;
  die "git_deploy.json muss ein JSON-Objekt enthalten" unless ref($cfg) eq 'HASH';
  my %allowed = map { $_=>1 } qw(schema_version profiles);
  for my $key (keys %$cfg) {
    die "git_deploy.json: Allgemeine Einstellung '$key' gehoert in global.json unter git_deploy"
      unless $allowed{$key};
  }
  die "git_deploy.json: profiles muss ein JSON-Objekt sein"
    if exists($cfg->{profiles}) && ref($cfg->{profiles}) ne 'HASH';
  if (exists $cfg->{schema_version}) {
    die "git_deploy.json: schema_version muss 1 oder 2 sein"
      unless defined($cfg->{schema_version}) && !ref($cfg->{schema_version}) &&
             "$cfg->{schema_version}" =~ /^\d+$/ &&
             ($cfg->{schema_version} == 1 || $cfg->{schema_version} == 2);
  }
  return {
    (exists($cfg->{schema_version}) ? (schema_version=>$cfg->{schema_version}) : ()),
    profiles => (ref($cfg->{profiles}) eq 'HASH' ? $cfg->{profiles} : {}),
  };
}

sub _compose_git_config {
  my ($settings, $profiles_cfg) = @_;
  die "interner Fehler: Git-Einstellungen fehlen" unless ref($settings) eq 'HASH';
  die "interner Fehler: Git-Profile fehlen" unless ref($profiles_cfg) eq 'HASH';
  return {%$settings, profiles=>(ref($profiles_cfg->{profiles}) eq 'HASH' ? $profiles_cfg->{profiles} : {})};
}

sub _apply_git_config_hash {
  my ($cfg, $digest) = @_;
  die "effektive Git-Konfiguration muss ein JSON-Objekt enthalten" unless ref($cfg) eq 'HASH';

  $git_cfg = $cfg;
  $git_deploy_enabled = $cfg->{enabled} ? 1 : 0;
  $git_allow_direct_request = $cfg->{allow_direct_request} ? 1 : 0;
  $git_require_api_token = exists $cfg->{require_api_token} ? ($cfg->{require_api_token} ? 1 : 0) : 1;
  $git_require_ip_acl = exists $cfg->{require_ip_acl} ? ($cfg->{require_ip_acl} ? 1 : 0) : 1;
  $git_require_guard_enforce = exists $cfg->{require_path_guard_enforce}
    ? ($cfg->{require_path_guard_enforce} ? 1 : 0) : 1;
  $git_require_allowed_ref = exists $cfg->{require_allowed_ref}
    ? ($cfg->{require_allowed_ref} ? 1 : 0) : 1;
  $git_allow_proxy_env = $cfg->{allow_proxy_env} ? 1 : 0;
  $git_allow_http = $cfg->{allow_http} ? 1 : 0;
  $git_verify_tls = exists($cfg->{verify_tls}) ? ($cfg->{verify_tls} ? 1 : 0) : 1;
  $git_deploy_token_source = lc($cfg->{deploy_token_source} // 'file');
  $git_deploy_token_file = $cfg->{deploy_token_file} // '/opt/service/env/forgejo-api.token';
  $git_bin = $cfg->{git_bin} // '/usr/bin/git';
  $tar_bin = $cfg->{tar_bin} // '/bin/tar';
  $mv_bin = $cfg->{mv_bin} // '/usr/bin/mv';
  $git_state_dir = $cfg->{state_dir} // "$tmpDir/git-deploy";
  $git_cache_root = "$git_state_dir/cache";
  $git_status_root = "$git_state_dir/status";
  $git_home_dir = "$git_state_dir/home";
  $git_timeout = (defined $cfg->{timeout} && $cfg->{timeout} =~ /^\d+$/)
    ? 0 + $cfg->{timeout} : DEFAULT_GIT_TIMEOUT;
  $git_default_keep_releases = (defined $cfg->{keep_releases} && $cfg->{keep_releases} =~ /^\d+$/)
    ? 0 + $cfg->{keep_releases} : DEFAULT_GIT_KEEP_RELEASES;
  $git_default_keep_releases = 2 if $git_default_keep_releases < 2;
  $git_default_max_files = (defined $cfg->{max_files} && $cfg->{max_files} =~ /^\d+$/)
    ? 0 + $cfg->{max_files} : DEFAULT_GIT_MAX_FILES;
  $git_default_max_bytes = (defined $cfg->{max_bytes} && $cfg->{max_bytes} =~ /^\d+$/)
    ? 0 + $cfg->{max_bytes} : DEFAULT_GIT_MAX_BYTES;
  $git_default_deploy_user = $cfg->{deploy_user};
  $git_default_auth_scheme = lc($cfg->{auth_scheme} // 'basic');
  $git_default_ca_info = $cfg->{ca_info};
  $git_allowed_hosts = ref($cfg->{allowed_git_hosts}) eq 'ARRAY' ? $cfg->{allowed_git_hosts} : [];
  my $raw_profiles = ref($cfg->{profiles}) eq 'HASH' ? $cfg->{profiles} : {};
  my %normalized_profiles;
  for my $id (keys %$raw_profiles) {
    $normalized_profiles{$id} = _normalize_deploy_profile($id, $raw_profiles->{$id});
  }
  $git_profiles_raw = \%normalized_profiles;

  $git_path_guard = lc($ENV{GIT_PATH_GUARD} // ($cfg->{path_guard} // 'off'));
  $git_path_guard = 'off' unless $git_path_guard =~ /^(?:off|audit|enforce)$/;
  $GIT_ALLOWED = [];
  if (ref($cfg->{allowed_roots}) eq 'ARRAY') {
    for my $root (@{$cfg->{allowed_roots}}) {
      next unless defined $root && !ref($root) && length $root;
      my $rr = eval { path($root)->realpath->to_string };
      next unless defined $rr && -d $rr;
      $rr =~ s{/+$}{} unless $rr eq '/';
      push @$GIT_ALLOWED, $rr;
    }
  }
  $digest = sha256_hex(encode_json($cfg)) unless defined($digest) && length($digest);
  if ($digest ne $git_config_digest) {
    $git_config_digest = $digest;
    $git_config_generation++;
  }
  return 1;
}

sub _set_git_config_degraded {
  my ($message, $source, $settings, $profiles_cfg, $settings_digest, $profiles_digest) = @_;
  $message = 'Unbekannter Fehler in der Git-Konfiguration' unless defined($message) && length($message);
  $message =~ s/[\r\n]+/ /g;
  $source = 'combined' unless defined($source) && length($source);
  $settings = {} unless ref($settings) eq 'HASH';
  $profiles_cfg = {profiles=>{}} unless ref($profiles_cfg) eq 'HASH';
  $settings_digest //= sha256_hex(encode_json($settings));
  $profiles_digest //= sha256_hex(encode_json($profiles_cfg));
  my $digest = sha256_hex(join("\0", 'invalid', $source, $message, $settings_digest, $profiles_digest));

  my $changed = $git_config_valid || $git_config_error ne $message || $git_config_digest ne $digest;
  _apply_git_config_hash({enabled=>false, profiles=>{}}, $digest);
  $git_settings_cfg = $settings;
  $git_profiles_cfg = $profiles_cfg;
  $git_settings_digest = $settings_digest;
  $git_profiles_digest = $profiles_digest;
  $git_config_valid = 0;
  $git_config_error = $message;
  $git_settings_error = $source eq 'settings' ? $message : '';
  $git_profiles_error = $source eq 'profiles' ? $message : '';

  $logger->error("GIT_CONFIG degraded source=$source error=$message") if $changed;
  return {exists=>$git_config_exists, enabled=>0, valid=>0, degraded=>1, source=>$source, error=>$message};
}

sub _load_git_configuration {
  my ($settings, $profiles_cfg, $settings_digest, $profiles_digest);

  my $settings_ok = eval {
    $settings = _git_settings_from_global();
    $settings_digest = sha256_hex(encode_json($settings));
    1;
  };
  unless ($settings_ok) {
    my $msg = $@ || 'Git-Einstellungen in global.json sind ungueltig';
    return _set_git_config_degraded($msg, 'settings', {}, {profiles=>{}}, 'invalid-settings', 'unknown');
  }

  if (!-e $gitfile) {
    $git_config_exists = 0;
    $profiles_cfg = {schema_version=>1, profiles=>{}};
    $profiles_digest = 'missing';
  } elsif (-l $gitfile) {
    $git_config_exists = 1;
    return _set_git_config_degraded("git_deploy.json darf kein Symlink sein: $gitfile", 'profiles', $settings, {profiles=>{}}, $settings_digest, 'invalid-symlink');
  } elsif (!-f $gitfile) {
    $git_config_exists = 1;
    return _set_git_config_degraded("git_deploy.json ist keine regulaere Datei: $gitfile", 'profiles', $settings, {profiles=>{}}, $settings_digest, 'invalid-filetype');
  } else {
    $git_config_exists = 1;
    my $raw = eval { read_all($gitfile) };
    if ($@) {
      my $msg = $@; $msg =~ s/[\r\n]+/ /g;
      return _set_git_config_degraded("git_deploy.json konnte nicht gelesen werden: $msg", 'profiles', $settings, {profiles=>{}}, $settings_digest, 'invalid-read');
    }
    $profiles_digest = sha256_hex($raw);
    my $decoded = eval { decode_json($raw) };
    if ($@ || ref($decoded) ne 'HASH') {
      my $msg = $@ || 'Wurzelelement muss ein JSON-Objekt sein'; $msg =~ s/[\r\n]+/ /g;
      return _set_git_config_degraded("git_deploy.json JSON-Syntaxfehler: $msg", 'profiles', $settings, {profiles=>{}}, $settings_digest, $profiles_digest);
    }
    my $profiles_ok = eval { $profiles_cfg = _git_profiles_only_or_die($decoded); 1 };
    unless ($profiles_ok) {
      my $msg = $@ || 'git_deploy.json ist ungueltig'; $msg =~ s/[\r\n]+/ /g;
      return _set_git_config_degraded($msg, 'profiles', $settings, {profiles=>{}}, $settings_digest, $profiles_digest);
    }
  }

  my $combined = _compose_git_config($settings, $profiles_cfg);
  my $valid = eval { _validate_git_config_hash($combined); 1 };
  unless ($valid) {
    my $e = _deploy_error_hash($@);
    my $source = ($e->{message} // '') =~ /^Profil\s/ ? 'profiles' : 'settings';
    return _set_git_config_degraded($e->{message}, $source, $settings, $profiles_cfg, $settings_digest, $profiles_digest);
  }

  my $was_invalid = !$git_config_valid;
  my $digest = sha256_hex(join("\0", $settings_digest, $profiles_digest));
  _apply_git_config_hash($combined, $digest);
  $git_settings_cfg = $settings;
  $git_profiles_cfg = $profiles_cfg;
  $git_settings_digest = $settings_digest;
  $git_profiles_digest = $profiles_digest;
  $git_config_valid = 1;
  $git_config_error = '';
  $git_settings_error = '';
  $git_profiles_error = '';
  $logger->info("GIT_CONFIG recovered generation=$git_config_generation") if $was_invalid;
  return {
    exists=>$git_config_exists, enabled=>$git_deploy_enabled, valid=>1,
    degraded=>0, generation=>$git_config_generation,
  };
}

# Git-Deploy ist optional. Kein Fehler beim initialen Laden der Git-
# Konfiguration darf den allgemeinen Config-Agenten am Start hindern. Die
# erwarteten JSON-/Schemafehler werden bereits in _load_git_configuration()
# in den Degraded Mode ueberfuehrt; dieser aeussere Schutz faengt zusaetzlich
# unerwartete Laufzeitfehler des optionalen Git-Moduls ab.
my $git_startup_ok = eval { _load_git_configuration(); 1 };
unless ($git_startup_ok) {
  my $msg = $@ || 'Unbekannter Fehler beim Initialisieren des Git-Moduls';
  $msg = "$msg";
  $msg =~ s/[\r\n]+/ /g;
  $git_cfg = {enabled=>false, profiles=>{}};
  $git_deploy_enabled = 0;
  $git_profiles_raw = {};
  $git_config_valid = 0;
  $git_config_error = "Git-Modul konnte nicht initialisiert werden: $msg";
  $git_settings_error = '';
  $git_profiles_error = $git_config_error;
  $logger->error("GIT_CONFIG degraded source=startup error=$git_config_error");
}


# ==================================================
# Git-Pull-Deploy: Hilfsfunktionen
# ==================================================
sub _deploy_throw {
  my ($stage, $message, $extra) = @_;
  $extra = {} unless ref($extra) eq 'HASH';
  die bless({ stage => ($stage // 'unknown'), message => ($message // 'Deploy fehlgeschlagen'), %$extra }, 'GitDeployError');
}

sub _deploy_error_hash {
  my ($exc) = @_;
  my $out = ref($exc) eq 'GitDeployError' ? {%$exc} : {stage=>'internal'};
  my $msg = ref($exc) eq 'GitDeployError'
    ? ($out->{message} // 'Deploy fehlgeschlagen')
    : (ref($exc) ? "$exc" : ($exc // 'unbekannter Fehler'));
  $msg =~ s/\s+\z//;
  # Perl haengt bei die() automatisch Quellpfad und Zeilennummer an. Fuer die
  # API ist die eigentliche Fehlermeldung ausreichend; interne Details bleiben
  # ueber Stage und strukturiertes Agent-Logging nachvollziehbar.
  $msg =~ s/\s+at \S+ line \d+\.?\z//;
  $out->{message} = $msg;
  return $out;
}

sub _safe_deploy_id {
  my ($id) = @_;
  return defined($id) && !ref($id) && $id =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
}

sub _normalize_abs_lexical {
  my ($p) = @_;
  die "Pfad fehlt" unless defined $p && !ref($p) && length $p;
  die "Pfad muss absolut sein: $p" unless $p =~ m{^/};
  die "NUL im Pfad" if $p =~ /\0/;

  my @out;
  for my $part (split m{/+}, $p) {
    next if $part eq '' || $part eq '.';
    if ($part eq '..') {
      die "Pfad verlaesst Root: $p" unless @out;
      pop @out;
      next;
    }
    push @out, $part;
  }
  return '/' . join('/', @out);
}

sub _path_is_within {
  my ($candidate, $root) = @_;
  $candidate = _normalize_abs_lexical($candidate);
  $root      = _normalize_abs_lexical($root);
  return 1 if $root eq '/';
  return 1 if $candidate eq $root;
  return index($candidate, "$root/") == 0 ? 1 : 0;
}

sub _allowed_root_for_path {
  my ($candidate) = @_;
  my $norm = _normalize_abs_lexical($candidate);
  for my $root (@$GIT_ALLOWED) {
    return $root if _path_is_within($norm, $root);
  }
  return undef;
}

sub _assert_deploy_path_allowed {
  my ($candidate, $label, $allow_final_symlink, $allow_missing_parent) = @_;
  $label //= 'Pfad';
  my $norm = _normalize_abs_lexical($candidate);
  _deploy_throw('validation', "$label darf nicht / sein") if $norm eq '/';

  if ($git_require_guard_enforce) {
    _deploy_throw('validation', 'git_deploy erfordert path_guard=enforce in global.json unter git_deploy') unless $git_path_guard eq 'enforce';
    _deploy_throw('validation', 'git_deploy erfordert mindestens einen gueltigen allowed_roots-Eintrag in global.json unter git_deploy') unless @$GIT_ALLOWED;
  }

  my $parent = path($norm)->dirname->to_string;

  if ($allow_missing_parent) {
    # Fehlende Unterverzeichnisse duerfen automatisch erzeugt werden, aber nur
    # innerhalb eines erlaubten Roots und ohne vorhandene Symlink-Komponenten.
    _deploy_throw('validation', "$label liegt nicht unter allowed_roots: $norm")
      if @$GIT_ALLOWED && !_allowed_root_for_path($norm);

    _assert_no_symlink_components($parent, 1);

    my $ancestor = $parent;
    while (!-e $ancestor && !-l $ancestor) {
      my $next = path($ancestor)->dirname->to_string;
      _deploy_throw('validation', "$label: Kein existierendes Parent-Verzeichnis gefunden: $parent")
        if !defined($next) || $next eq $ancestor;
      $ancestor = $next;
    }

    _deploy_throw('validation', "$label: Naechster existierender Parent ist kein regulaeres Verzeichnis: $ancestor")
      unless -d $ancestor && !-l $ancestor;

    my $ancestor_real = eval { path($ancestor)->realpath->to_string };
    _deploy_throw('validation', "$label: Parent-Verzeichnis ist nicht aufloesbar: $ancestor")
      unless defined $ancestor_real && -d $ancestor_real;

    _deploy_throw('validation', "$label: Existierender Parent liegt nicht unter allowed_roots: $ancestor_real")
      if @$GIT_ALLOWED && !_allowed_root_for_path($ancestor_real);
  } else {
    my $parent_real = eval { path($parent)->realpath->to_string };
    _deploy_throw('validation', "$label: Parent-Verzeichnis fehlt oder ist nicht aufloesbar: $parent")
      unless defined $parent_real && -d $parent_real;

    my $base = path($norm)->basename;
    my $resolved_candidate = $parent_real eq '/' ? "/$base" : "$parent_real/$base";
    if (@$GIT_ALLOWED && !_allowed_root_for_path($resolved_candidate)) {
      _deploy_throw('validation', "$label liegt nicht unter allowed_roots: $norm");
    }
  }

  if (-l $norm && !$allow_final_symlink) {
    _deploy_throw('validation', "$label darf kein Symlink sein: $norm");
  }
  return $norm;
}

sub _assert_no_symlink_components {
  my ($candidate, $include_final) = @_;
  my $norm = _normalize_abs_lexical($candidate);
  my @parts = grep { length } split m{/+}, $norm;
  pop @parts unless $include_final;
  my $cur = '';
  for my $part (@parts) {
    $cur .= "/$part";
    next unless -e $cur || -l $cur;
    _deploy_throw('validation', "Symlink-Komponente im verwalteten Pfad verboten: $cur") if -l $cur;
  }
  return 1;
}

sub _ensure_managed_dir {
  my ($dir, $mode) = @_;
  $mode //= 0770;
  my $norm = _normalize_abs_lexical($dir);
  _assert_no_symlink_components(path($norm)->dirname->to_string, 1);
  if (!-d $norm) {
    my $err;
    make_path($norm, {mode => $mode, error => \$err});
    if ($err && @$err) {
      my @m = map { my ($f,$e) = %$_; "$f: $e" } @$err;
      _deploy_throw('filesystem', "Verzeichnis konnte nicht angelegt werden: " . join('; ', @m));
    }
  }
  _deploy_throw('filesystem', "Verzeichnis fehlt nach make_path: $norm") unless -d $norm;
  _deploy_throw('filesystem', "Verzeichnis ist ein Symlink: $norm") if -l $norm;
  chmod($mode, $norm) or _deploy_throw('filesystem', "chmod($norm) fehlgeschlagen: $!");
  return $norm;
}

sub _with_named_locks {
  my ($keys, $code) = @_;
  die "Lock-Keys muessen ein Array sein" unless ref($keys) eq 'ARRAY' && @$keys;
  die "Callback fehlt" unless ref($code) eq 'CODE';

  my %seen;
  my @lockfiles = sort map { "$tmpDir/config-manager-" . sha256_hex($_) . ".lock" }
                       grep { defined($_) && length($_) && !$seen{$_}++ } @$keys;
  my @handles;
  my $deadline = time() + $lockTimeoutS;

  eval {
    for my $lockfile (@lockfiles) {
      sysopen(my $lfh, $lockfile, O_RDWR | O_CREAT, 0660)
        or die "Kann Lockdatei $lockfile nicht oeffnen: $!";
      chmod(0660, $lockfile)
        or die "Kann Rechte der Lockdatei $lockfile nicht setzen: $!";
      my $locked = 0;
      while (time() < $deadline) {
        if (flock($lfh, LOCK_EX | LOCK_NB)) {
          $locked = 1;
          last;
        }
        sleep 0.05;
      }
      die sprintf("flock(%s) Timeout nach %.1fs", $lockfile, $lockTimeoutS) unless $locked;
      push @handles, $lfh;
    }
    1;
  } or do {
    my $err = $@;
    for my $fh (reverse @handles) { flock($fh, LOCK_UN); close $fh; }
    die $err;
  };

  my ($wantarray, @ret, $ret, $ok, $err);
  $wantarray = wantarray;
  if ($wantarray) {
    $ok = eval { @ret = $code->(); 1 };
  } elsif (defined $wantarray) {
    $ok = eval { $ret = $code->(); 1 };
  } else {
    $ok = eval { $code->(); 1 };
  }
  $err = $@ unless $ok;

  for my $fh (reverse @handles) { flock($fh, LOCK_UN); close $fh; }
  die $err unless $ok;
  return $wantarray ? @ret : defined($wantarray) ? $ret : undef;
}

sub _parse_git_url_or_throw {
  my ($url) = @_;
  _deploy_throw('validation', 'git_url fehlt') unless defined $url && !ref($url) && length $url;
  _deploy_throw('validation', 'git_url enthaelt Steuerzeichen') if $url =~ /[\x00-\x1f\x7f]/;

  my $u = eval { Mojo::URL->new($url) };
  _deploy_throw('validation', 'git_url ist ungueltig') unless $u;
  my $scheme = lc($u->scheme // '');
  _deploy_throw('validation', 'git_url muss HTTPS verwenden; HTTP ist nur mit allow_http=true erlaubt')
    unless $scheme eq 'https' || ($scheme eq 'http' && $git_allow_http);
  _deploy_throw('validation', 'Benutzername/Passwort in git_url sind verboten')
    if defined($u->userinfo) && length($u->userinfo // '');
  _deploy_throw('validation', 'Query-String in git_url ist verboten')
    if length($u->query->to_string // '');
  _deploy_throw('validation', 'Fragment in git_url ist verboten')
    if defined($u->fragment) && length($u->fragment // '');

  my $host = lc($u->host // '');
  _deploy_throw('validation', 'git_url Host fehlt') unless length $host;
  _deploy_throw('validation', 'git_url Host ist ungueltig') unless $host =~ /^[A-Za-z0-9.-]+$/;
  my $port = $u->port // ($scheme eq 'http' ? 80 : 443);
  _deploy_throw('validation', 'git_url Port ist ungueltig') unless "$port" =~ /^\d+$/ && $port >= 1 && $port <= 65535;
  my $repo_path = $u->path->to_string // '';
  _deploy_throw('validation', 'git_url Repository-Pfad fehlt') unless $repo_path =~ m{^/[^\s]+$};
  _deploy_throw('validation', 'Backslash in git_url ist verboten') if $repo_path =~ /\\/;

  my $hostport = "$host:$port";
  my %allowed;
  for my $entry (@$git_allowed_hosts) {
    next unless defined $entry && !ref($entry) && length $entry;
    my $x = lc($entry);
    $x =~ s{^https?://}{};
    $x =~ s{/$}{};
    $x .= ':443' unless $x =~ /:\d+$/;
    $allowed{$x} = 1;
  }
  _deploy_throw('validation', 'allowed_git_hosts ist leer; Git-Deploy bleibt fail-closed') unless %allowed;
  _deploy_throw('validation', "Git-Host nicht erlaubt: $hostport") unless $allowed{$hostport};
  return ($url, $host, 0 + $port);
}

sub _validate_restart_service_or_throw {
  my ($svc) = @_;
  return undef unless defined $svc && length $svc;
  _deploy_throw('validation', 'restart_service muss ein String sein') if ref($svc);
  _deploy_throw('validation', 'Nur explizite .service-Units sind fuer Git-Deploy erlaubt')
    unless $svc =~ /^[A-Za-z0-9_.\@:-]+\.service$/ && length($svc) <= 255;
  my %deny = map { $_ => 1 } qw(
    poweroff.service reboot.service halt.service kexec.service rescue.service
    emergency.service systemd-poweroff.service systemd-reboot.service
  );
  _deploy_throw('validation', "Service ist verboten: $svc") if $deny{$svc};
  return $svc;
}

sub _git_base_env {
  # Alle geerbten GIT_*-Variablen entfernen, damit weder ein fremdes
  # GIT_DIR/GIT_WORK_TREE noch eingeschleuste GIT_CONFIG_KEY_n wirken kann.
  my %env = map { $_ => undef } grep { /^GIT_/ } keys %ENV;
  %env = (%env,
    GIT_TERMINAL_PROMPT => '0',
    GIT_ASKPASS         => '/bin/false',
    SSH_ASKPASS         => '/bin/false',
    GIT_CONFIG_NOSYSTEM => '1',
    GIT_CONFIG_GLOBAL   => '/dev/null',
    HOME                => $git_home_dir,
    LANG                => 'C',
    LC_ALL              => 'C',
  );
  unless ($git_allow_proxy_env) {
    for my $k (qw(http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY)) {
      $env{$k} = undef;
    }
  }
  return \%env;
}

sub _read_deploy_token_file {
  my $file = $git_deploy_token_file;
  _deploy_throw('validation', 'deploy_token_file muss ein absoluter Pfad sein')
    unless defined($file) && !ref($file) && $file =~ m{^/} && $file !~ /\\0/;
  _deploy_throw('validation', "Deploy-Token-Datei fehlt oder ist nicht lesbar: $file")
    unless -f $file && -r $file && !-l $file;

  my @st = stat($file);
  _deploy_throw('validation', "Deploy-Token-Datei kann nicht geprueft werden: $file") unless @st;
  my $mode = S_IMODE($st[2]);
  _deploy_throw('validation', sprintf('Deploy-Token-Datei muss vor Gruppe/Anderen geschuetzt sein: %s (Modus %04o)', $file, $mode))
    if $mode & 0077;

  my $token = read_all($file);
  $token =~ s/[\r\n]+\z//;
  _deploy_throw('validation', 'Gespeichertes Deploy-Token ist leer') unless length($token);
  _deploy_throw('validation', 'Gespeichertes Deploy-Token ist zu lang') if length($token) > 4096;
  _deploy_throw('validation', 'Gespeichertes Deploy-Token muss aus sichtbaren ASCII-Zeichen ohne Leerzeichen bestehen')
    unless $token =~ /^[\x21-\x7e]+$/;
  return $token;
}

sub _git_env_with_auth {
  my ($profile, $token) = @_;
  _deploy_throw('validation', 'deploy_token fehlt') unless defined $token && !ref($token) && length $token;
  _deploy_throw('validation', 'deploy_token ist zu lang') if length($token) > 4096;
  _deploy_throw('validation', 'deploy_token muss aus sichtbaren ASCII-Zeichen ohne Leerzeichen bestehen')
    unless $token =~ /^[\x21-\x7e]+$/;

  my $scheme = lc($profile->{auth_scheme} // $git_default_auth_scheme // 'basic');
  my $header;
  my @secrets = ($token);
  if ($scheme eq 'basic') {
    my $user = $profile->{deploy_user} // $git_default_deploy_user;
    _deploy_throw('validation', 'deploy_user fehlt fuer auth_scheme=basic')
      unless defined $user && !ref($user) && $user =~ /^[A-Za-z0-9_.\@+-]{1,128}$/;
    my $encoded = encode_base64("$user:$token", '');
    $header = "Authorization: Basic $encoded";
    push @secrets, $encoded;
  } elsif ($scheme eq 'bearer') {
    $header = "Authorization: Bearer $token";
  } elsif ($scheme eq 'token') {
    $header = "Authorization: token $token";
  } else {
    _deploy_throw('validation', "Unbekanntes auth_scheme: $scheme");
  }

  my @pairs = (
    ['core.hooksPath', '/dev/null'],
    ['credential.helper', ''],
    ['protocol.file.allow', 'never'],
    ['protocol.ext.allow', 'never'],
    ['fetch.fsckObjects', 'true'],
    ['transfer.fsckObjects', 'true'],
    ['http.followRedirects', 'false'],
    ['http.sslVerify', ($git_verify_tls ? 'true' : 'false')],
    ['http.extraHeader', $header],
  );
  my $ca = $profile->{ca_info} // $git_default_ca_info;
  if (defined $ca && length $ca) {
    _deploy_throw('validation', 'ca_info muss absolut sein') unless !ref($ca) && $ca =~ m{^/};
    _deploy_throw('validation', "ca_info nicht lesbar: $ca") unless -f $ca && -r $ca && !-l $ca;
    push @pairs, ['http.sslCAInfo', $ca];
  }

  my $env = _git_base_env();
  $env->{GIT_CONFIG_COUNT} = scalar @pairs;
  for my $i (0 .. $#pairs) {
    $env->{"GIT_CONFIG_KEY_$i"}   = $pairs[$i][0];
    $env->{"GIT_CONFIG_VALUE_$i"} = $pairs[$i][1];
  }
  return ($env, \@secrets);
}

sub _redact_secrets {
  my ($text, $secrets) = @_;
  $text = '' unless defined $text;
  if (ref($secrets) eq 'ARRAY') {
    for my $secret (@$secrets) {
      next unless defined $secret && length $secret;
      $text =~ s/\Q$secret\E/[REDACTED]/g;
    }
  }
  return $text;
}

sub _deploy_run_command {
  my (%arg) = @_;
  my $argv = $arg{argv};
  my $stage = $arg{stage} // 'command';
  my $timeout = $arg{timeout} // $git_timeout;
  my $result = _run_argv_capture($argv, $arg{cwd}, $timeout, $arg{env}, $arg{capture_limit});
  my $secrets = $arg{secrets} // [];
  $result->{stdout} = _redact_secrets($result->{stdout}, $secrets);
  $result->{stderr} = _redact_secrets($result->{stderr}, $secrets);
  $result->{error}  = _redact_secrets($result->{error},  $secrets) if defined $result->{error};

  if ($result->{timeout}) {
    _deploy_throw($stage, "Timeout nach ${timeout}s", {rc=>$result->{rc}, stdout=>$result->{stdout}, stderr=>$result->{stderr}});
  }
  unless ($result->{ok}) {
    _deploy_throw($stage, $result->{error} // 'Prozessfehler', {rc=>$result->{rc}, stdout=>$result->{stdout}, stderr=>$result->{stderr}});
  }
  if (!$arg{allow_nonzero} && ($result->{rc} // 255) != 0) {
    _deploy_throw($stage, "Befehl fehlgeschlagen (rc=$result->{rc})", {rc=>$result->{rc}, stdout=>$result->{stdout}, stderr=>$result->{stderr}});
  }
  return $result;
}

sub _expand_fixed_argv {
  my ($spec, $release, $commit, $target, $opt) = @_;
  $opt = {} unless ref($opt) eq 'HASH';
  _deploy_throw('validation', 'argv-Spezifikation fehlt') unless ref($spec) eq 'ARRAY' && @$spec;
  my @argv;
  for my $arg (@$spec) {
    _deploy_throw('validation', 'argv enthaelt keinen String') if !defined($arg) || ref($arg) || $arg =~ /\0/;
    my $x = "$arg";
    $x =~ s/\{release\}/$release/g;
    $x =~ s/\{commit\}/$commit/g;
    $x =~ s/\{target\}/$target/g;
    push @argv, $x;
  }
  _deploy_throw('validation', 'Erstes argv-Element muss ein absolutes Programm sein') unless $argv[0] =~ m{^/};
  if ($opt->{allow_nonexec_shell}) {
    _deploy_throw('validation', "Programm fehlt oder ist ungueltig: $argv[0]") unless -f $argv[0] && !-l $argv[0];
  } else {
    _deploy_throw('validation', "Programm nicht ausfuehrbar: $argv[0]") unless -x $argv[0] && !-l $argv[0];
  }
  return \@argv;
}

sub _validate_git_tree {
  my ($cache_dir, $commit, $profile, $secrets) = @_;
  my $max_files = (defined $profile->{max_files} && $profile->{max_files} =~ /^\d+$/)
    ? 0 + $profile->{max_files} : $git_default_max_files;
  my $max_bytes = (defined $profile->{max_bytes} && $profile->{max_bytes} =~ /^\d+$/)
    ? 0 + $profile->{max_bytes} : $git_default_max_bytes;
  my $listing_limit = (defined $profile->{max_tree_listing_bytes} && $profile->{max_tree_listing_bytes} =~ /^\d+$/)
    ? 0 + $profile->{max_tree_listing_bytes} : 33_554_432;
  $listing_limit = 1_048_576 if $listing_limit < 1_048_576;

  my $res = _deploy_run_command(
    stage=>'tree_validation',
    argv=>[$git_bin, "--git-dir=$cache_dir", 'ls-tree', '-r', '-z', '-l', '--full-tree', $commit],
    timeout=>$git_timeout, env=>_git_base_env(), secrets=>$secrets,
    capture_limit=>$listing_limit,
  );
  if (($res->{bytes_out_total} // 0) > $listing_limit) {
    _deploy_throw('tree_validation', "Git-Baumliste ist groesser als das Prueflimit von $listing_limit Bytes");
  }

  my ($files, $bytes) = (0, 0);
  for my $record (split /\0/, $res->{stdout}, -1) {
    next unless length $record;
    my ($mode, $type, $size, $name) = $record =~ /^(\d{6})\s+(\S+)\s+[0-9a-fA-F]+\s+(-|\d+)\t(.*)\z/s;
    _deploy_throw('tree_validation', 'Unerwartetes git ls-tree-Ausgabeformat') unless defined $mode;
    _deploy_throw('tree_validation', 'Repository-Pfad enthaelt Steuerzeichen') if $name =~ /[\x00-\x1f\x7f]/;
    _deploy_throw('tree_validation', "Git-Submodule/Gitlink ist nicht unterstuetzt: $name")
      if $mode eq '160000' || $type eq 'commit';
    _deploy_throw('tree_validation', "Unerwarteter Git-Objekttyp $type: $name") unless $type eq 'blob';
    $files++;
    $bytes += 0 + $size if $size ne '-';
    _deploy_throw('tree_validation', "Repository enthaelt zu viele Dateien (Maximum $max_files)") if $files > $max_files;
    _deploy_throw('tree_validation', "Repository-Inhalt ist zu gross (Maximum $max_bytes Bytes)") if $bytes > $max_bytes;
  }
  return {files=>$files, bytes=>$bytes};
}

sub _is_managed_systemd_backlink {
  my ($path_abs, $link, $root, $profile) = @_;
  return 0 unless ref($profile) eq 'HASH' && exists $profile->{post_deploy};
  my $service = $profile->{restart_service};
  return 0 unless defined($service) && !ref($service)
    && $service =~ /^[A-Za-z0-9_.\@:-]+\.service$/ && length($service) <= 255;

  my $expected_path = _normalize_abs_lexical("$root/service/$service");
  my $expected_link = "/etc/systemd/system/$service";
  return _normalize_abs_lexical($path_abs) eq $expected_path && $link eq $expected_link ? 1 : 0;
}

sub _scan_release_tree {
  my ($root, $profile) = @_;
  my $root_norm = _normalize_abs_lexical($root);
  my $allow_symlinks = exists $profile->{allow_symlinks} ? ($profile->{allow_symlinks} ? 1 : 0) : 1;
  my $reject_hardlinks = exists $profile->{reject_hardlinks} ? ($profile->{reject_hardlinks} ? 1 : 0) : 1;
  my $reject_lfs_pointers = exists $profile->{reject_lfs_pointers} ? ($profile->{reject_lfs_pointers} ? 1 : 0) : 1;
  my $max_files = (defined $profile->{max_files} && $profile->{max_files} =~ /^\d+$/)
    ? 0 + $profile->{max_files} : $git_default_max_files;
  my $max_bytes = (defined $profile->{max_bytes} && $profile->{max_bytes} =~ /^\d+$/)
    ? 0 + $profile->{max_bytes} : $git_default_max_bytes;
  my ($files, $bytes) = (0, 0);

  my $ok = eval {
    find({
      no_chdir => 1,
      wanted => sub {
        my $p = $File::Find::name;
        my $rel = substr($p, length($root_norm));
        die "Repository-Pfad enthaelt Steuerzeichen" if $rel =~ /[\x00-\x1f\x7f]/;
        my @st = lstat($p);
        die "lstat fehlgeschlagen: $p: $!" unless @st;
        my $mode = $st[2];
        if (S_ISDIR($mode)) {
          return;
        } elsif (S_ISREG($mode)) {
          $files++;
          $bytes += $st[7] // 0;
          die "Hardlink im Release verboten: $p" if $reject_hardlinks && ($st[3] // 1) > 1;
          if ($reject_lfs_pointers && ($st[7] // 0) <= 1024) {
            open my $lfh, '<:raw', $p or die "LFS-Pruefung konnte Datei nicht lesen: $p: $!";
            my $head = '';
            read($lfh, $head, 256);
            close $lfh;
            die "Git-LFS-Pointer ist nicht als Deployment-Inhalt erlaubt: $p"
              if $head =~ /^version https:\/\/git-lfs\.github\.com\/spec\/v1(?:\r?\n|\z)/;
          }
        } elsif (S_ISLNK($mode)) {
          my $link = readlink($p);
          die "readlink fehlgeschlagen: $p: $!" unless defined $link;
          die "NUL im Symlink-Ziel: $p" if $link =~ /\0/;
          my $managed_systemd_backlink = _is_managed_systemd_backlink(
            $p, $link, $root_norm, $profile
          );
          die "Symlink im Release verboten: $p" unless $allow_symlinks || $managed_systemd_backlink;
          unless ($managed_systemd_backlink) {
            my $resolved = $link =~ m{^/}
              ? _normalize_abs_lexical($link)
              : _normalize_abs_lexical(path($p)->dirname->to_string . "/$link");
            die "Symlink verlaesst Release: $p -> $link" unless _path_is_within($resolved, $root_norm);
          }
          $files++;
          # Git speichert das Symlink-Ziel als Blob. git ls-tree -l zaehlt
          # deshalb die Laenge des Link-Textes als Objektgroesse. Der
          # extrahierte Baum muss dieselbe Byte-Semantik verwenden, sonst
          # scheitern sichere interne Symlinks faelschlich am Tree-Vergleich.
          $bytes += length($link);
        } else {
          die "Spezialdatei im Release verboten: $p";
        }
        die "Release enthaelt zu viele Dateien (Maximum $max_files)" if $files > $max_files;
        die "Release ist zu gross (Maximum $max_bytes Bytes)" if $bytes > $max_bytes;
      },
    }, $root_norm);
    1;
  };
  _deploy_throw('release_validation', $@) unless $ok;
  return {files=>$files, bytes=>$bytes};
}

sub _release_path_is_live_preserve_subtree {
  my ($absolute, $root, $specs) = @_;
  return 0 unless ref($specs) eq 'ARRAY' && @$specs;
  my $root_norm = _normalize_abs_lexical($root);
  my $path_norm = _normalize_abs_lexical($absolute);
  return 0 unless _path_is_within($path_norm, $root_norm);
  my $rel = substr($path_norm, length($root_norm));
  $rel =~ s{^/}{};
  return 0 unless length $rel;

  for my $spec (@$specs) {
    my $policy = $spec->{policy} // 'preserve_existing';
    next unless $policy eq 'preserve_existing' || $policy eq 'create_if_missing';
    my $preserved = $spec->{path};
    return 1 if $rel eq $preserved || index($rel, "$preserved/") == 0;
  }
  return 0;
}

sub _apply_release_owner {
  my ($root, $profile, $preserve_specs) = @_;
  return unless defined($profile->{user}) || defined($profile->{group});
  my $uid = _name2uid($profile->{user});
  my $gid = _name2gid($profile->{group});
  _deploy_throw('metadata', "Unbekannter Benutzer: $profile->{user}") if defined($profile->{user}) && !defined($uid);
  _deploy_throw('metadata', "Unbekannte Gruppe: $profile->{group}") if defined($profile->{group}) && !defined($gid);
  my $u = defined($uid) ? $uid : -1;
  my $g = defined($gid) ? $gid : -1;
  my $ok = eval {
    find({
      no_chdir => 1,
      wanted => sub {
        my $p = $File::Find::name;
        my @st = lstat($p);
        die "lstat fehlgeschlagen: $p: $!" unless @st;
        return if S_ISLNK($st[2]);
        if (_release_path_is_live_preserve_subtree($p, $root, $preserve_specs)) {
          $File::Find::prune = 1 if S_ISDIR($st[2]);
          return;
        }
        chown($u, $g, $p) or die "chown fehlgeschlagen: $p: $!";
      },
    }, $root);
    1;
  };
  _deploy_throw('metadata', $@) unless $ok;
}

sub _normalize_preserve_relative_or_throw {
  my ($raw, $label) = @_;
  $label //= 'preserve_paths.path';
  _deploy_throw('validation', "$label fehlt")
    unless defined($raw) && !ref($raw) && length($raw);
  _deploy_throw('validation', "$label muss relativ sein") if $raw =~ m{^/};
  _deploy_throw('validation', "$label enthaelt Steuerzeichen") if $raw =~ /[\x00-\x1f\x7f]/;
  _deploy_throw('validation', "$label enthaelt Backslashes") if $raw =~ /\\/;

  my @parts;
  for my $part (split m{/+}, $raw) {
    next if $part eq '' || $part eq '.';
    _deploy_throw('validation', "$label darf kein .. enthalten") if $part eq '..';
    push @parts, $part;
  }
  _deploy_throw('validation', "$label darf nicht leer sein") unless @parts;
  return join('/', @parts);
}

sub _preserve_specs_or_throw {
  my ($profile, $context) = @_;
  $context //= 'Deployment-Profil';
  return [] unless exists $profile->{preserve_paths};
  _deploy_throw('validation', "$context: preserve_paths muss ein Array sein")
    unless ref($profile->{preserve_paths}) eq 'ARRAY';
  _deploy_throw('validation', "$context: preserve_paths enthaelt zu viele Eintraege (Maximum 100)")
    if @{$profile->{preserve_paths}} > 100;

  my (@clean, %seen);
  for my $i (0 .. $#{$profile->{preserve_paths}}) {
    my $raw = $profile->{preserve_paths}[$i];
    _deploy_throw('validation', "$context: preserve_paths[$i] muss ein Objekt sein")
      unless ref($raw) eq 'HASH';
    my %allowed = map { $_=>1 } qw(path policy required user group mode);
    for my $key (keys %$raw) {
      _deploy_throw('validation', "$context: preserve_paths[$i].$key ist nicht erlaubt")
        unless $allowed{$key};
    }

    my $rel = _normalize_preserve_relative_or_throw(
      $raw->{path}, "$context: preserve_paths[$i].path"
    );
    _deploy_throw('validation', "$context: preserve_paths enthaelt den Pfad mehrfach: $rel")
      if $seen{$rel}++;

    my $policy = lc($raw->{policy} // 'preserve_existing');
    _deploy_throw('validation', "$context: preserve_paths[$i].policy muss preserve_existing, create_if_missing oder replace_from_git sein")
      unless $policy =~ /^(?:preserve_existing|create_if_missing|replace_from_git)$/;

    my $mode;
    if (defined $raw->{mode}) {
      my $m = "$raw->{mode}";
      $m =~ s/^0+//;
      _deploy_throw('validation', "$context: preserve_paths[$i].mode ist ungueltig")
        unless $m =~ /^[0-7]{3,4}$/;
      $mode = oct($m);
      _deploy_throw('validation', "$context: preserve_paths[$i].mode darf kein setuid/setgid/sticky enthalten")
        if $mode & 07000;
      _deploy_throw('validation', "$context: preserve_paths[$i].mode darf nicht world-writable sein")
        if $mode & 0002;
    }
    for my $field (qw(user group)) {
      next unless defined $raw->{$field};
      _deploy_throw('validation', "$context: preserve_paths[$i].$field ist ungueltig")
        if ref($raw->{$field}) || "$raw->{$field}" =~ /[\x00-\x1f\x7f]/ || !length("$raw->{$field}");
    }
    my $required = exists($raw->{required})
      ? _json_bool_or_throw($raw->{required}, "$context: preserve_paths[$i].required")
      : 1;

    push @clean, {
      path=>$rel,
      policy=>$policy,
      required=>$required,
      (defined($raw->{user}) ? (user=>$raw->{user}) : ()),
      (defined($raw->{group}) ? (group=>$raw->{group}) : ()),
      (defined($mode) ? (mode=>$mode) : ()),
    };
  }

  # Ueberlappende Pfade waeren mehrdeutig, z.B. config und config/app.json.
  my @paths = sort keys %seen;
  for my $i (0 .. $#paths) {
    for my $j ($i + 1 .. $#paths) {
      _deploy_throw('validation', "$context: preserve_paths ueberlappen sich: $paths[$i] und $paths[$j]")
        if index($paths[$j], "$paths[$i]/") == 0;
    }
  }
  return \@clean;
}

sub _preserve_policy_keeps_live {
  my ($spec) = @_;
  return (($spec->{policy}//'') eq 'preserve_existing' || ($spec->{policy}//'') eq 'create_if_missing') ? 1 : 0;
}

sub _release_path_is_preserved {
  my ($absolute, $root, $specs) = @_;
  return 0 unless ref($specs) eq 'ARRAY' && @$specs;
  my $root_norm = _normalize_abs_lexical($root);
  my $path_norm = _normalize_abs_lexical($absolute);
  return 0 unless _path_is_within($path_norm, $root_norm);
  my $rel = substr($path_norm, length($root_norm));
  $rel =~ s{^/}{};
  for my $spec (@$specs) {
    next unless _preserve_policy_keeps_live($spec);
    my $p = $spec->{path};
    # Der Pfad selbst, sein Inhalt und alle Elternverzeichnisse bleiben
    # schreibbar. Atomare Config-Saves benoetigen Schreibrecht im Parent.
    return 1 if $rel eq '' || $rel eq $p || index($rel, "$p/") == 0 || index($p, "$rel/") == 0;
  }
  return 0;
}

sub _remove_preserve_destination {
  my ($dest) = @_;
  return unless -e $dest || -l $dest;
  if (-l $dest || -f $dest) {
    unlink($dest) or _deploy_throw('preserve', "Ziel konnte nicht entfernt werden: $dest: $!");
    return;
  }
  if (-d $dest) {
    my $err;
    remove_tree($dest, {safe=>1, error=>\$err});
    if ($err && @$err) {
      my @m = map { my ($f,$e) = %$_; "$f: $e" } @$err;
      _deploy_throw('preserve', "Zielverzeichnis konnte nicht entfernt werden: " . join('; ', @m));
    }
    return;
  }
  _deploy_throw('preserve', "Spezialdatei als Preserve-Ziel ist verboten: $dest");
}

sub _ensure_preserve_parent {
  my ($release, $dest) = @_;
  my $root = _normalize_abs_lexical($release);
  my $parent = _normalize_abs_lexical(path($dest)->dirname->to_string);
  _deploy_throw('preserve', "Preserve-Ziel verlaesst Release: $dest") unless _path_is_within($parent, $root);
  my $rel = substr($parent, length($root));
  $rel =~ s{^/}{};
  my $cur = $root;
  for my $part (grep { length } split m{/+}, $rel) {
    $cur .= "/$part";
    if (-e $cur || -l $cur) {
      _deploy_throw('preserve', "Symlink im Preserve-Zielpfad verboten: $cur") if -l $cur;
      _deploy_throw('preserve', "Preserve-Zielkomponente ist kein Verzeichnis: $cur") unless -d $cur;
    } else {
      mkdir($cur, 0770) or _deploy_throw('preserve', "Preserve-Zielverzeichnis konnte nicht angelegt werden: $cur: $!");
    }
  }
}

sub _copy_preserved_node {
  my ($src, $dest, $release, $stats) = @_;
  my @st = lstat($src);
  _deploy_throw('preserve', "Preserve-Quelle konnte nicht gelesen werden: $src: $!") unless @st;
  my $mode = $st[2];
  # Auf regulaeren Dateien werden besondere Bits nie uebernommen. Bei
  # Verzeichnissen bleiben Setgid und Sticky dagegen erhalten, weil sie fuer
  # Gruppenvererbung und gemeinsam verwaltete Laufzeitdaten benoetigt werden.
  # Setuid auf Verzeichnissen wird verworfen. Der explizite Profilmodus wird
  # anschliessend weiterhin auf dem obersten Preserve-Pfad angewendet.
  my $source_mode = S_IMODE($mode);
  my $safe_mode = S_ISDIR($mode) ? ($source_mode & ~04000) : ($source_mode & 0777);
  _deploy_throw('preserve', "Symlink als Preserve-Quelle ist verboten: $src") if S_ISLNK($mode);

  _ensure_preserve_parent($release, $dest);
  if (S_ISREG($mode)) {
    _deploy_throw('preserve', "Hardlink als Preserve-Quelle ist verboten: $src") if ($st[3]//1) > 1;
    _remove_preserve_destination($dest);
    eval { path($src)->copy_to($dest); 1 }
      or _deploy_throw('preserve', "Preserve-Datei konnte nicht kopiert werden: $src -> $dest: $@");
    chmod($safe_mode, $dest) or _deploy_throw('preserve', "chmod fehlgeschlagen: $dest: $!");
    chown($st[4], $st[5], $dest) or _deploy_throw('preserve', "chown fehlgeschlagen: $dest: $!");
    $stats->{files}++;
    $stats->{bytes} += $st[7] // 0;
    return;
  }
  if (S_ISDIR($mode)) {
    _remove_preserve_destination($dest);
    # Bis alle Kinder kopiert sind, muss das Staging-Verzeichnis dem
    # Deploy-Prozess gehoeren und sicher beschreibbar bleiben.
    mkdir($dest, 0700) or _deploy_throw('preserve', "Preserve-Verzeichnis konnte nicht angelegt werden: $dest: $!");
    opendir(my $dh, $src) or _deploy_throw('preserve', "Preserve-Verzeichnis konnte nicht gelesen werden: $src: $!");
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    for my $name (@names) {
      _copy_preserved_node("$src/$name", "$dest/$name", $release, $stats);
    }
    chmod($safe_mode, $dest) or _deploy_throw('preserve', "chmod fehlgeschlagen: $dest: $!");
    chown($st[4], $st[5], $dest) or _deploy_throw('preserve', "chown fehlgeschlagen: $dest: $!");
    return;
  }
  _deploy_throw('preserve', "Spezialdatei als Preserve-Quelle ist verboten: $src");
}

sub _apply_preserve_metadata {
  my ($dest, $spec) = @_;
  my @st = lstat($dest);
  _deploy_throw('preserve', "Erhaltener Pfad fehlt nach Verarbeitung: $dest") unless @st;
  _deploy_throw('preserve', "Erhaltener Pfad darf kein Symlink sein: $dest") if S_ISLNK($st[2]);

  my $uid = defined($spec->{user}) ? _name2uid($spec->{user}) : undef;
  my $gid = defined($spec->{group}) ? _name2gid($spec->{group}) : undef;
  _deploy_throw('preserve', "Unbekannter Benutzer fuer $spec->{path}: $spec->{user}")
    if defined($spec->{user}) && !defined($uid);
  _deploy_throw('preserve', "Unbekannte Gruppe fuer $spec->{path}: $spec->{group}")
    if defined($spec->{group}) && !defined($gid);
  if (defined $spec->{mode}) {
    chmod($spec->{mode}, $dest) or _deploy_throw('preserve', "chmod fuer $dest fehlgeschlagen: $!");
  }
  if (defined($uid) || defined($gid)) {
    chown(defined($uid)?$uid:-1, defined($gid)?$gid:-1, $dest)
      or _deploy_throw('preserve', "chown fuer $dest fehlgeschlagen: $!");
  }
  my @after = stat($dest);
  return {
    uid=>$after[4], gid=>$after[5], mode=>sprintf('%04o', S_IMODE($after[2])),
  };
}

sub _apply_preserve_paths {
  my ($target, $incoming, $specs) = @_;
  return {count=>0, items=>[]} unless ref($specs) eq 'ARRAY' && @$specs;
  my @items;
  for my $spec (@$specs) {
    my $rel = $spec->{path};
    my $src = _normalize_abs_lexical("$target/$rel");
    my $dest = _normalize_abs_lexical("$incoming/$rel");
    _deploy_throw('preserve', "Preserve-Quelle verlaesst target_path: $rel") unless _path_is_within($src, $target);
    _deploy_throw('preserve', "Preserve-Ziel verlaesst Release: $rel") unless _path_is_within($dest, $incoming);

    my $source_exists = (-e $src || -l $src) ? 1 : 0;
    my $dest_exists = (-e $dest || -l $dest) ? 1 : 0;
    my ($action, $copy_stats) = ('', {files=>0, bytes=>0});

    if (_preserve_policy_keeps_live($spec) && $source_exists) {
      _assert_no_symlink_components($src, 1);
      _copy_preserved_node($src, $dest, $incoming, $copy_stats);
      $action = 'preserved_active';
      $dest_exists = 1;
    } elsif ($dest_exists) {
      $action = ($spec->{policy} eq 'replace_from_git') ? 'replaced_from_git' : 'git_default';
    } elsif ($spec->{required}) {
      _deploy_throw('preserve', "Erforderlicher Preserve-Pfad fehlt produktiv und im Git-Release: $rel");
    } else {
      $action = 'optional_missing';
    }

    my $meta;
    $meta = _apply_preserve_metadata($dest, $spec) if $dest_exists;
    push @items, {
      path=>$rel, policy=>$spec->{policy}, required=>($spec->{required}?true():false()),
      action=>$action, copied_files=>$copy_stats->{files}, copied_bytes=>$copy_stats->{bytes},
      (defined($meta) ? (applied=>$meta) : ()),
    };
  }
  return {count=>scalar(@items), items=>\@items};
}

sub _seal_release_permissions {
  my ($root, $profile, $preserve_specs) = @_;
  my $enabled = exists $profile->{immutable_permissions}
    ? ($profile->{immutable_permissions} ? 1 : 0) : 1;
  return {enabled=>0, changed=>0, excluded_preserve_paths=>0} unless $enabled;
  my ($changed, $excluded) = (0, 0);
  my $ok = eval {
    find({
      no_chdir => 1,
      wanted => sub {
        my $p = $File::Find::name;
        my @st = lstat($p);
        die "lstat fehlgeschlagen: $p: $!" unless @st;
        return if S_ISLNK($st[2]);
        if (_release_path_is_preserved($p, $root, $preserve_specs)) {
          $excluded++;
          return;
        }
        my $old = S_IMODE($st[2]);
        my $new = $old & ~0222;
        if ($new != $old) {
          chmod($new, $p) or die "chmod read-only fehlgeschlagen: $p: $!";
          $changed++;
        }
      },
    }, $root);
    1;
  };
  _deploy_throw('metadata', $@) unless $ok;
  return {enabled=>1, changed=>$changed, excluded_preserve_paths=>$excluded};
}

sub _commit_from_release_path {
  my ($release) = @_;
  return undef unless defined $release && length $release;
  my $name = path($release)->basename;
  return lc($1) if $name =~ /^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})-/;
  return undef;
}

sub _list_deploy_release_commits {
  my ($id, $request_token) = @_;
  _deploy_throw('validation', 'Ungueltige Deployment-ID') unless _safe_deploy_id($id);
  my $profile = $git_profiles_raw->{$id};
  _deploy_throw('validation', "Unbekanntes Deployment-Profil: $id") unless ref($profile) eq 'HASH';

  my $deploy_mode = lc($profile->{deploy_mode} // 'symlink_release');
  _deploy_throw('validation', 'deploy_mode muss symlink_release oder directory_swap sein')
    unless $deploy_mode eq 'symlink_release' || $deploy_mode eq 'directory_swap';
  my $target = _assert_deploy_path_allowed(
    $profile->{target_path}, 'target_path', ($deploy_mode eq 'symlink_release' ? 1 : 0)
  );
  my $parent = path($target)->dirname->to_string;
  my $base = path($target)->basename;
  my $releases_dir = $profile->{releases_dir} // "$parent/.${base}.releases";
  $releases_dir = _assert_deploy_path_allowed($releases_dir, 'releases_dir', 0, 1);

  my $status = _read_deploy_status($id) // {};
  my $active_commit = _valid_git_commit_id($status->{active_commit});
  my %by_commit;
  if (defined $active_commit) {
    $by_commit{$active_commit} = {
      commit=>$active_commit, active=>true(), source=>'active', deployed=>true(),
      release=>$status->{active_release} // $target,
      recorded_at=>$status->{deployed_at} // '', recorded_at_epoch=>0,
    };
  }

  # Bereits lokal vorhandene Releases bleiben immer sichtbar und direkt
  # wiederherstellbar, auch wenn das Repository temporaer nicht erreichbar ist.
  if (-d $releases_dir && !-l $releases_dir && opendir(my $dh, $releases_dir)) {
    while (defined(my $name = readdir($dh))) {
      next if $name =~ /^\./;
      next unless $name =~ /^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})-/;
      my $commit = lc($1);
      my $release = "$releases_dir/$name";
      next unless -d $release && !-l $release;
      my $mtime = (stat($release))[9] // 0;
      my $entry = $by_commit{$commit};
      next if $entry && ($entry->{recorded_at_epoch} // 0) >= $mtime;
      $by_commit{$commit} = {
        commit=>$commit,
        active=>(defined($active_commit) && $commit eq $active_commit ? true() : false()),
        source=>(defined($active_commit) && $commit eq $active_commit ? 'active' : 'archived'),
        deployed=>true(), release=>$release,
        recorded_at=>($mtime ? gmtime($mtime)->datetime . 'Z' : ''),
        recorded_at_epoch=>0 + $mtime,
      };
    }
    closedir $dh;
  }

  my $history_error = '';
  my $repository_head;
  my $allowed_ref = $profile->{allowed_ref};
  my $ref_policy = lc($profile->{ref_policy} //
    ((defined($allowed_ref) && $allowed_ref =~ m{^refs/tags/}) ? 'exact' : 'ancestor'));

  # Repository-Historie des erlaubten Refs laden. Branch-Profile liefern bis
  # zu 100 Commits. Bei einem Tag-Profil wird der exakt freigegebene Tag als
  # Release sichtbar. Tags sind reine Metadaten; die eigentliche Deploy-
  # Freigabe bleibt weiterhin durch allowed_ref/ref_policy und den spaeteren
  # merge-base- bzw. exact-Check abgesichert.
  if (defined($allowed_ref) && $allowed_ref =~ m{^refs/(?:heads|tags)/}) {
    eval {
      if ($git_deploy_token_source eq 'request') {
        _deploy_throw('history', 'Repository-Historie erfordert ein kurzlebiges Deploy-Token')
          unless defined($request_token) && length($request_token);
      }
      my $git_url = $profile->{git_url};
      _parse_git_url_or_throw($git_url);
      my $cache_dir = "$git_cache_root/" . sha256_hex($git_url);
      my $remote_ref = "refs/config-manager/" . sha256_hex($id);
      _ensure_managed_dir($git_state_dir, 0770);
      _ensure_managed_dir($git_cache_root, 0770);
      _ensure_managed_dir($git_home_dir, 0700);
      my $token = $git_deploy_token_source eq 'request' ? $request_token : _read_deploy_token_file();
      my ($auth_env, $secrets) = _git_env_with_auth($profile, $token);
      _with_named_locks(["git-cache:$cache_dir"], sub {
        if (!-d $cache_dir) {
          _deploy_run_command(stage=>'history_init', argv=>[$git_bin, 'init', '--bare', $cache_dir],
            timeout=>$git_timeout, env=>_git_base_env(), secrets=>$secrets);
        }
        _deploy_throw('history', "Ungueltiger Bare-Cache: $cache_dir")
          unless -d $cache_dir && -d "$cache_dir/objects" && -f "$cache_dir/HEAD" && !-l $cache_dir;
        _deploy_run_command(stage=>'history_fetch',
          argv=>[$git_bin, "--git-dir=$cache_dir", 'fetch', '--force', '--no-tags', '--prune',
                 $git_url, "$allowed_ref:$remote_ref"],
          timeout=>$git_timeout, env=>$auth_env, secrets=>$secrets);
        my $head = _deploy_run_command(stage=>'history_head',
          argv=>[$git_bin, "--git-dir=$cache_dir", 'rev-parse', "$remote_ref^{commit}"],
          timeout=>30, env=>_git_base_env(), secrets=>$secrets);
        $repository_head = lc($head->{stdout} // '');
        $repository_head =~ s/\s+\z//;
        _deploy_throw('history', 'Repository-Head ist ungueltig') unless _valid_git_commit_id($repository_head);

        if ($ref_policy eq 'ancestor' && $allowed_ref =~ m{^refs/heads/}) {
          my $limit = 100;
          my $log = _deploy_run_command(stage=>'history_log',
            argv=>[$git_bin, "--git-dir=$cache_dir", 'log', "--max-count=$limit",
                   '--date=iso-strict', '--format=%H%x1f%aI%x1f%an%x1f%s', $remote_ref],
            timeout=>30, env=>_git_base_env(), secrets=>$secrets,
            capture_limit=>2_097_152);
          for my $line (split /\n/, ($log->{stdout} // '')) {
            my ($commit, $date, $author, $subject) = split /\x1f/, $line, 4;
            $commit = _valid_git_commit_id($commit);
            next unless defined $commit;
            $author //= ''; $subject //= ''; $date //= '';
            $author =~ s/[\x00-\x1f\x7f]+/ /g;
            $subject =~ s/[\x00-\x1f\x7f]+/ /g;
            my $existing = $by_commit{$commit} // {};
            $by_commit{$commit} = {
              %$existing,
              commit=>$commit,
              active=>(defined($active_commit) && $commit eq $active_commit ? true() : false()),
              deployed=>($existing->{deployed} ? true() : false()),
              source=>($existing->{source} // 'repository_history'),
              commit_date=>$date,
              author=>substr($author, 0, 200),
              subject=>substr($subject, 0, 500),
              repository_head=>($commit eq $repository_head ? true() : false()),
              source_ref=>$allowed_ref,
              source_kind=>'branch',
            };
          }
        } else {
          # Exact-Tag-Profile: genau der freigegebene Tag wird angezeigt.
          my $show = _deploy_run_command(stage=>'history_show',
            argv=>[$git_bin, "--git-dir=$cache_dir", 'show', '-s',
                   '--date=iso-strict', '--format=%H%x1f%aI%x1f%an%x1f%s', "$remote_ref^{commit}"],
            timeout=>30, env=>_git_base_env(), secrets=>$secrets,
            capture_limit=>262_144);
          my ($line) = split /\n/, ($show->{stdout} // '');
          my ($commit, $date, $author, $subject) = split /\x1f/, ($line // ''), 4;
          $commit = _valid_git_commit_id($commit);
          _deploy_throw('history', 'Tag-Commit konnte nicht gelesen werden') unless defined $commit;
          $author //= ''; $subject //= ''; $date //= '';
          $author =~ s/[\x00-\x1f\x7f]+/ /g;
          $subject =~ s/[\x00-\x1f\x7f]+/ /g;
          my $tag_name = $allowed_ref; $tag_name =~ s{^refs/tags/}{};
          my $existing = $by_commit{$commit} // {};
          $by_commit{$commit} = {
            %$existing,
            commit=>$commit,
            active=>(defined($active_commit) && $commit eq $active_commit ? true() : false()),
            deployed=>($existing->{deployed} ? true() : false()),
            source=>($existing->{source} // 'repository_tag'),
            commit_date=>$date,
            author=>substr($author, 0, 200),
            subject=>substr($subject, 0, 500),
            repository_head=>true(),
            source_ref=>$allowed_ref,
            source_kind=>'tag',
            tags=>[$tag_name],
          };
        }

        # Remote Tags nur als Metadaten laden. Ein Tag erweitert die Deploy-
        # Berechtigung nicht; deploybare Commits muessen weiterhin den oben
        # freigegebenen Ref-Regeln entsprechen.
        my $tag_refs = _deploy_run_command(stage=>'history_tags',
          argv=>[$git_bin, 'ls-remote', '--tags', $git_url],
          timeout=>30, env=>$auth_env, secrets=>$secrets,
          capture_limit=>2_097_152);
        my (%tag_target, %peeled);
        my $seen = 0;
        for my $line (split /\n/, ($tag_refs->{stdout} // '')) {
          last if ++$seen > 4000;
          my ($oid, $ref) = split /\s+/, $line, 2;
          next unless defined($oid) && defined($ref);
          $oid = _valid_git_commit_id($oid);
          next unless defined $oid;
          next unless $ref =~ m{^refs/tags/([^\^\x00-\x20\x7f]+)(\^\{\})?$};
          my ($name, $is_peeled) = ($1, $2);
          next if length($name) > 200;
          if ($is_peeled) {
            $tag_target{$name} = $oid;
            $peeled{$name} = 1;
          } elsif (!$peeled{$name}) {
            $tag_target{$name} = $oid;
          }
        }
        for my $name (sort keys %tag_target) {
          my $commit = $tag_target{$name};
          next unless ref($by_commit{$commit}) eq 'HASH';
          my %have = map { $_ => 1 } @{ref($by_commit{$commit}{tags}) eq 'ARRAY' ? $by_commit{$commit}{tags} : []};
          next if $have{$name};
          push @{$by_commit{$commit}{tags}}, $name;
        }
      });
      1;
    } or do {
      my $e = _deploy_error_hash($@);
      $history_error = $e->{message} // 'Repository-Historie konnte nicht geladen werden';
    };
  }

  my @items = sort {
    ($b->{active} ? 1 : 0) <=> ($a->{active} ? 1 : 0)
      || (($b->{commit_date} // '') cmp ($a->{commit_date} // ''))
      || ($b->{recorded_at_epoch} // 0) <=> ($a->{recorded_at_epoch} // 0)
      || $a->{commit} cmp $b->{commit}
  } values %by_commit;
  return {
    deployment=>$id, deploy_mode=>$deploy_mode, target_path=>$target,
    releases_dir=>$releases_dir, active_commit=>$active_commit,
    repository_head=>$repository_head, allowed_ref=>$allowed_ref,
    history_complete=>(length($history_error) ? false() : true()),
    history_error=>$history_error,
    releases=>\@items,
  };
}


sub _active_commit_from_target_or_status {
  my ($profile, $status) = @_;
  my $target = ref($profile) eq 'HASH' ? $profile->{target_path} : undef;
  if (defined($target) && !ref($target) && $target =~ m{^/}) {
    my $marker = "$target/.deploy-commit";
    if (-f $marker && !-l $marker) {
      my $raw = eval { read_all($marker) };
      if (!$@ && defined $raw) {
        $raw =~ s/^\s+|\s+$//g;
        my $commit = _valid_git_commit_id($raw);
        return ($commit, 'active_release_marker') if defined $commit;
      }
    }
  }
  my $commit = _valid_git_commit_id(ref($status) eq 'HASH' ? $status->{active_commit} : undef);
  return ($commit, 'deploy_status') if defined $commit;
  return (undef, 'unknown');
}

sub _write_release_commit_marker {
  my ($release, $commit) = @_;
  _deploy_throw('release_metadata', 'Ungueltiger Release-Pfad') unless defined($release) && -d $release && !-l $release;
  _deploy_throw('release_metadata', 'Ungueltiger Commit fuer Release-Markierung') unless defined(_valid_git_commit_id($commit));
  my $marker = "$release/.deploy-commit";
  _deploy_throw('release_metadata', "Release-Markierung darf kein Symlink sein: $marker") if -l $marker;
  open my $fh, '>:raw', $marker or _deploy_throw('release_metadata', "Release-Markierung konnte nicht geschrieben werden: $!");
  print {$fh} lc($commit), "\n" or _deploy_throw('release_metadata', "Release-Markierung konnte nicht geschrieben werden: $!");
  close $fh or _deploy_throw('release_metadata', "Release-Markierung konnte nicht geschlossen werden: $!");
  chmod 0640, $marker or _deploy_throw('release_metadata', "Release-Markierung chmod fehlgeschlagen: $!");
  return $marker;
}


sub _compare_excluded_paths {
  my ($profile) = @_;
  my @excluded = ('.deploy-commit');
  my $raw = ref($profile) eq 'HASH' ? ($profile->{preserve_paths} // $profile->{preserve}) : undef;
  if (ref($raw) eq 'ARRAY') {
    for my $item (@$raw) {
      my $rel = ref($item) eq 'HASH' ? ($item->{path} // '') : '';
      next unless defined($rel) && !ref($rel) && length($rel);
      $rel =~ s{^\./+}{}; $rel =~ s{/+$}{};
      next if $rel eq '' || $rel =~ m{(?:^|/)\.\.(?:/|$)} || $rel =~ m{^/};
      push @excluded, $rel;
    }
  }
  return \@excluded;
}

sub _compare_path_excluded {
  my ($rel, $excluded) = @_;
  for my $x (@{$excluded // []}) {
    return 1 if $rel eq $x || index($rel, "$x/") == 0;
  }
  return 0;
}

sub _compare_tree_map {
  my ($root, $excluded) = @_;
  my %map;
  my $root_norm = _normalize_abs_lexical($root);
  find({no_chdir=>1, wanted=>sub {
    my $p = $File::Find::name;
    return if $p eq $root_norm;
    my $rel = substr($p, length($root_norm));
    $rel =~ s{^/}{};
    if (_compare_path_excluded($rel, $excluded)) {
      $File::Find::prune = 1 if -d $p && !-l $p;
      return;
    }
    my @st = lstat($p); return unless @st;
    if (S_ISREG($st[2])) {
      open my $fh, '<:raw', $p or _deploy_throw('compare', "Datei konnte nicht gelesen werden: $rel: $!");
      my $sha = Digest::SHA->new(256); $sha->addfile($fh); close $fh;
      $map{$rel} = {type=>'file', digest=>$sha->hexdigest, size=>0+($st[7]//0)};
    } elsif (S_ISLNK($st[2])) {
      my $link = readlink($p); $link = '' unless defined $link;
      $map{$rel} = {type=>'symlink', digest=>sha256_hex($link), size=>length($link)};
    }
  }}, $root_norm);
  return \%map;
}

sub _tree_integrity_fingerprint {
  my ($root, $excluded, $allow_missing) = @_;
  $excluded = [] unless ref($excluded) eq 'ARRAY';
  $allow_missing = $allow_missing ? 1 : 0;

  if (!(-e $root || -l $root)) {
    _deploy_throw('integrity', "Dateibaum fehlt: $root") unless $allow_missing;
    return {sha256=>sha256_hex("missing\0"), entries=>0, missing=>1};
  }

  my $resolved = $root;
  if (-l $resolved) {
    my $real = eval { path($resolved)->realpath->to_string };
    _deploy_throw('integrity', "Dateibaum kann nicht aufgeloest werden: $root")
      unless defined($real) && -d $real;
    $resolved = $real;
  }
  _deploy_throw('integrity', "Dateibaum ist kein Verzeichnis: $root") unless -d $resolved;
  my $root_norm = _normalize_abs_lexical($resolved);

  my @paths;
  find({no_chdir=>1, follow=>0, wanted=>sub {
    my $p = $File::Find::name;
    return if $p eq $root_norm;
    my $rel = substr($p, length($root_norm));
    $rel =~ s{^/}{};
    if (_compare_path_excluded($rel, $excluded)) {
      $File::Find::prune = 1 if -d $p && !-l $p;
      return;
    }
    push @paths, [$rel, $p];
  }}, $root_norm);

  my $sha = Digest::SHA->new(256);
  my $entries = 0;
  for my $item (sort { $a->[0] cmp $b->[0] } @paths) {
    my ($rel, $p) = @$item;
    my @st = lstat($p);
    _deploy_throw('integrity', "lstat fehlgeschlagen: $rel: $!") unless @st;
    my $mode = sprintf('%04o', S_IMODE($st[2]));
    my ($type, $digest, $size) = ('', '', 0);
    if (S_ISREG($st[2])) {
      open my $fh, '<:raw', $p or _deploy_throw('integrity', "Datei konnte nicht gelesen werden: $rel: $!");
      my $file_sha = Digest::SHA->new(256); $file_sha->addfile($fh); close $fh;
      ($type, $digest, $size) = ('file', $file_sha->hexdigest, 0 + ($st[7] // 0));
    } elsif (S_ISDIR($st[2])) {
      ($type, $digest, $size) = ('dir', '-', 0);
    } elsif (S_ISLNK($st[2])) {
      my $link = readlink($p);
      _deploy_throw('integrity', "readlink fehlgeschlagen: $rel: $!") unless defined $link;
      ($type, $digest, $size) = ('symlink', sha256_hex($link), length($link));
    } else {
      _deploy_throw('integrity', "Spezialdatei im Dateibaum ist verboten: $rel");
    }
    $sha->add(join("\0", $rel, $type, $mode, 0+($st[4]//0), 0+($st[5]//0), $size, $digest), "\0");
    $entries++;
  }
  return {sha256=>$sha->hexdigest, entries=>$entries, missing=>0};
}

sub _preview_dir {
  return "$git_state_dir/previews";
}

sub _cleanup_preview_tokens {
  my $dir = _preview_dir();
  return unless -d $dir;
  my $cutoff = time() - 3600;
  for my $file (glob("$dir/*.json")) {
    next if -l $file || !-f $file;
    my @st = stat($file);
    unlink($file) if @st && ($st[9] // 0) < $cutoff;
  }
}

sub _create_preview_token {
  my ($id, $profile, $to_commit, $tree_fp, $files_changed) = @_;
  my $dir = _preview_dir();
  _ensure_managed_dir($dir, 0700);
  _cleanup_preview_tokens();
  my $random = '';
  if (open my $ur, '<:raw', '/dev/urandom') {
    read($ur, $random, 32);
    close $ur;
  }
  my $token = sha256_hex(join("\0", $id, $to_commit, $git_config_digest, $tree_fp->{sha256}, time(), $$, $random));
  my $file = "$dir/$token.json";
  sysopen(my $fh, $file, O_WRONLY | O_CREAT | O_EXCL, 0600)
    or _deploy_throw('compare', "Preview-Token konnte nicht gespeichert werden: $!");
  my $expires = int(time() + 600);
  my $record = {
    deployment=>$id,
    to_commit=>lc($to_commit),
    target_path=>($profile->{target_path} // ''),
    active_tree_sha256=>$tree_fp->{sha256},
    active_tree_missing=>($tree_fp->{missing} ? true() : false()),
    config_digest=>$git_config_digest,
    config_generation=>$git_config_generation,
    files_changed=>0 + ($files_changed // 0),
    created_at=>int(time()), expires_at=>$expires,
  };
  print {$fh} encode_json($record) or do { close $fh; unlink $file; _deploy_throw('compare', 'Preview-Token konnte nicht geschrieben werden'); };
  close $fh or do { unlink $file; _deploy_throw('compare', 'Preview-Token konnte nicht geschlossen werden'); };
  chmod 0600, $file;
  return ($token, $expires);
}

sub _verify_and_consume_preview_token {
  my ($id, $profile, $commit, $payload) = @_;
  my $required = exists($profile->{require_diff_preview})
    ? _json_bool_or_throw($profile->{require_diff_preview}, "Profil $id: require_diff_preview")
    : 0;
  my $token = ref($payload) eq 'HASH' ? ($payload->{diff_preview_token} // '') : '';
  return {required=>0, verified=>0} if !$required && !length($token);
  _deploy_throw('preview', 'Gueltige Diff-Vorschau ist fuer dieses Deployment erforderlich')
    unless defined($token) && !ref($token) && $token =~ /^[0-9a-f]{64}$/;

  my $file = _preview_dir() . "/$token.json";
  _deploy_throw('preview', 'Diff-Vorschau ist unbekannt, abgelaufen oder bereits verwendet')
    unless -f $file && !-l $file;
  my $record = eval { decode_json(read_all($file)) };
  _deploy_throw('preview', 'Diff-Vorschau ist unlesbar') if $@ || ref($record) ne 'HASH';
  unlink($file) or _deploy_throw('preview', "Diff-Vorschau konnte nicht verbraucht werden: $!");

  _deploy_throw('preview', 'Diff-Vorschau ist abgelaufen')
    unless defined($record->{expires_at}) && $record->{expires_at} =~ /^\d+$/ && $record->{expires_at} >= time();
  _deploy_throw('preview', 'Diff-Vorschau gehoert zu einem anderen Deployment')
    unless ($record->{deployment} // '') eq $id;
  _deploy_throw('preview', 'Diff-Vorschau gehoert zu einem anderen Ziel-Commit')
    unless lc($record->{to_commit} // '') eq lc($commit // '');
  _deploy_throw('preview', 'Git-Deploy-Konfiguration hat sich seit der Vorschau geaendert')
    unless ($record->{config_digest} // '') eq $git_config_digest;
  _deploy_throw('preview', 'target_path hat sich seit der Vorschau geaendert')
    unless ($record->{target_path} // '') eq ($profile->{target_path} // '');

  my $excluded = _compare_excluded_paths($profile);
  my $current_fp = _tree_integrity_fingerprint($profile->{target_path}, $excluded, 1);
  _deploy_throw('preview', 'Aktiver Dateibaum hat sich seit der Vorschau geaendert')
    unless ($record->{active_tree_sha256} // '') eq $current_fp->{sha256} &&
           (($record->{active_tree_missing} ? 1 : 0) == ($current_fp->{missing} ? 1 : 0));
  return {required=>$required, verified=>1, token=>$token, files_changed=>0+($record->{files_changed}//0)};
}

sub _compare_active_tree_to_commit {
  my ($target, $cache_dir, $commit, $profile, $secrets) = @_;
  my $active_root = $target;
  if (-l $active_root) {
    my $real = eval { path($active_root)->realpath->to_string };
    _deploy_throw('compare', "Aktives Ziel kann nicht aufgeloest werden: $target") unless defined($real) && -d $real;
    $active_root = $real;
  }
  my $target_missing = !(-e $active_root || -l $active_root);
  _deploy_throw('compare', "Aktives Ziel ist kein Verzeichnis: $target")
    if !$target_missing && !-d $active_root;
  my $work = "$git_state_dir/compare-$$-" . int(time()*1000);
  _ensure_managed_dir($work, 0700);
  my $tarfile = "$work/target.tar";
  my $extract = "$work/tree";
  _ensure_managed_dir($extract, 0700);
  my ($files, $ins, $del, $binary) = ([], 0, 0, 0);
  my $ok = eval {
    _deploy_run_command(stage=>'compare_archive', argv=>[$git_bin, "--git-dir=$cache_dir", 'archive', '--format=tar', "--output=$tarfile", $commit], timeout=>$git_timeout, env=>_git_base_env(), secrets=>$secrets);
    _deploy_run_command(stage=>'compare_extract', argv=>[$tar_bin, '-xf', $tarfile, '-C', $extract, '--no-same-owner'], timeout=>$git_timeout, env=>_git_base_env(), secrets=>$secrets);
    my $excluded = _compare_excluded_paths($profile);
    my $left = $target_missing ? {} : _compare_tree_map($active_root, $excluded);
    my $right = _compare_tree_map($extract, $excluded);
    my %all = map { $_=>1 } (keys %$left, keys %$right);
    for my $rel (sort keys %all) {
      if (!exists $left->{$rel}) { push @$files, {status=>'A', path=>$rel}; next; }
      if (!exists $right->{$rel}) { push @$files, {status=>'D', path=>$rel}; next; }
      my $a=$left->{$rel}; my $b=$right->{$rel};
      if (($a->{type}//'') ne ($b->{type}//'') || ($a->{digest}//'') ne ($b->{digest}//'')) {
        push @$files, {status=>'M', path=>$rel};
      }
      last if @$files >= 1000;
    }
    1;
  };
  my $err=$@;
  remove_tree($work, {error=>\my $rmerr}) if -d $work;
  die $err unless $ok;
  my $tree_fp = _tree_integrity_fingerprint($target, _compare_excluded_paths($profile), 1);
  return ($files, $ins, $del, $binary, $tree_fp);
}

sub _compare_deploy_commits {
  my ($id, $requested_commit, $request_token) = @_;
  _deploy_throw('validation', 'Ungueltige Deployment-ID') unless _safe_deploy_id($id);
  my $profile = $git_profiles_raw->{$id};
  _deploy_throw('validation', "Unbekanntes Deployment-Profil: $id") unless ref($profile) eq 'HASH';

  my $status = _read_deploy_status($id) // {};
  my ($from, $from_source) = _active_commit_from_target_or_status($profile, $status);
  $from_source = 'none' unless defined $from;

  my $allowed_ref = $profile->{allowed_ref};
  my $ref_policy = lc($profile->{ref_policy} //
    ((defined($allowed_ref) && $allowed_ref =~ m{^refs/tags/}) ? 'exact' : 'ancestor'));
  _deploy_throw('compare', 'ref_policy muss exact oder ancestor sein')
    unless $ref_policy eq 'exact' || $ref_policy eq 'ancestor';
  _deploy_throw('compare', 'Diff-Vorschau erfordert allowed_ref')
    unless defined($allowed_ref) && !ref($allowed_ref) && $allowed_ref =~ m{^refs/(?:heads|tags)/};

  if ($git_deploy_token_source eq 'request') {
    _deploy_throw('compare', 'Diff-Vorschau erfordert ein kurzlebiges Deploy-Token')
      unless defined($request_token) && length($request_token);
  }

  my $git_url = $profile->{git_url};
  _parse_git_url_or_throw($git_url);
  my $cache_dir = "$git_cache_root/" . sha256_hex($git_url);
  my $remote_ref = "refs/config-manager/" . sha256_hex($id);
  _ensure_managed_dir($git_state_dir, 0770);
  _ensure_managed_dir($git_cache_root, 0770);
  _ensure_managed_dir($git_home_dir, 0700);
  my $token = $git_deploy_token_source eq 'request' ? $request_token : _read_deploy_token_file();
  my ($auth_env, $secrets) = _git_env_with_auth($profile, $token);

  my ($to, @files, $insertions, $deletions, $binary_files) = (undef, (), 0, 0, 0);
  _with_named_locks(["git-cache:$cache_dir"], sub {
    if (!-d $cache_dir) {
      _deploy_run_command(stage=>'compare_init', argv=>[$git_bin, 'init', '--bare', $cache_dir],
        timeout=>$git_timeout, env=>_git_base_env(), secrets=>$secrets);
    }
    _deploy_run_command(stage=>'compare_fetch',
      argv=>[$git_bin, "--git-dir=$cache_dir", 'fetch', '--force', '--no-tags', '--prune',
             $git_url, "$allowed_ref:$remote_ref"],
      timeout=>$git_timeout, env=>$auth_env, secrets=>$secrets);

    if (!defined($requested_commit) || $requested_commit eq '' || $requested_commit eq 'auto') {
      my $head = _deploy_run_command(stage=>'compare_head',
        argv=>[$git_bin, "--git-dir=$cache_dir", 'rev-parse', "$remote_ref^{commit}"],
        timeout=>30, env=>_git_base_env(), secrets=>$secrets);
      $to = lc($head->{stdout} // ''); $to =~ s/\s+\z//;
    } else {
      $to = _valid_git_commit_id($requested_commit);
    }
    _deploy_throw('compare', 'Ziel-Commit ist ungueltig') unless defined($to) && _valid_git_commit_id($to);

    for my $commit (grep { defined($_) && length($_) } ($from, $to)) {
      _deploy_run_command(stage=>'compare_commit',
        argv=>[$git_bin, "--git-dir=$cache_dir", 'cat-file', '-e', "$commit^{commit}"],
        timeout=>30, env=>_git_base_env(), secrets=>$secrets);
    }
    if ($ref_policy eq 'exact') {
      my $resolved = _deploy_run_command(stage=>'compare_ref_policy',
        argv=>[$git_bin, "--git-dir=$cache_dir", 'rev-parse', "$remote_ref^{commit}"],
        timeout=>30, env=>_git_base_env(), secrets=>$secrets);
      my $ref_commit = lc($resolved->{stdout} // ''); $ref_commit =~ s/\s+\z//;
      _deploy_throw('compare', "Ziel-Commit entspricht nicht exakt dem erlaubten Ref $allowed_ref")
        unless $ref_commit eq $to;
    } else {
      _deploy_run_command(stage=>'compare_ref_policy',
        argv=>[$git_bin, "--git-dir=$cache_dir", 'merge-base', '--is-ancestor', $to, $remote_ref],
        timeout=>30, env=>_git_base_env(), secrets=>$secrets);
    }

    # Entscheidend ist der tatsaechlich aktive Dateibaum. Dadurch kann weder
    # eine veraltete Statusdatei noch eine falsche Commit-Markierung den
    # Ausgangsstand auf den ausgewaehlten Ziel-Commit umbiegen.
    my ($tree_files, $tree_ins, $tree_del, $tree_binary, $tree_fp) =
      _compare_active_tree_to_commit($profile->{target_path}, $cache_dir, $to, $profile, $secrets);
    @files = @$tree_files;
    $insertions = $tree_ins;
    $deletions = $tree_del;
    $binary_files = $tree_binary;
    $status->{_preview_tree_fp} = $tree_fp;
  });

  my %counts = (added=>0, modified=>0, deleted=>0, renamed=>0, copied=>0, other=>0);
  for my $f (@files) {
    my $st = $f->{status} // '';
    if ($st =~ /^A/) { $counts{added}++ }
    elsif ($st =~ /^M/) { $counts{modified}++ }
    elsif ($st =~ /^D/) { $counts{deleted}++ }
    elsif ($st =~ /^R/) { $counts{renamed}++ }
    elsif ($st =~ /^C/) { $counts{copied}++ }
    else { $counts{other}++ }
  }
  my $direction = !defined($from) ? 'initial' : ($from eq $to ? 'same' : 'change');
  if (defined($from) && $from ne $to) {
    my $is_down = eval {
      _deploy_run_command(stage=>'compare_direction',
        argv=>[$git_bin, "--git-dir=$cache_dir", 'merge-base', '--is-ancestor', $to, $from],
        timeout=>30, env=>_git_base_env(), secrets=>$secrets); 1;
    };
    $direction = $is_down ? 'downgrade' : 'upgrade';
  }
  my ($preview_token, $preview_expires_at) = _create_preview_token(
    $id, $profile, $to, ($status->{_preview_tree_fp} // _tree_integrity_fingerprint($profile->{target_path}, _compare_excluded_paths($profile), 1)), scalar(@files)
  );
  return {deployment=>$id, from_commit=>$from, from_source=>$from_source, comparison_source=>'active_target_tree', to_commit=>$to, direction=>$direction,
    files_changed=>scalar(@files), insertions=>$insertions, deletions=>$deletions,
    binary_files=>$binary_files, counts=>\%counts, files=>\@files, preview_token=>$preview_token,
    preview_expires_at=>$preview_expires_at, truncated=>(@files>=1000?true():false())};
}

sub _managed_current_release {
  my ($target, $releases_dir) = @_;
  return undef unless -e $target || -l $target;
  _deploy_throw('validation', "target_path existiert, ist aber kein verwalteter Symlink: $target") unless -l $target;
  my $link = readlink($target);
  _deploy_throw('validation', "readlink($target) fehlgeschlagen: $!") unless defined $link;
  my $abs = $link =~ m{^/} ? _normalize_abs_lexical($link)
                           : _normalize_abs_lexical(path($target)->dirname->to_string . "/$link");
  _deploy_throw('validation', "Aktiver Symlink zeigt ausserhalb releases_dir: $target -> $link")
    unless _path_is_within($abs, $releases_dir);
  _deploy_throw('validation', "Aktives Release fehlt oder ist kein Verzeichnis: $abs") unless -d $abs && !-l $abs;
  return $abs;
}

sub _atomic_symlink_switch {
  my ($target, $release) = @_;
  my $parent = path($target)->dirname->to_string;
  my $base = path($target)->basename;
  my $tmp = "$parent/.${base}.deploy-link.$$-" . int(time() * 1000);
  unlink $tmp if -e $tmp || -l $tmp;
  symlink($release, $tmp) or _deploy_throw('activate', "symlink($tmp) fehlgeschlagen: $!");
  if (-e $target && !-l $target) {
    unlink $tmp;
    _deploy_throw('activate', "target_path wurde waehrend des Deploys zu einer Nicht-Symlink-Datei: $target");
  }
  rename($tmp, $target) or do {
    my $e = $!;
    unlink $tmp;
    _deploy_throw('activate', "Atomarer Symlink-Wechsel fehlgeschlagen: $e");
  };
  _fsync_dir($target);
  return 1;
}


sub _assert_same_filesystem {
  my ($left, $right) = @_;
  my @a = stat($left);
  my @b = stat($right);
  _deploy_throw('filesystem', "Dateisystem konnte nicht ermittelt werden: $left") unless @a;
  _deploy_throw('filesystem', "Dateisystem konnte nicht ermittelt werden: $right") unless @b;
  _deploy_throw('filesystem', 'directory_swap verlangt target_path und releases_dir auf demselben Dateisystem')
    unless $a[0] == $b[0];
  return 1;
}

sub _renameat2_syscall_number {
  my $arch = lc($Config::Config{archname} // '');
  return 316 if $arch =~ /^x86_64/;
  return 353 if $arch =~ /^(?:i[3-6]86|x86)-/;
  return 276 if $arch =~ /^(?:aarch64|arm64|riscv64|loongarch64)/;
  return 382 if $arch =~ /^arm/;
  return 357 if $arch =~ /^(?:powerpc|ppc)/;
  return 347 if $arch =~ /^s390x/;
  return 345 if $arch =~ /^sparc64/;
  return undef;
}

sub _rename_exchange {
  my ($left, $right, $stage) = @_;
  $stage //= 'filesystem';
  _deploy_throw($stage, 'renameat2(RENAME_EXCHANGE) verlangt zwei absolute Pfade')
    unless defined($left) && defined($right) && $left =~ m{^/} && $right =~ m{^/};
  _deploy_throw($stage, 'renameat2(RENAME_EXCHANGE) akzeptiert keine NUL-Zeichen')
    if $left =~ /\0/ || $right =~ /\0/;

  my $nr = _renameat2_syscall_number();
  my $arch = $Config::Config{archname} // 'unbekannt';
  _deploy_throw($stage, "renameat2(RENAME_EXCHANGE) wird auf dieser Architektur nicht unterstuetzt: $arch")
    unless defined $nr;

  # Linux: AT_FDCWD=-100, RENAME_EXCHANGE=2.
  my $rc = syscall($nr, -100, $left, -100, $right, 2);
  if ($rc != 0) {
    my $error = "$!";
    _deploy_throw($stage, "Atomarer Verzeichnistausch fehlgeschlagen ($left <-> $right): $error");
  }
  return 1;
}

sub _probe_rename_exchange {
  my ($dir) = @_;
  my $stamp = "$$-" . int(time() * 1000);
  my $a = "$dir/.exchange-probe-a-$stamp";
  my $b = "$dir/.exchange-probe-b-$stamp";
  mkdir($a, 0700) or _deploy_throw('validation', "Exchange-Probe konnte $a nicht anlegen: $!");
  mkdir($b, 0700) or do { rmdir($a); _deploy_throw('validation', "Exchange-Probe konnte $b nicht anlegen: $!"); };
  my $ok = eval {
    _rename_exchange($a, $b, 'validation');
    1;
  };
  my $err = $@;
  rmdir($a) if -d $a;
  rmdir($b) if -d $b;
  if (!$ok) {
    my $e = _deploy_error_hash($err);
    _deploy_throw('validation', "Dateisystem unter $dir unterstuetzt keinen atomaren directory_swap: $e->{message}", $e);
  }
  return 1;
}

sub _directory_swap_activate {
  my ($target, $new_release, $releases_dir, $previous_commit, $secrets) = @_;
  _deploy_throw('activate', "Neues Release fehlt: $new_release") unless -d $new_release && !-l $new_release;
  _deploy_throw('activate', "target_path darf bei directory_swap kein Symlink sein: $target") if -l $target;
  _deploy_throw('activate', "target_path ist keine Verzeichnisstruktur: $target") if -e $target && !-d $target;

if (-d $target) {
    _rename_exchange($new_release, $target, 'activate_exchange');
    # Nach dem atomaren Tausch liegt der alte aktive Stand am bisherigen
    # Release-Pfad, der neue Stand weiterhin unter dem festen target_path.
    _deploy_throw('activate', "Vorheriges Release fehlt nach renameat2(RENAME_EXCHANGE): $new_release")
      unless -d $new_release && !-l $new_release;
    _fsync_dir($target);

    # $new_release ist noch nach dem NEUEN Commit benannt, enthaelt nach dem
    # Tausch aber den ALTEN (vorherigen) Stand. Ohne Korrektur wuerde
    # GET /git_deploy/releases/:deployment diesen Ordner faelschlich unter
    # dem neuen Commit-Hash listen und dabei mit dem tatsaechlich aktiven
    # Release verwechseln. Deshalb hier auf den echten Inhalt umbenennen.
    my $archived = $new_release;
    my $prev_id = defined($previous_commit) && $previous_commit =~ /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i
      ? lc($previous_commit) : 'unknown';
    my $stamp = localtime()->strftime('%Y%m%d_%H%M%S') . '_' . sprintf('%03d', int((time() - int(time())) * 1000));
    my $corrected = "$releases_dir/$prev_id-$stamp-$$";
    if ($corrected ne $archived && !-e $corrected && rename($archived, $corrected)) {
      $archived = $corrected;
      _fsync_dir($releases_dir);
    }
    return $archived;
  }

  rename($new_release, $target)
    or _deploy_throw('activate', "Erstdeploy konnte nicht auf target_path aktiviert werden: $!");
  _fsync_dir($target);
  return undef;
}

sub _directory_swap_rollback {
  my ($target, $previous_store, $releases_dir, $failed_commit, $secrets) = @_;
  _deploy_throw('rollback', "Aktives Ziel fehlt beim Rollback: $target") unless -d $target && !-l $target;

  if (defined($previous_store) && length($previous_store)) {
    _deploy_throw('rollback', "Vorheriges Release fehlt: $previous_store") unless -d $previous_store && !-l $previous_store;
    _rename_exchange($target, $previous_store, 'rollback_exchange');
    # previous_store enthaelt danach den fehlgeschlagenen neuen Stand.
    _fsync_dir($target);
    return $previous_store;
  }

  my $stamp = localtime()->strftime('%Y%m%d_%H%M%S') . '_' . sprintf('%03d', int((time() - int(time())) * 1000));
  my $id = defined($failed_commit) && $failed_commit =~ /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/
    ? $failed_commit : 'unknown';
  my $failed_store = "$releases_dir/$id-failed-$stamp-$$";
  rename($target, $failed_store)
    or _deploy_throw('rollback', "Fehlgeschlagenes Erstdeploy konnte nicht gesichert werden: $!");
  _fsync_dir($failed_store);
  return $failed_store;
}

sub _read_deploy_status {
  my ($id) = @_;
  return undef unless _safe_deploy_id($id);
  my $file = "$git_status_root/$id.json";
  return undef unless -f $file && !-l $file;
  my $raw = eval { read_all($file) };
  return undef if $@;
  my $j = eval { decode_json($raw) };
  return ref($j) eq 'HASH' ? $j : undef;
}

sub _write_deploy_status {
  my ($id, $data) = @_;
  _deploy_throw('status', 'Ungueltige Deployment-ID') unless _safe_deploy_id($id);
  _ensure_managed_dir($git_status_root, 0770);
  my $file = "$git_status_root/$id.json";
  my $json = encode_json($data);
  eval { safe_write_file($file, $json, 1); 1 }
    or _deploy_throw('status', "Status konnte nicht geschrieben werden: $@");
  return $file;
}

sub _valid_git_commit_id {
  my ($value) = @_;
  return undef unless defined($value) && !ref($value)
    && $value =~ /^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$/;
  return lc($value);
}

# Liest den aktuellen Commit des im Profil erlaubten Repository-Refs, ohne ein
# Deployment vorzubereiten oder den Git-Cache zu veraendern. Die Abfrage nutzt
# dieselben geschuetzten Git-/TLS-/Auth-Einstellungen wie ein Deploy.
sub _repository_commit_status {
  my ($id, $request_token) = @_;
  _deploy_throw('repository_status', 'Ungueltige Deployment-ID') unless _safe_deploy_id($id);
  my $profile = $git_profiles_raw->{$id};
  _deploy_throw('repository_status', "Unbekanntes Deployment-Profil: $id") unless ref($profile) eq 'HASH';
  _deploy_throw('repository_status', "Deployment-Profil ist deaktiviert: $id")
    if exists($profile->{enabled}) && !$profile->{enabled};

  my $git_url = $profile->{git_url};
  my $allowed_ref = $profile->{allowed_ref};
  _deploy_throw('repository_status', 'git_url fehlt im Deployment-Profil')
    unless defined($git_url) && !ref($git_url) && length($git_url);
  _deploy_throw('repository_status', 'allowed_ref fehlt oder ist ungueltig')
    unless defined($allowed_ref) && !ref($allowed_ref)
      && $allowed_ref =~ m{^refs/(?:heads|tags)/[A-Za-z0-9._/-]+$}
      && $allowed_ref !~ m{(?:^|/)\.\.(?:/|$)};
  my $token;
  if ($git_deploy_token_source eq 'request') {
    _deploy_throw('repository_status', 'Repository-Status erfordert ein kurzlebiges Deploy-Token')
      unless defined($request_token) && !ref($request_token) && length($request_token);
    $token = $request_token;
  } else {
    $token = _read_deploy_token_file();
  }
  my ($auth_env, $secrets) = _git_env_with_auth($profile, $token);
  my $timeout = $git_timeout > 30 ? 30 : $git_timeout;
  $timeout = 5 if $timeout < 5;
  my $result = _deploy_run_command(
    stage=>'repository_status',
    argv=>[$git_bin, 'ls-remote', $git_url, $allowed_ref, "$allowed_ref^{}"],
    timeout=>$timeout, env=>$auth_env, secrets=>$secrets,
  );

  my ($direct, $peeled);
  for my $line (split /\n/, ($result->{stdout} // '')) {
    my ($sha, $ref) = $line =~ /^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})\t(.+)$/;
    next unless defined $sha;
    $direct = lc($sha) if $ref eq $allowed_ref;
    $peeled = lc($sha) if $ref eq "$allowed_ref^{}";
  }
  my $commit = $peeled // $direct;
  _deploy_throw('repository_status', "Repository-Ref nicht gefunden: $allowed_ref") unless defined $commit;

  return {
    repository_commit=>$commit,
    allowed_ref=>$allowed_ref,
    git_url=>$git_url,
  };
}

sub _run_preflight {
  my ($profile, $release, $commit, $target, $secrets) = @_;
  my $spec = $profile->{preflight};
  return {type=>'none', ok=>1} unless ref($spec) eq 'HASH';
  my $argv = _expand_fixed_argv($spec->{argv}, $release, $commit, $target);
  my $timeout = (defined $spec->{timeout} && $spec->{timeout} =~ /^\d+$/) ? 0 + $spec->{timeout} : 60;
  my $cwd = $release;
  if (defined $spec->{cwd} && length $spec->{cwd}) {
    my $x = $spec->{cwd};
    $x =~ s/\{release\}/$release/g;
    $x =~ s/\{commit\}/$commit/g;
    $x =~ s/\{target\}/$target/g;
    $cwd = _normalize_abs_lexical($x);
    _deploy_throw('preflight', "Preflight-cwd verlaesst Release: $cwd") unless _path_is_within($cwd, $release) && -d $cwd;
  }
  my $res = _deploy_run_command(
    stage=>'preflight', argv=>$argv, cwd=>$cwd, timeout=>$timeout,
    env=>_git_base_env(), secrets=>$secrets,
  );
  return {type=>'exec', ok=>1, rc=>$res->{rc}, stdout=>$res->{stdout}, stderr=>$res->{stderr}};
}

sub _validate_preflight_spec_or_throw {
  my ($spec, $label) = @_;
  $label //= 'preflight';
  return unless defined $spec;
  _deploy_throw('validation', "$label muss ein JSON-Objekt sein") unless ref($spec) eq 'HASH';
  _known_keys_or_throw($spec, [qw(argv cwd timeout)], $label);
  my $argv = $spec->{argv};
  _deploy_throw('validation', "$label.argv muss ein nicht leeres Array sein")
    unless ref($argv) eq 'ARRAY' && @$argv;
  _deploy_throw('validation', "$label.argv darf hoechstens 64 Argumente enthalten") if @$argv > 64;
  for my $arg (@$argv) {
    _deploy_throw('validation', "$label.argv enthaelt einen ungueltigen Wert")
      if !defined($arg) || ref($arg) || $arg =~ /\0/ || length($arg) > 4096;
  }
  _deploy_throw('validation', "$label.argv[0] muss ein absolutes Programm sein")
    unless $argv->[0] =~ m{^/};
  _deploy_throw('validation', "$label.argv[0] ist nicht ausfuehrbar: $argv->[0]")
    unless -f $argv->[0] && -x $argv->[0] && !-l $argv->[0];
  my $cwd = $spec->{cwd} // '{release}';
  _deploy_throw('validation', "$label.cwd muss innerhalb von {release} liegen")
    unless defined($cwd) && !ref($cwd) && $cwd =~ m{^\{release\}(?:/.*)?$} &&
           $cwd !~ m{(?:^|/)\.\.(?:/|$)} && $cwd !~ /\0/;
  _uint_or_throw($spec->{timeout}, "$label.timeout", 1, 900) if exists $spec->{timeout};
}

sub _validate_healthcheck_spec_or_throw {
  my ($profile, $label) = @_;
  $label //= 'healthcheck';
  return unless exists $profile->{healthcheck};
  my $hc = $profile->{healthcheck};
  _deploy_throw('validation', "$label muss ein JSON-Objekt sein") unless ref($hc) eq 'HASH';
  _known_keys_or_throw($hc, [qw(type argv timeout wait_seconds)], $label);
  my $type = lc($hc->{type} // '');
  _deploy_throw('validation', "$label.type muss none, systemd oder exec sein")
    unless $type =~ /^(?:none|systemd|exec)$/;
  if ($type eq 'systemd') {
    _deploy_throw('validation', "$label.type=systemd benoetigt restart_service")
      unless defined($profile->{restart_service}) && length($profile->{restart_service});
  }
  if ($type eq 'exec') {
    my $argv = $hc->{argv};
    _deploy_throw('validation', "$label.argv muss fuer type=exec ein nicht leeres Array sein")
      unless ref($argv) eq 'ARRAY' && @$argv;
    _deploy_throw('validation', "$label.argv darf hoechstens 64 Argumente enthalten") if @$argv > 64;
    for my $arg (@$argv) {
      _deploy_throw('validation', "$label.argv enthaelt einen ungueltigen Wert")
        if !defined($arg) || ref($arg) || $arg =~ /\0/ || length($arg) > 4096;
    }
    _deploy_throw('validation', "$label.argv[0] muss ein absolutes Programm sein")
      unless $argv->[0] =~ m{^/};
    _deploy_throw('validation', "$label.argv[0] ist nicht ausfuehrbar: $argv->[0]")
      unless -f $argv->[0] && -x $argv->[0] && !-l $argv->[0];
  } elsif (exists $hc->{argv}) {
    _deploy_throw('validation', "$label.argv ist nur fuer type=exec erlaubt");
  }
  _uint_or_throw($hc->{timeout}, "$label.timeout", 1, 900) if exists $hc->{timeout};
  if (exists $hc->{wait_seconds}) {
    my $wait = $hc->{wait_seconds};
    _deploy_throw('validation', "$label.wait_seconds muss zwischen 0 und 60 liegen")
      unless defined($wait) && !ref($wait) && "$wait" =~ /^\d+(?:\.\d+)?$/ && $wait >= 0 && $wait <= 60;
  }
}

sub _post_deploy_spec_or_throw {
  my ($profile, $label) = @_;
  $label //= 'Profil';
  my $spec = $profile->{post_deploy};
  return undef unless defined $spec;
  $spec = _normalize_post_deploy($spec) unless ref($spec) eq 'HASH' && ref($spec->{argv}) eq 'ARRAY';

  my $argv = $spec->{argv};
  _deploy_throw('validation', "$label: post_deploy.argv muss ein nicht leeres Array sein")
    unless ref($argv) eq 'ARRAY' && @$argv;
  _deploy_throw('validation', "$label: post_deploy.argv darf hoechstens 64 Argumente enthalten") if @$argv > 64;
  for my $arg (@$argv) {
    _deploy_throw('validation', "$label: post_deploy.argv enthaelt einen ungueltigen Wert")
      if !defined($arg) || ref($arg) || $arg =~ /\0/ || length($arg) > 4096;
  }
  my $program = $argv->[0];
  _deploy_throw('validation', "$label: post_deploy-Programm muss innerhalb des aktiven Releases liegen")
    unless $program =~ m{^\{(?:release|target)\}/[^/]} && $program !~ m{(?:^|/)\.\.(?:/|$)};

  my $cwd = $spec->{cwd} // '{release}';
  _deploy_throw('validation', "$label: post_deploy.cwd muss innerhalb des aktiven Releases liegen")
    unless !ref($cwd) && $cwd =~ m{^\{(?:release|target)\}(?:/.*)?$} && $cwd !~ m{(?:^|/)\.\.(?:/|$)} && $cwd !~ /\0/;
  my $timeout = $spec->{timeout};
  _deploy_throw('validation', "$label: post_deploy.timeout muss zwischen 1 und 900 Sekunden liegen")
    unless defined($timeout) && !ref($timeout) && "$timeout" =~ /^\d+$/ && $timeout >= 1 && $timeout <= 900;
  return $spec;
}

sub _run_post_deploy {
  my ($profile, $release, $commit, $target, $stage, $secrets, $rollback) = @_;
  my $spec = _post_deploy_spec_or_throw($profile, 'Deployment-Profil');
  return {type=>'none', ok=>1, skipped=>1} unless $spec;
  return {type=>'exec', ok=>1, skipped=>1, reason=>'run_on_rollback=false'}
    if $rollback && !$spec->{run_on_rollback};

  my $argv = _expand_fixed_argv($spec->{argv}, $release, $commit, $target, {allow_nonexec_shell=>1});
  my $release_real = eval { path($release)->realpath->to_string };
  my $program_real = eval { path($argv->[0])->realpath->to_string };
  _deploy_throw($stage, "Aktives Release ist nicht aufloesbar: $release")
    unless defined($release_real) && -d $release_real;
  _deploy_throw($stage, "post_deploy-Programm fehlt oder ist nicht aufloesbar: $argv->[0]")
    unless defined($program_real) && -f $program_real && !-l $argv->[0];
  _deploy_throw($stage, "post_deploy-Programm verlaesst das aktive Release: $argv->[0]")
    unless _path_is_within($program_real, $release_real);

  # Forgejo Contents-API erzeugt Dateien regulaer als 0644. Fuer kontrollierte
  # Shell-Hooks innerhalb des aktiven Releases darf Git Deploy deshalb eine
  # nicht-ausfuehrbare *.sh Datei explizit ueber /bin/bash starten. Andere
  # post_deploy-Programme muessen weiterhin executable sein.
  if (!-x $program_real) {
    _deploy_throw($stage, "post_deploy-Programm ist nicht ausfuehrbar: $argv->[0]")
      unless $program_real =~ /\.sh\z/;
    $argv = ['/bin/bash', $program_real, @$argv[1..$#$argv]];
  }

  my $cwd = $spec->{cwd} // '{release}';
  $cwd =~ s/\{release\}/$release/g;
  $cwd =~ s/\{commit\}/$commit/g;
  $cwd =~ s/\{target\}/$target/g;
  $cwd = _normalize_abs_lexical($cwd);
  my $cwd_real = eval { path($cwd)->realpath->to_string };
  _deploy_throw($stage, "post_deploy-cwd fehlt oder ist nicht aufloesbar: $cwd")
    unless defined($cwd_real) && -d $cwd_real;
  _deploy_throw($stage, "post_deploy-cwd verlaesst das aktive Release: $cwd")
    unless _path_is_within($cwd_real, $release_real);

  my $res = _deploy_run_command(
    stage=>$stage, argv=>$argv, cwd=>$cwd, timeout=>0 + $spec->{timeout},
    env=>_git_base_env(), secrets=>$secrets,
  );
  return {
    type=>'exec', ok=>1, skipped=>0, rc=>$res->{rc},
    stdout=>$res->{stdout}, stderr=>$res->{stderr},
    run_on_rollback=>($spec->{run_on_rollback} ? 1 : 0),
  };
}

sub _systemctl_argv {
  return ($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''));
}

sub _restart_service {
  my ($service, $profile, $stage, $secrets) = @_;
  return {skipped=>1} unless defined $service && length $service;
  _validate_restart_service_or_throw($service);
  _deploy_throw($stage, "systemctl nicht ausfuehrbar: $SYSTEMCTL") unless $SYSTEMCTL =~ m{^/} && -x $SYSTEMCTL;
  my @ctl = _systemctl_argv();
  if ($profile->{daemon_reload}) {
    _deploy_run_command(stage=>"${stage}_daemon_reload", argv=>[@ctl, 'daemon-reload'], timeout=>60, env=>_git_base_env(), secrets=>$secrets);
  }
  my $res = _deploy_run_command(stage=>$stage, argv=>[@ctl, 'restart', $service], timeout=>60, env=>_git_base_env(), secrets=>$secrets);
  return {skipped=>0, rc=>$res->{rc}};
}

sub _stop_service {
  my ($service, $stage, $secrets) = @_;
  return {skipped=>1} unless defined $service && length $service;
  _validate_restart_service_or_throw($service);
  my @ctl = _systemctl_argv();
  my $res = _deploy_run_command(
    stage=>$stage, argv=>[@ctl, 'stop', $service], timeout=>60,
    env=>_git_base_env(), secrets=>$secrets,
  );
  return {skipped=>0, rc=>$res->{rc}};
}

sub _run_healthcheck {
  my ($profile, $service, $release, $commit, $target, $stage, $secrets) = @_;
  my $hc = ref($profile->{healthcheck}) eq 'HASH' ? $profile->{healthcheck} : undef;
  my $type = $hc ? lc($hc->{type} // '') : (defined($service) && length($service) ? 'systemd' : 'none');
  $type = 'none' unless length $type;
  my $wait = $hc && defined($hc->{wait_seconds}) && $hc->{wait_seconds} =~ /^\d+(?:\.\d+)?$/
    ? 0 + $hc->{wait_seconds} : ($type eq 'systemd' ? 2 : 0);
  $wait = 60 if $wait > 60;
  sleep($wait) if $wait > 0;

  if ($type eq 'none') {
    return {type=>'none', ok=>1};
  }
  if ($type eq 'systemd') {
    _deploy_throw($stage, 'systemd-Healthcheck benoetigt restart_service') unless defined $service && length $service;
    my @ctl = _systemctl_argv();
    my $res = _deploy_run_command(
      stage=>$stage, argv=>[@ctl, 'is-active', '--quiet', $service],
      timeout=>30, env=>_git_base_env(), secrets=>$secrets,
    );
    return {type=>'systemd', ok=>1, rc=>$res->{rc}, wait_seconds=>$wait};
  }
  if ($type eq 'exec') {
    my $argv = _expand_fixed_argv($hc->{argv}, $release, $commit, $target);
    my $timeout = (defined $hc->{timeout} && $hc->{timeout} =~ /^\d+$/) ? 0 + $hc->{timeout} : 30;
    my $cwd = $target;
    my $res = _deploy_run_command(
      stage=>$stage, argv=>$argv, cwd=>$cwd, timeout=>$timeout,
      env=>_git_base_env(), secrets=>$secrets,
    );
    return {type=>'exec', ok=>1, rc=>$res->{rc}, stdout=>$res->{stdout}, stderr=>$res->{stderr}, wait_seconds=>$wait};
  }
  _deploy_throw('validation', "Unbekannter Healthcheck-Typ: $type");
}

sub _cleanup_old_releases {
  my ($releases_dir, $current_release, $keep, $preserve) = @_;
  $keep = 2 unless defined($keep) && "$keep" =~ /^\d+$/ && $keep >= 2;
  $preserve = [] unless ref($preserve) eq 'ARRAY';
  my %must_keep = map { $_ => 1 } grep { defined($_) && length($_) } ($current_release, @$preserve);

  opendir(my $dh, $releases_dir) or return {removed=>[], error=>"opendir fehlgeschlagen: $!"};
  my @dirs;
  while (defined(my $name = readdir($dh))) {
    next if $name =~ /^\./;
    my $p = "$releases_dir/$name";
    next unless -d $p && !-l $p;
    my $mtime = (stat($p))[9] // 0;
    push @dirs, [$p, $mtime];
  }
  closedir $dh;
  @dirs = sort { $b->[1] <=> $a->[1] || $b->[0] cmp $a->[0] } @dirs;

  my @removed;
  my %kept;
  my $kept_count = 0;
  # Aktives und unmittelbar vorheriges erfolgreiches Release haben Vorrang,
  # auch wenn ein fehlgeschlagenes Release einen neueren mtime besitzt.
  for my $item (@dirs) {
    my $p = $item->[0];
    next unless $must_keep{$p};
    $kept{$p} = 1;
    $kept_count++;
  }
  for my $item (@dirs) {
    my $p = $item->[0];
    next if $kept{$p};
    if ($kept_count < $keep) {
      $kept{$p} = 1;
      $kept_count++;
      next;
    }
    my $err;
    remove_tree($p, {safe=>1, error=>\$err});
    if (!$err || !@$err) { push @removed, $p; }
  }
  return {removed=>\@removed, kept=>$kept_count};
}

sub _resolve_deploy_profile {
  my ($payload) = @_;
  _deploy_throw('validation', 'JSON-Body muss ein Objekt sein') unless ref($payload) eq 'HASH';
  my $id = $payload->{deployment};
  my $profile;

  if (defined $id && length $id) {
    _deploy_throw('validation', 'Ungueltige Deployment-ID') unless _safe_deploy_id($id);
    my $raw = $git_profiles_raw->{$id};
    _deploy_throw('validation', "Unbekanntes Deployment-Profil: $id") unless ref($raw) eq 'HASH';
    _deploy_throw('validation', "Deployment-Profil ist deaktiviert: $id") if exists($raw->{enabled}) && !$raw->{enabled};
    $profile = {%$raw, id=>$id};
    for my $forbidden (qw(git_url target_path releases_dir deploy_mode allowed_ref ref_policy deploy_user auth_scheme ca_info preserve_paths user group preflight post_deploy install packages package_repositories allow_repository_package_plan healthcheck immutable_permissions keep_releases require_signed_commit allow_symlinks reject_hardlinks reject_lfs_pointers daemon_reload repository branch tag ref target owner service preserve advanced format)) {
      _deploy_throw('validation', "$forbidden darf bei profilgebundenem Deploy nicht im Request stehen")
        if exists $payload->{$forbidden};
    }
    if (exists $payload->{restart_service}) {
      my $configured = $profile->{restart_service} // '';
      my $requested  = $payload->{restart_service} // '';
      _deploy_throw('validation', 'restart_service darf das Profil nicht ueberschreiben') unless $requested eq $configured;
    }
  } else {
    _deploy_throw('validation', 'Direkte Git-Deploy-Requests sind deaktiviert; deployment-ID erforderlich')
      unless $git_allow_direct_request;
    for my $required (qw(git_url target_path)) {
      _deploy_throw('validation', "$required fehlt") unless defined $payload->{$required} && !ref($payload->{$required}) && length $payload->{$required};
    }
    my $derived = 'direct-' . substr(sha256_hex(join("\0", map { $payload->{$_} // '' } qw(git_url target_path restart_service))), 0, 24);
    $id = $derived;
    $profile = {
      id=>$id,
      git_url=>$payload->{git_url}, target_path=>$payload->{target_path},
      allowed_ref=>$payload->{allowed_ref}, restart_service=>$payload->{restart_service},
      deploy_user=>$payload->{deploy_user}, auth_scheme=>$payload->{auth_scheme}, ca_info=>$payload->{ca_info},
    };
  }

  my $commit = $payload->{commit_sha};
  $commit = 'auto' unless defined($commit) && !ref($commit) && length($commit);
  _deploy_throw('validation', 'commit_sha muss auto oder eine vollstaendige SHA-1-/SHA-256-ID sein')
    unless !ref($commit) && ($commit eq 'auto' || $commit =~ /^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$/);
  $commit = lc($commit);
  if ($commit eq 'auto') {
    my $auto_ref = $profile->{allowed_ref};
    _deploy_throw('validation', 'Automatische Commit-Auswahl erfordert allowed_ref im Deployment-Profil')
      unless defined($auto_ref) && !ref($auto_ref) && length($auto_ref);
  }
  my $token;
  if ($git_deploy_token_source eq 'request') {
    $token = $payload->{deploy_token};
    _deploy_throw('validation', 'deploy_token fehlt')
      unless defined($token) && !ref($token) && length($token);
  } else {
    # Im Standardmodus wird ein eventuell mitgesendetes Browser-Token bewusst
    # ignoriert. Die geschuetzte lokale Datei ist die einzige Credential-Quelle.
    $token = _read_deploy_token_file();
  }

  my $actor = $payload->{requested_by};
  $actor = '' unless defined($actor) && !ref($actor);
  $actor =~ s/[\x00-\x1f\x7f]/?/g;
  $actor = substr($actor, 0, 128);
  return ($id, $profile, $commit, $token, $actor);
}

sub _validate_git_config_hash {
  my ($cfg) = @_;
  _deploy_throw('validation', 'Effektive Git-Konfiguration muss ein JSON-Objekt enthalten') unless ref($cfg) eq 'HASH';

  _known_keys_or_throw($cfg, [qw(
    enabled allow_direct_request require_api_token require_ip_acl
    require_path_guard_enforce require_allowed_ref allow_proxy_env allow_http
    verify_tls deploy_token_source deploy_token_file git_bin tar_bin mv_bin
    state_dir timeout keep_releases max_files max_bytes deploy_user auth_scheme
    ca_info allowed_git_hosts path_guard allowed_roots profiles schema_version
  )], 'git_deploy');

  for my $key (qw(
    enabled allow_direct_request require_api_token require_ip_acl
    require_path_guard_enforce require_allowed_ref allow_proxy_env allow_http verify_tls
  )) {
    _json_bool_or_throw($cfg->{$key}, "git_deploy.$key") if exists $cfg->{$key};
  }

  _uint_or_throw($cfg->{timeout}, 'git_deploy.timeout', 1, 3600) if exists $cfg->{timeout};
  _uint_or_throw($cfg->{keep_releases}, 'git_deploy.keep_releases', 2, 100) if exists $cfg->{keep_releases};
  _uint_or_throw($cfg->{max_files}, 'git_deploy.max_files', 1, 1_000_000) if exists $cfg->{max_files};
  _uint_or_throw($cfg->{max_bytes}, 'git_deploy.max_bytes', 1, 1_099_511_627_776) if exists $cfg->{max_bytes};

  for my $bin_key (qw(git_bin tar_bin mv_bin)) {
    next unless exists $cfg->{$bin_key};
    my $bin = $cfg->{$bin_key};
    _deploy_throw('validation', "git_deploy.$bin_key muss ein absoluter Pfad sein")
      unless defined($bin) && !ref($bin) && $bin =~ m{^/} && $bin !~ /\0/;
    _deploy_throw('validation', "git_deploy.$bin_key ist nicht ausfuehrbar: $bin")
      if ($cfg->{enabled} ? 1 : 0) && (!-f $bin || !-x $bin || -l $bin);
  }

  if (exists $cfg->{auth_scheme}) {
    my $scheme = lc($cfg->{auth_scheme} // '');
    _deploy_throw('validation', 'git_deploy.auth_scheme muss basic, bearer oder token sein')
      unless !ref($cfg->{auth_scheme}) && $scheme =~ /^(?:basic|bearer|token)$/;
    if (($cfg->{enabled} ? 1 : 0) && $scheme eq 'basic') {
      my $user = $cfg->{deploy_user};
      _deploy_throw('validation', 'git_deploy.deploy_user fehlt fuer auth_scheme=basic')
        unless defined($user) && !ref($user) && $user =~ /^[A-Za-z0-9_.\@+-]{1,128}$/;
    }
  }

  my $enabled = $cfg->{enabled} ? 1 : 0;
  my $require_guard = exists($cfg->{require_path_guard_enforce})
    ? ($cfg->{require_path_guard_enforce} ? 1 : 0) : 1;
  my $require_ref = exists($cfg->{require_allowed_ref})
    ? ($cfg->{require_allowed_ref} ? 1 : 0) : 1;
  my $guard = lc($cfg->{path_guard} // 'off');
  _deploy_throw('validation', 'path_guard muss off, audit oder enforce sein')
    unless $guard =~ /^(?:off|audit|enforce)$/;

  my $roots = ref($cfg->{allowed_roots}) eq 'ARRAY' ? $cfg->{allowed_roots} : [];
  my @normalized_roots;
  for my $root (@$roots) {
    _deploy_throw('validation', 'allowed_roots enthaelt einen ungueltigen Wert')
      unless defined($root) && !ref($root) && $root =~ m{^/} && $root !~ /\0/;
    my $norm = eval { _normalize_abs_lexical($root) };
    _deploy_throw('validation', "allowed_root ungueltig: $root") unless defined $norm;
    my $real = eval { path($norm)->realpath->to_string };
    _deploy_throw('validation', "allowed_root fehlt oder ist nicht aufloesbar: $norm")
      unless defined($real) && -d $real && !-l $norm;
    push @normalized_roots, $real;
  }
  if ($enabled && $require_guard) {
    _deploy_throw('validation', 'Bei aktiviertem Git-Deploy muss path_guard=enforce gesetzt sein')
      unless $guard eq 'enforce';
    _deploy_throw('validation', 'Bei aktiviertem Git-Deploy muss allowed_roots mindestens einen existierenden Pfad enthalten')
      unless @normalized_roots;
  }

  my $state_dir_raw = $cfg->{state_dir} // "$tmpDir/git-deploy";
  _deploy_throw('validation', 'state_dir muss ein absoluter Pfad sein')
    unless defined($state_dir_raw) && !ref($state_dir_raw) && $state_dir_raw =~ m{^/} && $state_dir_raw !~ /\0/;
  my $state_dir = eval { _normalize_abs_lexical($state_dir_raw) };
  _deploy_throw('validation', 'state_dir ist ungueltig oder darf nicht / sein')
    unless defined($state_dir) && $state_dir ne '/';

  my $hosts = ref($cfg->{allowed_git_hosts}) eq 'ARRAY' ? $cfg->{allowed_git_hosts} : [];
  my %allowed_hosts;
  for my $entry (@$hosts) {
    _deploy_throw('validation', 'allowed_git_hosts enthaelt einen ungueltigen Wert')
      unless defined($entry) && !ref($entry) && length($entry) && $entry !~ /[\x00-\x20\x7f]/;
    my $x = lc($entry);
    $x =~ s{^https?://}{};
    $x =~ s{/$}{};
    $x .= ':443' unless $x =~ /:\d+$/;
    _deploy_throw('validation', "Ungueltiger allowed_git_hosts-Eintrag: $entry")
      unless $x =~ /^[a-z0-9.-]+:\d+$/;
    $allowed_hosts{$x} = 1;
  }
  _deploy_throw('validation', 'Bei aktiviertem Git-Deploy muss allowed_git_hosts gesetzt sein')
    if $enabled && !%allowed_hosts;

  my $token_source = lc($cfg->{deploy_token_source} // 'file');
  _deploy_throw('validation', 'deploy_token_source muss file oder request sein')
    unless $token_source eq 'file' || $token_source eq 'request';
  if ($enabled && $token_source eq 'file') {
    my $token_file = $cfg->{deploy_token_file} // '/opt/service/env/forgejo-api.token';
    _deploy_throw('validation', 'deploy_token_file muss ein absoluter Pfad sein')
      unless defined($token_file) && !ref($token_file) && $token_file =~ m{^/} && $token_file !~ /\0/;
    _deploy_throw('validation', "Deploy-Token-Datei fehlt oder ist nicht lesbar: $token_file")
      unless -f $token_file && -r $token_file && !-l $token_file;
    my @token_st = stat($token_file);
    _deploy_throw('validation', "Deploy-Token-Datei kann nicht geprueft werden: $token_file") unless @token_st;
    my $token_mode = S_IMODE($token_st[2]);
    _deploy_throw('validation', sprintf('Deploy-Token-Datei muss vor Gruppe/Anderen geschuetzt sein: %s (Modus %04o)', $token_file, $token_mode))
      if $token_mode & 0077;
  }

  my $profiles = ref($cfg->{profiles}) eq 'HASH' ? $cfg->{profiles} : {};
  my $preserve_path_count = 0;
  _deploy_throw('validation', 'profiles muss ein JSON-Objekt sein') if exists($cfg->{profiles}) && ref($cfg->{profiles}) ne 'HASH';
  for my $id (sort keys %$profiles) {
    _deploy_throw('validation', "Ungueltige Deployment-ID: $id") unless _safe_deploy_id($id);
    my $raw_profile = $profiles->{$id};
    _deploy_throw('validation', "Profil $id muss ein JSON-Objekt sein") unless ref($raw_profile) eq 'HASH';

    _known_keys_or_throw($raw_profile, [qw(
      enabled repository branch tag ref target owner group service preserve preflight
      post_deploy install packages package_repositories allow_repository_package_plan advanced format git_url target_path releases_dir deploy_mode
      allowed_ref ref_policy restart_service deploy_user auth_scheme ca_info preserve_paths
      user healthcheck immutable_permissions keep_releases require_signed_commit allow_symlinks
      reject_hardlinks reject_lfs_pointers daemon_reload max_files max_bytes
      max_tree_listing_bytes require_diff_preview config_schema
    )], "Profil $id");

    for my $key (qw(
      enabled immutable_permissions require_signed_commit allow_symlinks reject_hardlinks
      reject_lfs_pointers daemon_reload require_diff_preview
    )) {
      _json_bool_or_throw($raw_profile->{$key}, "Profil $id: $key") if exists $raw_profile->{$key};
    }
    _uint_or_throw($raw_profile->{keep_releases}, "Profil $id: keep_releases", 2, 100)
      if exists $raw_profile->{keep_releases};
    _uint_or_throw($raw_profile->{max_files}, "Profil $id: max_files", 1, 1_000_000)
      if exists $raw_profile->{max_files};
    _uint_or_throw($raw_profile->{max_bytes}, "Profil $id: max_bytes", 1, 1_099_511_627_776)
      if exists $raw_profile->{max_bytes};
    _uint_or_throw($raw_profile->{max_tree_listing_bytes}, "Profil $id: max_tree_listing_bytes", 1_048_576, 268_435_456)
      if exists $raw_profile->{max_tree_listing_bytes};

    if (ref($raw_profile->{advanced}) eq 'HASH') {
      _known_keys_or_throw($raw_profile->{advanced}, [qw(
        enabled git_url target_path releases_dir deploy_mode allowed_ref ref_policy
        restart_service deploy_user auth_scheme ca_info preserve_paths user group
        preflight post_deploy packages package_repositories allow_repository_package_plan healthcheck immutable_permissions keep_releases
        require_signed_commit allow_symlinks reject_hardlinks reject_lfs_pointers
        daemon_reload max_files max_bytes max_tree_listing_bytes require_diff_preview
        config_schema
      )], "Profil $id: advanced");
    }

    my $p = eval { _normalize_deploy_profile($id, $raw_profile) };
    _deploy_throw('validation', "Profil $id konnte nicht normalisiert werden: $@") unless ref($p) eq 'HASH';
    for my $key (qw(
      enabled immutable_permissions require_signed_commit allow_symlinks reject_hardlinks
      reject_lfs_pointers daemon_reload require_diff_preview
    )) {
      _json_bool_or_throw($p->{$key}, "Profil $id: $key") if exists $p->{$key};
    }
    next if exists($p->{enabled}) && !$p->{enabled};

    my $deploy_mode = lc($p->{deploy_mode} // 'symlink_release');
    my $preserve_specs = _preserve_specs_or_throw($p, "Profil $id");
    $preserve_path_count += scalar(@$preserve_specs);
    _deploy_throw('validation', "Profil $id: deploy_mode muss symlink_release oder directory_swap sein")
      unless $deploy_mode eq 'symlink_release' || $deploy_mode eq 'directory_swap';

    for my $required (qw(git_url target_path)) {
      _deploy_throw('validation', "Profil $id: $required fehlt")
        unless defined($p->{$required}) && !ref($p->{$required}) && length($p->{$required});
    }
    my $u = eval { Mojo::URL->new($p->{git_url}) };
    _deploy_throw('validation', "Profil $id: git_url ist ungueltig") unless $u;
    my $scheme = lc($u->scheme // '');
    _deploy_throw('validation', "Profil $id: git_url muss HTTPS verwenden; HTTP ist nur mit allow_http=true erlaubt")
      unless $scheme eq 'https' || ($scheme eq 'http' && $cfg->{allow_http});
    _deploy_throw('validation', "Profil $id: Zugangsdaten in git_url sind verboten")
      if defined($u->userinfo) && length($u->userinfo // '');
    _deploy_throw('validation', "Profil $id: Query oder Fragment in git_url ist verboten")
      if length($u->query->to_string // '') || length($u->fragment // '');
    my $host = lc($u->host // '');
    my $port = $u->port // ($scheme eq 'http' ? 80 : 443);
    _deploy_throw('validation', "Profil $id: Git-Host ist nicht erlaubt: $host:$port")
      if %allowed_hosts && !$allowed_hosts{"$host:$port"};

    my $target = eval { _normalize_abs_lexical($p->{target_path}) };
    _deploy_throw('validation', "Profil $id: target_path ist ungueltig") unless defined $target && $target ne '/';
    if (@normalized_roots) {
      my $inside = 0;
      for my $root (@normalized_roots) { $inside = 1 if _path_is_within($target, $root); }
      _deploy_throw('validation', "Profil $id: target_path liegt nicht unter allowed_roots") unless $inside;
    }
    my $release;
    if (defined($p->{releases_dir}) && length($p->{releases_dir})) {
      $release = eval { _normalize_abs_lexical($p->{releases_dir}) };
      _deploy_throw('validation', "Profil $id: releases_dir ist ungueltig") unless defined $release && $release ne '/';
      if (@normalized_roots) {
        my $inside = 0;
        for my $root (@normalized_roots) { $inside = 1 if _path_is_within($release, $root); }
        _deploy_throw('validation', "Profil $id: releases_dir liegt nicht unter allowed_roots") unless $inside;
      }

      _deploy_throw('validation', "Profil $id: target_path und releases_dir duerfen nicht identisch sein")
        if $target eq $release;
      _deploy_throw('validation', "Profil $id: releases_dir darf nicht innerhalb von target_path liegen")
        if _path_is_within($release, $target);
      _deploy_throw('validation', "Profil $id: target_path darf nicht innerhalb von releases_dir liegen")
        if _path_is_within($target, $release);

      my $target_base  = path($target)->basename;
      my $release_base = path($release)->basename;
      if ($deploy_mode eq 'symlink_release' && ($target_base eq 'current' || $release_base eq 'releases')) {
        _deploy_throw('validation', "Profil $id: Das current/releases-Layout verlangt target_path .../current und releases_dir .../releases")
          unless $target_base eq 'current' && $release_base eq 'releases';
        my $target_parent  = path($target)->dirname->to_string;
        my $release_parent = path($release)->dirname->to_string;
        _deploy_throw('validation', "Profil $id: current und releases muessen unter demselben Anwendungs-Root liegen")
          unless $target_parent eq $release_parent;
      }
    }
    if ($deploy_mode eq 'directory_swap' && (!defined($p->{releases_dir}) || !length($p->{releases_dir}))) {
      _deploy_throw('validation', "Profil $id: directory_swap verlangt ein explizites releases_dir");
    }
    if ($deploy_mode eq 'directory_swap' && -l $target) {
      _deploy_throw('validation', "Profil $id: target_path darf bei directory_swap kein Symlink sein");
    }
    if ($require_ref) {
      _deploy_throw('validation', "Profil $id: allowed_ref fehlt")
        unless defined($p->{allowed_ref}) && !ref($p->{allowed_ref}) && $p->{allowed_ref} =~ m{^refs/(?:heads|tags)/[^\s\x00-\x1f\x7f]+$};
    }
    my $ref_policy = lc($p->{ref_policy} //
      ((defined($p->{allowed_ref}) && $p->{allowed_ref} =~ m{^refs/tags/}) ? 'exact' : 'ancestor'));
    _deploy_throw('validation', "Profil $id: ref_policy muss exact oder ancestor sein")
      unless $ref_policy eq 'exact' || $ref_policy eq 'ancestor';
    if (exists $p->{auth_scheme}) {
      my $scheme = lc($p->{auth_scheme} // '');
      _deploy_throw('validation', "Profil $id: auth_scheme muss basic, bearer oder token sein")
        unless !ref($p->{auth_scheme}) && $scheme =~ /^(?:basic|bearer|token)$/;
      if ($scheme eq 'basic') {
        my $user = $p->{deploy_user} // $cfg->{deploy_user};
        _deploy_throw('validation', "Profil $id: deploy_user fehlt fuer auth_scheme=basic")
          unless defined($user) && !ref($user) && $user =~ /^[A-Za-z0-9_.\@+-]{1,128}$/;
      }
    }
    _validate_restart_service_or_throw($p->{restart_service}) if defined $p->{restart_service};
    _validate_preflight_spec_or_throw($p->{preflight}, "Profil $id: preflight") if exists $p->{preflight};
    _post_deploy_spec_or_throw($p, "Profil $id") if exists $p->{post_deploy};
    _validate_healthcheck_spec_or_throw($p, "Profil $id: healthcheck");
    if (exists $p->{config_schema}) {
      _deploy_throw('validation', "Profil $id: config_schema muss ein JSON-Objekt sein") unless ref($p->{config_schema}) eq 'HASH';
      my $cs = $p->{config_schema};
      _deploy_throw('validation', "Profil $id: config_schema.file muss relativ sein")
        if defined($cs->{file}) && ($cs->{file} =~ m{^/} || $cs->{file} =~ m{(?:^|/)\.\.(?:/|$)});
    }
  }

  return {
    ok=>1,
    enabled=>$enabled,
    profile_count=>scalar(keys %$profiles),
    allowed_root_count=>scalar(@normalized_roots),
    allowed_host_count=>scalar(keys %allowed_hosts),
    preserve_path_count=>$preserve_path_count,
    state_dir=>$state_dir,
  };
}

sub _git_config_mode {
  my $raw = defined($global->{fileMode_service}) ? "$global->{fileMode_service}" : '0660';
  $raw =~ s/^0+//;
  return $raw =~ /^[0-7]{3,4}$/ ? oct($raw) : 0660;
}

sub _apply_git_config_meta {
  return unless -e $gitfile;
  die "git_deploy.json darf kein Symlink sein" if -l $gitfile;
  my $uid = _name2uid($global->{serviceUser});
  my $gid = _name2gid($global->{serviceGroup});
  chown(defined($uid) ? $uid : -1, defined($gid) ? $gid : -1, $gitfile)
    or die "chown($gitfile) fehlgeschlagen: $!" if defined($uid) || defined($gid);
  chmod(_git_config_mode(), $gitfile) or die "chmod($gitfile) fehlgeschlagen: $!";
}

sub _ensure_git_config_backup_dir {
  die "Git-Deploy-Backup-Verzeichnis darf kein Symlink sein: $git_config_backup_dir"
    if -l $git_config_backup_dir;
  if (-e $git_config_backup_dir && !-d $git_config_backup_dir) {
    die "Git-Deploy-Backup-Pfad ist kein Verzeichnis: $git_config_backup_dir";
  }
  if (!-d $git_config_backup_dir) {
    mkdir $git_config_backup_dir or die "Git-Deploy-Backup-Verzeichnis konnte nicht angelegt werden: $!";
    chmod(0770, $git_config_backup_dir);
  }
  return $git_config_backup_dir;
}

sub _create_git_config_backup {
  return undef unless -f $gitfile;
  die "git_deploy.json darf beim Backup kein Symlink sein" if -l $gitfile;
  my $dir = _ensure_git_config_backup_dir();
  my ($name, $file);
  for my $attempt (1..5) {
    $name = 'git_deploy.json.bak.' . _backup_timestamp();
    $file = "$dir/$name";
    last unless -e $file;
    Time::HiRes::sleep(0.001);
  }
  die "Backup-Datei kollidiert mehrfach" if !defined($file) || -e $file;
  path($gitfile)->copy_to($file);
  chmod(0660, $file);
  _rotate_backup_files($dir, 'git_deploy.json');
  return $name;
}

sub _list_git_config_backups {
  return [] unless -d $git_config_backup_dir;
  my @files = sort { $b cmp $a } grep { defined } glob("$git_config_backup_dir/git_deploy.json.bak.*");
  @files = map { s{^\Q$git_config_backup_dir\E/}{}r } @files;
  return \@files;
}


sub _ensure_git_settings_backup_dir {
  die "Git-Settings-Backup-Verzeichnis darf kein Symlink sein: $git_settings_backup_dir"
    if -l $git_settings_backup_dir;
  if (-e $git_settings_backup_dir && !-d $git_settings_backup_dir) {
    die "Git-Settings-Backup-Pfad ist kein Verzeichnis: $git_settings_backup_dir";
  }
  if (!-d $git_settings_backup_dir) {
    mkdir $git_settings_backup_dir or die "Git-Settings-Backup-Verzeichnis konnte nicht angelegt werden: $!";
    chmod(0770, $git_settings_backup_dir);
  }
  return $git_settings_backup_dir;
}

sub _create_git_settings_backup {
  my $dir = _ensure_git_settings_backup_dir();
  my ($name, $file);
  for my $attempt (1..5) {
    $name = 'git_deploy.settings.bak.' . _backup_timestamp();
    $file = "$dir/$name";
    last unless -e $file;
    Time::HiRes::sleep(0.001);
  }
  die "Git-Settings-Backup kollidiert mehrfach" if !defined($file) || -e $file;
  my $backup_value = exists($global->{git_deploy}) ? $global->{git_deploy} : {};
  safe_write_file($file, _pretty_json_text($backup_value), 1);
  chmod(0660, $file);
  _rotate_backup_files($dir, 'git_deploy.settings');
  return $name;
}

sub _list_git_settings_backups {
  return [] unless -d $git_settings_backup_dir;
  my @files = sort { $b cmp $a } grep { defined } glob("$git_settings_backup_dir/git_deploy.settings.bak.*");
  @files = map { s{^\Q$git_settings_backup_dir\E/}{}r } @files;
  return \@files;
}

sub _save_git_settings_section {
  my ($settings) = @_;
  die "Git-Einstellungen muessen ein JSON-Objekt sein" unless ref($settings) eq 'HASH';
  die "global.json darf kein Symlink sein" if -l $globalfile;
  my @st = stat($globalfile);
  die "global.json fehlt oder ist keine regulaere Datei" unless @st && -f $globalfile;

  my $fresh = eval { decode_json(read_all($globalfile)) };
  die "global.json konnte nicht neu geladen werden: $@" if $@ || ref($fresh) ne 'HASH';
  $fresh->{git_deploy} = $settings;
  safe_write_file($globalfile, _pretty_json_text($fresh), 1);
  chown($st[4], $st[5], $globalfile) or die "chown(global.json) fehlgeschlagen: $!";
  chmod(S_IMODE($st[2]), $globalfile) or die "chmod(global.json) fehlgeschlagen: $!";
  $global = $fresh;
  return 1;
}

sub _validate_git_settings_candidate {
  my ($settings, $with_profiles) = @_;
  _deploy_throw('validation', 'Git-Einstellungen muessen ein JSON-Objekt sein') unless ref($settings) eq 'HASH';
  _deploy_throw('validation', 'profiles gehoert nicht in global.json unter git_deploy') if exists $settings->{profiles};
  # Dieselbe Normalisierung wie beim Agent-Start verwenden. Damit ist ein
  # unveraenderter, kompakter global.json-Block auch im Validate/Save-Pfad
  # gueltig und Defaults (path_guard, auth_scheme, deploy_user, Forgejo-Host)
  # werden nicht erst nach dem Speichern sichtbar.
  my $normalized = eval { _normalize_git_settings({%$settings}) };
  _deploy_throw('validation', "Git-Einstellungen konnten nicht normalisiert werden: $@") if $@ || ref($normalized) ne 'HASH';
  my $profiles = $with_profiles ? $git_profiles_cfg : {profiles=>{}};
  return _validate_git_config_hash(_compose_git_config($normalized, $profiles));
}

sub _validate_git_profiles_candidate {
  my ($profiles_cfg) = @_;
  my $clean = _git_profiles_only_or_die($profiles_cfg);
  return (_validate_git_config_hash(_compose_git_config($git_settings_cfg, $clean)), $clean);
}

sub _git_deploy_execute {
  my ($id, $profile, $commit, $token, $actor, $payload) = @_;
  $payload = {} unless ref($payload) eq 'HASH';
  my $started = time();
  my $result;
  my $commit_source = ($commit eq 'auto') ? 'allowed_ref_head' : 'explicit_sha';

  my $ok = eval {
    _deploy_throw('disabled', 'Git-Deploy ist in global.json unter git_deploy nicht aktiviert') unless $git_deploy_enabled;
    _deploy_throw('validation', "git_bin nicht ausfuehrbar: $git_bin") unless $git_bin =~ m{^/} && -f $git_bin && -x $git_bin;
    _deploy_throw('validation', "tar_bin nicht ausfuehrbar: $tar_bin") unless $tar_bin =~ m{^/} && -f $tar_bin && -x $tar_bin;
    _deploy_throw('validation', "mv_bin nicht ausfuehrbar: $mv_bin") unless $mv_bin =~ m{^/} && -f $mv_bin && -x $mv_bin;

    my ($git_url) = _parse_git_url_or_throw($profile->{git_url});
    my $deploy_mode = lc($profile->{deploy_mode} // 'symlink_release');
    _deploy_throw('validation', 'deploy_mode muss symlink_release oder directory_swap sein')
      unless $deploy_mode eq 'symlink_release' || $deploy_mode eq 'directory_swap';
    my $target = _assert_deploy_path_allowed(
      $profile->{target_path}, 'target_path', ($deploy_mode eq 'symlink_release' ? 1 : 0)
    );
    my $target_parent = path($target)->dirname->to_string;
    _assert_no_symlink_components($target_parent, 1);

    my $base = path($target)->basename;
    my $releases_dir = $profile->{releases_dir} // "$target_parent/.${base}.releases";
    $releases_dir = _assert_deploy_path_allowed($releases_dir, 'releases_dir', 0, 1);
    _assert_no_symlink_components(path($releases_dir)->dirname->to_string, 1);

    my $allowed_ref = $profile->{allowed_ref};
    if ($git_require_allowed_ref) {
      _deploy_throw('validation', 'allowed_ref fehlt im Deployment-Profil')
        unless defined($allowed_ref) && !ref($allowed_ref) && $allowed_ref =~ m{^refs/(?:heads|tags)/[A-Za-z0-9._/-]+$};
    } elsif (defined $allowed_ref && length $allowed_ref) {
      _deploy_throw('validation', 'allowed_ref ist ungueltig')
        unless !ref($allowed_ref) && $allowed_ref =~ m{^refs/(?:heads|tags)/[A-Za-z0-9._/-]+$};
    }
    _deploy_throw('validation', 'allowed_ref enthaelt ..') if defined($allowed_ref) && $allowed_ref =~ m{(?:^|/)\.\.(?:/|$)};
    if (defined $allowed_ref && length $allowed_ref) {
      _deploy_run_command(
        stage=>'validation', argv=>[$git_bin, 'check-ref-format', $allowed_ref],
        timeout=>15, env=>_git_base_env(), secrets=>[],
      );
    }
    my $ref_policy = lc($profile->{ref_policy} //
      ((defined($allowed_ref) && $allowed_ref =~ m{^refs/tags/}) ? 'exact' : 'ancestor'));
    _deploy_throw('validation', 'ref_policy muss exact oder ancestor sein')
      unless $ref_policy eq 'exact' || $ref_policy eq 'ancestor';

    my $preserve_specs = _preserve_specs_or_throw($profile, "Profil $id");
    my $service = _validate_restart_service_or_throw($profile->{restart_service});
    my $cache_dir = "$git_cache_root/" . sha256_hex($git_url);
    my $remote_ref = "refs/config-manager/" . sha256_hex($id);
    my $keep = (defined $profile->{keep_releases} && $profile->{keep_releases} =~ /^\d+$/)
      ? 0 + $profile->{keep_releases} : $git_default_keep_releases;
    $keep = 2 if $keep < 2;

    _ensure_managed_dir($git_state_dir, 0770);
    _ensure_managed_dir($git_cache_root, 0770);
    _ensure_managed_dir($git_status_root, 0770);
    _ensure_managed_dir($git_home_dir, 0700);
    _ensure_managed_dir($releases_dir, 0770);
    _assert_same_filesystem($target_parent, $releases_dir) if $deploy_mode eq 'directory_swap';

    my ($auth_env, $secrets) = _git_env_with_auth($profile, $token);
    _probe_rename_exchange($releases_dir)
      if $deploy_mode eq 'directory_swap' && -d $target;
    my @locks = ($target, "git-cache:$cache_dir");
    push @locks, map { _normalize_abs_lexical("$target/$_->{path}") }
      grep { _preserve_policy_keeps_live($_) } @$preserve_specs;
    push @locks, "git-service:$service" if defined $service;

    _with_named_locks(\@locks, sub {
      my $previous_release = $deploy_mode eq 'symlink_release'
        ? _managed_current_release($target, $releases_dir)
        : ((-d $target && !-l $target) ? $target : undef);
      _deploy_throw('validation', "target_path ist bei directory_swap kein Verzeichnis: $target")
        if $deploy_mode eq 'directory_swap' && (-e $target || -l $target) && (!-d $target || -l $target);
      my $previous_status = _read_deploy_status($id) // {};
      my $previous_commit = $previous_status->{active_commit} //
        ($deploy_mode eq 'symlink_release' ? _commit_from_release_path($previous_release) : undef);
      my $action = $previous_release ? 'updated' : 'cloned';
      my $activated = 0;
      my $service_stopped = 0;
      my $new_release;
      my $incoming;
      my $tarfile;
      my $preflight;
      my $post_deploy;
      my $package_plan;
      my $repo_package_manifest;
      my $healthcheck;
      my $permission_seal;
      my $preserve_result;
      my $git_tree;
      my $final_tree;
      my $preview_verification = {required=>0, verified=>0};
      my $rollback = {attempted=>0, ok=>0};

      my $deploy_ok = eval {
        if (!-d $cache_dir) {
          _deploy_run_command(
            stage=>'git_init', argv=>[$git_bin, 'init', '--bare', $cache_dir],
            timeout=>$git_timeout, env=>_git_base_env(), secrets=>$secrets,
          );
        }
        _deploy_throw('git_cache', "Ungueltiger Bare-Cache: $cache_dir")
          unless -d $cache_dir && -d "$cache_dir/objects" && -f "$cache_dir/HEAD" && !-l $cache_dir;

        my @fetch = ($git_bin, "--git-dir=$cache_dir", 'fetch', '--force', '--no-tags', '--prune', $git_url);
        if (defined $allowed_ref && length $allowed_ref) {
          push @fetch, "$allowed_ref:$remote_ref";
        } else {
          push @fetch, $commit;
        }
        _deploy_run_command(stage=>'git_fetch', argv=>\@fetch, timeout=>$git_timeout, env=>$auth_env, secrets=>$secrets);

        if ($commit eq 'auto') {
          _deploy_throw('ref_resolve', 'Automatische Commit-Auswahl erfordert allowed_ref')
            unless defined($allowed_ref) && length($allowed_ref);
          my $resolved = _deploy_run_command(
            stage=>'ref_resolve', argv=>[$git_bin, "--git-dir=$cache_dir", 'rev-parse', "$remote_ref^{commit}"],
            timeout=>30, env=>_git_base_env(), secrets=>$secrets,
          );
          $commit = lc($resolved->{stdout} // '');
          $commit =~ s/\s+\z//;
          _deploy_throw('ref_resolve', 'Erlaubter Ref konnte nicht in eine vollstaendige Commit-ID aufgeloest werden')
            unless $commit =~ /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
        }

        _deploy_run_command(
          stage=>'commit_verify', argv=>[$git_bin, "--git-dir=$cache_dir", 'cat-file', '-e', "$commit^{commit}"],
          timeout=>30, env=>_git_base_env(), secrets=>$secrets,
        );
        if (defined $allowed_ref && length $allowed_ref) {
          if ($ref_policy eq 'exact') {
            my $resolved = _deploy_run_command(
              stage=>'ref_verify', argv=>[$git_bin, "--git-dir=$cache_dir", 'rev-parse', "$remote_ref^{commit}"],
              timeout=>30, env=>_git_base_env(), secrets=>$secrets,
            );
            my $ref_commit = lc($resolved->{stdout} // '');
            $ref_commit =~ s/\s+\z//;
            _deploy_throw('ref_verify', "Commit entspricht nicht exakt dem erlaubten Ref $allowed_ref")
              unless $ref_commit eq $commit;
          } else {
            _deploy_run_command(
              stage=>'ref_verify', argv=>[$git_bin, "--git-dir=$cache_dir", 'merge-base', '--is-ancestor', $commit, $remote_ref],
              timeout=>30, env=>_git_base_env(), secrets=>$secrets,
            );
          }
        }
        if ($profile->{require_signed_commit}) {
          _deploy_run_command(
            stage=>'signature_verify', argv=>[$git_bin, "--git-dir=$cache_dir", 'verify-commit', $commit],
            timeout=>60, env=>_git_base_env(), secrets=>$secrets,
          );
        }
        $repo_package_manifest = _load_repository_package_plan($cache_dir, $commit, $profile, $secrets);
        $preview_verification = _verify_and_consume_preview_token($id, $profile, $commit, $payload);
        $git_tree = _validate_git_tree($cache_dir, $commit, $profile, $secrets);

        my $stamp = localtime()->strftime('%Y%m%d_%H%M%S') . '_' . sprintf('%03d', int((time() - int(time())) * 1000));
        my $release_name = $commit . "-$stamp-$$";
        $incoming = "$releases_dir/.incoming-$release_name";
        $new_release = "$releases_dir/$release_name";
        _deploy_throw('filesystem', "Release existiert bereits: $new_release") if -e $incoming || -e $new_release;
        _ensure_managed_dir($incoming, 0770);

        my ($tfh, $tmp_tar) = tempfile('git-deploy-XXXXXX', DIR=>$git_state_dir, UNLINK=>0);
        close $tfh or _deploy_throw('archive', "Temp-Tar konnte nicht geschlossen werden: $!");
        $tarfile = $tmp_tar;
        _deploy_run_command(
          stage=>'archive', argv=>[$git_bin, "--git-dir=$cache_dir", 'archive', '--format=tar', "--output=$tarfile", $commit],
          timeout=>$git_timeout, env=>_git_base_env(), secrets=>$secrets,
        );
        _deploy_run_command(
          stage=>'extract', argv=>[$tar_bin, '-xf', $tarfile, '-C', $incoming, '--no-same-owner'],
          timeout=>$git_timeout, env=>_git_base_env(), secrets=>$secrets,
        );
        unlink $tarfile;
        undef $tarfile;

        my $tree = _scan_release_tree($incoming, $profile);
        _deploy_throw('release_validation', 'Extrahierter Dateibaum weicht vom Git-Baum ab')
          unless $tree->{files} == $git_tree->{files} && $tree->{bytes} == $git_tree->{bytes};
        _write_release_commit_marker($incoming, $commit);
        $preserve_result = _apply_preserve_paths($target, $incoming, $preserve_specs);
        # Preserve erfolgt, solange das Incoming-Verzeichnis noch sicher
        # beschreibbar ist. Die globale Release-Eigentuemeroperation laesst
        # anschliessend alle produktiv erhaltenen Unterbaeume unangetastet.
        _apply_release_owner($incoming, $profile, $preserve_specs);
        # Ohne Installations-Hook bleibt das bisherige Sicherheitsverhalten:
        # der Release wird bereits vor der Aktivierung schreibgeschuetzt.
        $permission_seal = _seal_release_permissions($incoming, $profile, $preserve_specs)
          unless exists $profile->{post_deploy};
        $final_tree = _scan_release_tree($incoming, $profile);
        my $preflight_fp_before = _tree_integrity_fingerprint($incoming, [], 0);
        $preflight = _run_preflight($profile, $incoming, $commit, $target, $secrets);
        my $preflight_fp_after = _tree_integrity_fingerprint($incoming, [], 0);
        _deploy_throw('preflight_integrity', 'Preflight hat den vorbereiteten Release veraendert')
          unless $preflight_fp_before->{sha256} eq $preflight_fp_after->{sha256};
        # Struktur-/Limitpruefung nach dem Preflight nochmals ausfuehren. Der
        # Fingerprint erkennt Inhalte/Metadaten; dieser Scan deckt zusaetzlich
        # die Deploy-spezifischen Dateityp- und Symlink-Regeln ab.
        $final_tree = _scan_release_tree($incoming, $profile);
        $package_plan = _run_package_plan($profile, $secrets);
        rename($incoming, $new_release) or _deploy_throw('filesystem', "Release-Finalisierung fehlgeschlagen: $!");
        undef $incoming;
        _fsync_dir($new_release);

        my $active_release;
        if ($deploy_mode eq 'symlink_release') {
          _atomic_symlink_switch($target, $new_release);
          $active_release = $new_release;
        } else {
          if (defined $service) {
            _stop_service($service, 'activate_stop', $secrets);
            $service_stopped = 1;
          }
          $previous_release = _directory_swap_activate(
            $target, $new_release, $releases_dir, $previous_commit, $secrets
          );
          $active_release = $target;
        }
        $activated = 1;
        $post_deploy = _run_post_deploy($profile, $active_release, $commit, $target, 'post_deploy', $secrets, 0);
        if (exists $profile->{post_deploy}) {
          # Der Installer darf den aktivierten Release noch gezielt vorbereiten
          # (z.B. systemd-Symlink/Unit). Erst danach wird der Release versiegelt.
          $permission_seal = _seal_release_permissions($active_release, $profile, $preserve_specs);
          $final_tree = _scan_release_tree($active_release, $profile);
        }
        my $restart = _restart_service($service, $profile, 'restart', $secrets);
        $service_stopped = 0 if defined $service;
        $healthcheck = _run_healthcheck($profile, $service, $active_release, $commit, $target, 'healthcheck', $secrets);

        my $status = {
          ok=>1, deployment=>$id, action=>$action, deploy_mode=>$deploy_mode, target_path=>$target, git_url=>$git_url,
          active_commit=>$commit, active_release=>$active_release,
          commit_source=>$commit_source, allowed_ref=>$allowed_ref,
          previous_commit=>$previous_commit, previous_release=>$previous_release,
          restart_service=>$service, healthcheck=>$healthcheck, preflight=>$preflight, post_deploy=>$post_deploy, package_plan=>$package_plan, repository_package_manifest=>$repo_package_manifest,
          immutable_permissions=>$permission_seal, preserve_paths=>$preserve_result,
          requested_by=>$actor, deployed_at=>gmtime()->datetime . 'Z',
          from_commit=>$previous_commit, to_commit=>$commit,
          deployment_direction=>(defined($previous_commit) && $previous_commit eq $commit ? 'same' : ($payload->{deployment_direction} // 'change')),
          diff_preview_required=>($preview_verification->{required} ? true() : false()),
          diff_preview_verified=>($preview_verification->{verified} ? true() : false()),
          (length($preview_verification->{token}//'') ? (diff_preview_token_sha256=>sha256_hex($preview_verification->{token})) : ()),
          diff_files_changed=>(0 + ($preview_verification->{files_changed} // $payload->{diff_files_changed} // 0)),
          duration_ms=>int((time()-$started)*1000),
        };
        _write_deploy_status($id, $status);
        my $cleanup = _cleanup_old_releases($releases_dir, ($deploy_mode eq 'symlink_release' ? $new_release : undef), $keep, [$previous_release]);
        $result = {%$status, commit=>$commit, restarted=>$service, release_stats=>$final_tree, git_tree_stats=>$git_tree, cleanup=>$cleanup};
        1;
      };

      unless ($deploy_ok) {
        my $failure = _deploy_error_hash($@);
        unlink $tarfile if defined($tarfile) && -e $tarfile;
        if (defined $incoming && -d $incoming && !-l $incoming) {
          my $rmerr;
          remove_tree($incoming, {safe=>1, error=>\$rmerr});
        }

        if ($activated || $service_stopped) {
          $rollback->{attempted} = 1;
          my $rb_ok = eval {
            if ($deploy_mode eq 'symlink_release') {
              if ($previous_release) {
                _atomic_symlink_switch($target, $previous_release);
                my $rb_commit = $previous_commit // '';
                $rollback->{post_deploy} = _run_post_deploy(
                  $profile, $previous_release, $rb_commit, $target, 'rollback_post_deploy', $secrets, 1
                );
                _restart_service($service, $profile, 'rollback_restart', $secrets);
                $rollback->{healthcheck} = _run_healthcheck(
                  $profile, $service, $previous_release, $rb_commit, $target, 'rollback_healthcheck', $secrets
                );
                $rollback->{active_release} = $previous_release;
                $rollback->{active_commit} = $previous_commit;
              } else {
                $rollback->{stop_result} = _stop_service($service, 'rollback_stop', $secrets) if defined $service;
                unlink($target) or _deploy_throw('rollback', "Erstdeploy-Symlink konnte nicht entfernt werden: $!") if -l $target;
                $rollback->{active_release} = undef;
                $rollback->{active_commit} = undef;
              }
            } else {
              _stop_service($service, 'rollback_stop', $secrets) if defined($service) && $activated;
              if ($activated) {
                $rollback->{failed_release} = _directory_swap_rollback(
                  $target, $previous_release, $releases_dir, $commit, $secrets
                );
              }
              if (defined($previous_release) || (!$activated && -d $target)) {
                my $rb_commit = $previous_commit // '';
                $rollback->{post_deploy} = _run_post_deploy(
                  $profile, $target, $rb_commit, $target, 'rollback_post_deploy', $secrets, 1
                ) if $activated && defined($previous_release);
                _restart_service($service, $profile, 'rollback_restart', $secrets) if defined $service;
                $rollback->{healthcheck} = _run_healthcheck(
                  $profile, $service, $target, $rb_commit, $target, 'rollback_healthcheck', $secrets
                );
                $rollback->{active_release} = $target;
                $rollback->{active_commit} = $previous_commit;
              } else {
                $rollback->{active_release} = undef;
                $rollback->{active_commit} = undef;
              }
            }
            1;
          };
          if ($rb_ok) {
            $rollback->{ok} = 1;
          } else {
            $rollback->{ok} = 0;
            $rollback->{error} = _deploy_error_hash($@);
          }
        }

        my $failed_status = {
          ok=>0, deployment=>$id, deploy_mode=>$deploy_mode, target_path=>$target, git_url=>$git_url,
          requested_commit=>$commit,
          active_commit=>(!$activated ? $previous_commit : ($rollback->{ok} ? $previous_commit : undef)),
          active_release=>(!$activated ? $previous_release : ($rollback->{ok} ? $previous_release : undef)),
          previous_commit=>$previous_commit, restart_service=>$service,
          (defined($preserve_result) ? (preserve_paths=>$preserve_result) : ()),
          error_stage=>$failure->{stage}, error=>$failure->{message},
          rc=>$failure->{rc}, stdout=>$failure->{stdout}, stderr=>$failure->{stderr},
          rollback=>$rollback, requested_by=>$actor, failed_at=>gmtime()->datetime . 'Z',
          duration_ms=>int((time()-$started)*1000),
        };
        eval { _write_deploy_status($id, $failed_status); 1 } or do {
          $failed_status->{status_error} = _deploy_error_hash($@);
        };
        _deploy_throw($failure->{stage}, $failure->{message}, {%$failure, result=>$failed_status});
      }
    });
    1;
  };

  unless ($ok) {
    my $failure = _deploy_error_hash($@);
    return $failure->{result} if ref($failure->{result}) eq 'HASH';
    return {
      ok=>0, deployment=>$id, requested_commit=>$commit,
      error_stage=>$failure->{stage}, error=>$failure->{message},
      rc=>$failure->{rc}, stdout=>$failure->{stdout}, stderr=>$failure->{stderr},
      requested_by=>$actor, duration_ms=>int((time()-$started)*1000),
    };
  }
  return $result;
}


# Allgemeine Git-Einstellungen in global.json lesen und verwalten. Der Editor
# bearbeitet ausschliesslich das Unterobjekt global.json -> git_deploy.
get '/git_deploy/settings' => sub {
  my $c = shift;
  my $state = _load_git_configuration();
  my $summary = eval { _validate_git_settings_candidate($git_settings_cfg, 0) };
  $c->render(json=>{
    ok=>1, file=>$globalfile, section=>'git_deploy',
    valid=>(length($git_settings_error) ? false() : true()),
    degraded=>($state->{valid} ? false() : true()),
    generation=>$git_config_generation, sha256=>$git_settings_digest,
    content=>_pretty_json_text(exists($global->{git_deploy}) ? $global->{git_deploy} : {}), summary=>$summary,
    (length($git_settings_error) ? (validation_error=>$git_settings_error) : ()),
  });
};

post '/git_deploy/settings/validate' => sub {
  my $c = shift;
  my $body = eval { _read_body_or_die($c) };
  return $c->render(json=>{ok=>0,error=>'Anfrage zu gross'}, status=>413) if ref($@) eq 'RequestTooLarge';
  return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $@"}, status=>500) if $@;
  my $payload = eval { decode_json($body) };
  return $c->render(json=>{ok=>0,error=>'Ungueltiges JSON'}, status=>400) if $@ || ref($payload) ne 'HASH';
  my $content = exists($payload->{content}) ? $payload->{content} : $body;
  return $c->render(json=>{ok=>0,error=>'content muss ein JSON-String sein'}, status=>400)
    if exists($payload->{content}) && ref($content);
  my $settings = eval { decode_json($content) };
  return $c->render(json=>{ok=>0,error=>"JSON-Syntaxfehler: $@"}, status=>400) if $@ || ref($settings) ne 'HASH';
  my $summary = eval { _validate_git_settings_candidate($settings, 0) };
  if ($@) { my $e=_deploy_error_hash($@); return $c->render(json=>{ok=>0,error=>$e->{message},error_stage=>'validation'},status=>400); }
  my $combined_warning;
  eval { _validate_git_settings_candidate($settings, 1); 1 } or do { $combined_warning=_deploy_error_hash($@)->{message}; };
  $c->render(json=>{ok=>1,valid=>true(),summary=>$summary,(defined($combined_warning)?(combined_warning=>$combined_warning):())});
};

post '/git_deploy/settings' => sub {
  my $c = shift;
  my $body = eval { _read_body_or_die($c) };
  return $c->render(json=>{ok=>0,error=>'Anfrage zu gross'}, status=>413) if ref($@) eq 'RequestTooLarge';
  return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $@"}, status=>500) if $@;
  my $payload = eval { decode_json($body) };
  return $c->render(json=>{ok=>0,error=>'Ungueltiges JSON'}, status=>400) if $@ || ref($payload) ne 'HASH';
  my $content = exists($payload->{content}) ? $payload->{content} : $body;
  return $c->render(json=>{ok=>0,error=>'content muss ein JSON-String sein'}, status=>400)
    if exists($payload->{content}) && ref($content);
  my $settings = eval { decode_json($content) };
  return $c->render(json=>{ok=>0,error=>"JSON-Syntaxfehler: $@"}, status=>400) if $@ || ref($settings) ne 'HASH';
  my $summary = eval { _validate_git_settings_candidate($settings, 0) };
  if ($@) { my $e=_deploy_error_hash($@); return $c->render(json=>{ok=>0,error=>$e->{message},error_stage=>'validation'},status=>400); }
  my ($backup, $state);
  eval {
    _with_named_locks(['git-deploy-config',$globalfile,$gitfile], sub {
      _load_git_configuration();
      # Bestehende Profile muessen mit den neuen Settings weiterhin gueltig
      # sein. Andernfalls wird der Save vor dem Schreiben abgelehnt.
      $summary = _validate_git_settings_candidate($settings, 1);
      my $old_settings = exists($global->{git_deploy}) && ref($global->{git_deploy}) eq 'HASH'
        ? {%{$global->{git_deploy}}} : {};
      $backup = _create_git_settings_backup();
      _save_git_settings_section($settings);
      $state = _load_git_configuration();
      unless ($state->{valid}) {
        _save_git_settings_section($old_settings);
        _load_git_configuration();
        die "neue Git-Einstellungen wurden nach dem Schreiben ungueltig; vorheriger Stand wiederhergestellt: $git_config_error";
      }
    });
    1;
  } or return $c->render(json=>{ok=>0,error=>"Git-Einstellungen konnten nicht gespeichert werden: $@"},status=>500);
  $logger->info(sprintf('GIT_SETTINGS save %s file=%s backup=%s generation=%d',_fmt_req($c),$globalfile,($backup//'none'),$git_config_generation));
  $c->render(json=>{ok=>1,saved=>'global.json:git_deploy',backup=>$backup,generation=>$git_config_generation,sha256=>$git_settings_digest,summary=>$summary,degraded=>false()});
};

get '/git_deploy/settings/backups' => sub {
  my $c=shift;
  $c->render(json=>{ok=>1,backups=>_list_git_settings_backups()});
};

post '/git_deploy/settings/restore/#filename' => sub {
  my $c=shift;
  my $filename=$c->stash('filename')//'';
  return $c->render(json=>{ok=>0,error=>'Ungueltiger Backup-Name'},status=>400)
    unless $filename =~ /^git_deploy\.settings\.bak\.\d{8}_\d{6}_\d{3}$/;
  my $src="$git_settings_backup_dir/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'},status=>404) unless -f $src && !-l $src;
  my $settings=eval { decode_json(read_all($src)) };
  return $c->render(json=>{ok=>0,error=>"Backup enthaelt ungueltiges JSON: $@"},status=>400) if $@ || ref($settings) ne 'HASH';
  my $summary=eval { _validate_git_settings_candidate($settings,0) };
  if ($@) { my $e=_deploy_error_hash($@); return $c->render(json=>{ok=>0,error=>$e->{message}},status=>400); }
  my ($pre_backup,$state);
  eval {
    _with_named_locks(['git-deploy-config',$globalfile,$gitfile],sub {
      _load_git_configuration();
      $summary=_validate_git_settings_candidate($settings,1);
      my $old_settings=exists($global->{git_deploy}) && ref($global->{git_deploy}) eq 'HASH' ? {%{$global->{git_deploy}}} : {};
      $pre_backup=_create_git_settings_backup();
      _save_git_settings_section($settings);
      $state=_load_git_configuration();
      unless ($state->{valid}) {
        _save_git_settings_section($old_settings);
        _load_git_configuration();
        die "Restore wuerde Git-Deploy ungueltig machen; vorheriger Stand wiederhergestellt: $git_config_error";
      }
    });
    1;
  } or return $c->render(json=>{ok=>0,error=>"Restore fehlgeschlagen: $@"},status=>500);
  $c->render(json=>{ok=>1,restored=>$filename,pre_restore_backup=>$pre_backup,generation=>$git_config_generation,sha256=>$git_settings_digest,summary=>$summary,degraded=>false()});
};

# Separate git_deploy.json lesen und verwalten. Sie enthaelt ab 2.0.0 nur
# schema_version und profiles (Deployment-Profile/Module).
get '/git_deploy/config' => sub {
  my $c = shift;
  my $state = _load_git_configuration();
  if (-l $gitfile) {
    return $c->render(json=>{ok=>0,error=>'git_deploy.json ist ein Symlink und wird nicht gelesen',valid=>false(),degraded=>true()},status=>409);
  }
  my $content = -f $gitfile ? eval { read_all($gitfile) } : _pretty_json_text({schema_version=>1,profiles=>{}});
  return $c->render(json=>{ok=>0,error=>"git_deploy.json konnte nicht gelesen werden: $@"},status=>500) if $@;
  my $summary;
  my $local_error='';
  eval {
    my $parsed=decode_json($content);
    ($summary)=_validate_git_profiles_candidate($parsed);
    1;
  } or do { $local_error=_deploy_error_hash($@)->{message}; };
  $c->render(json=>{
    ok=>1,file=>$gitfile,exists=>(-f $gitfile?true():false()),
    valid=>(length($local_error)?false():true()),degraded=>($state->{valid}?false():true()),
    generation=>$git_config_generation,sha256=>$git_profiles_digest,content=>$content,summary=>$summary,
    (length($local_error)?(validation_error=>$local_error):()),mode=>(_mode_str($gitfile)//undef),
  });
};

post '/git_deploy/config/validate' => sub {
  my $c=shift;
  my $body=eval { _read_body_or_die($c) };
  return $c->render(json=>{ok=>0,error=>'Anfrage zu gross'},status=>413) if ref($@) eq 'RequestTooLarge';
  return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $@"},status=>500) if $@;
  my $payload=eval { decode_json($body) };
  return $c->render(json=>{ok=>0,error=>'Ungueltiges JSON'},status=>400) if $@ || ref($payload) ne 'HASH';
  my $content=exists($payload->{content})?$payload->{content}:$body;
  return $c->render(json=>{ok=>0,error=>'content muss ein JSON-String sein'},status=>400) if exists($payload->{content})&&ref($content);
  my $cfg=eval { decode_json($content) };
  return $c->render(json=>{ok=>0,error=>"JSON-Syntaxfehler: $@"},status=>400) if $@ || ref($cfg) ne 'HASH';
  my ($summary,$clean);
  my $ok=eval { ($summary,$clean)=_validate_git_profiles_candidate($cfg);1 };
  if (!$ok) { my $e=_deploy_error_hash($@); return $c->render(json=>{ok=>0,error=>$e->{message},error_stage=>'validation'},status=>400); }
  $c->render(json=>{ok=>1,valid=>true(),summary=>$summary});
};

post '/git_deploy/config' => sub {
  my $c=shift;
  my $body=eval { _read_body_or_die($c) };
  return $c->render(json=>{ok=>0,error=>'Anfrage zu gross'},status=>413) if ref($@) eq 'RequestTooLarge';
  return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $@"},status=>500) if $@;
  my $payload=eval { decode_json($body) };
  return $c->render(json=>{ok=>0,error=>'Ungueltiges JSON'},status=>400) if $@ || ref($payload) ne 'HASH';
  my $content=exists($payload->{content})?$payload->{content}:$body;
  return $c->render(json=>{ok=>0,error=>'content muss ein JSON-String sein'},status=>400) if exists($payload->{content})&&ref($content);
  my $cfg=eval { decode_json($content) };
  return $c->render(json=>{ok=>0,error=>"JSON-Syntaxfehler: $@"},status=>400) if $@ || ref($cfg) ne 'HASH';
  my $expected_sha = lc($payload->{expected_sha256} // '');
  return $c->render(json=>{ok=>0,error=>'expected_sha256 muss leer oder SHA-256 sein'},status=>400)
    if $expected_sha ne '' && $expected_sha !~ /^[0-9a-f]{64}$/;
  my ($summary,$clean,$backup,$method,$state);
  eval {
    _with_named_locks(['git-deploy-config',$globalfile,$gitfile],sub {
      # Beide Konfigurationsquellen innerhalb desselben Locks neu laden. So
      # kann ein paralleler Portal-Save von global.json und git_deploy.json
      # keinen bereits veralteten kombinierten Zustand validieren.
      _load_git_configuration();
      if ($expected_sha ne '' && lc($git_profiles_digest // '') ne $expected_sha) {
        _deploy_throw('conflict','git_deploy.json wurde seit dem Laden veraendert; bitte neu laden');
      }
      ($summary,$clean)=_validate_git_profiles_candidate($cfg);
      $content=_pretty_json_text($clean);
      my $old_exists = -f $gitfile && !-l $gitfile;
      my $old_content = $old_exists ? read_all($gitfile) : undef;
      $backup=_create_git_config_backup();
      $method=safe_write_file($gitfile,$content,1);
      _apply_git_config_meta();
      $state=_load_git_configuration();
      unless ($state->{valid}) {
        if ($old_exists) {
          safe_write_file($gitfile,$old_content,1);
          _apply_git_config_meta();
        } else {
          unlink($gitfile) if -f $gitfile && !-l $gitfile;
        }
        _load_git_configuration();
        die "neue Git-Deploy-Konfiguration wurde nach dem Schreiben ungueltig; vorheriger Stand wiederhergestellt: $git_config_error";
      }
    });
    1;
  } or do {
    my $e=_deploy_error_hash($@);
    my $code=($e->{stage}//'') eq 'conflict' ? 409 : 500;
    return $c->render(json=>{ok=>0,error=>"git_deploy.json konnte nicht gespeichert werden: $e->{message}",error_stage=>($e->{stage}//'save')},status=>$code);
  };
  $c->render(json=>{ok=>1,saved=>'git_deploy.json',method=>$method,backup=>$backup,generation=>$git_config_generation,sha256=>$git_profiles_digest,summary=>$summary,degraded=>false()});
};

get '/git_deploy/config/backups' => sub { shift->render(json=>{ok=>1,backups=>_list_git_config_backups()}); };

# Relaxed placeholder (#filename) erlaubt Punkte im geprüften Backup-Dateinamen.
get '/git_deploy/config/backup/#filename' => sub {
  my $c=shift;
  my $filename=$c->stash('filename')//'';
  return $c->render(json=>{ok=>0,error=>'Ungueltiger Backup-Name'},status=>400)
    unless $filename =~ /^git_deploy\.json\.bak\.\d{8}_\d{6}_\d{3}$/;
  my $src="$git_config_backup_dir/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'},status=>404) unless -f $src && !-l $src;
  my $content=eval { read_all($src) };
  return $c->render(json=>{ok=>0,error=>"Backup konnte nicht gelesen werden: $@"},status=>500) if $@;
  my $cfg=eval { decode_json($content) };
  return $c->render(json=>{ok=>0,error=>"Backup enthaelt ungueltiges JSON: $@"},status=>400) if $@ || ref($cfg) ne 'HASH';
  my ($summary,$clean);
  my $ok=eval { ($summary,$clean)=_validate_git_profiles_candidate($cfg);1 };
  if (!$ok) { my $e=_deploy_error_hash($@); return $c->render(json=>{ok=>0,error=>$e->{message}},status=>400); }
  $c->render(json=>{ok=>1,filename=>$filename,content=>_pretty_json_text($clean),summary=>$summary});
};

post '/git_deploy/config/restore/#filename' => sub {
  my $c=shift;
  my $filename=$c->stash('filename')//'';
  return $c->render(json=>{ok=>0,error=>'Ungueltiger Backup-Name'},status=>400) unless $filename =~ /^git_deploy\.json\.bak\.\d{8}_\d{6}_\d{3}$/;
  my $src="$git_config_backup_dir/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'},status=>404) unless -f $src && !-l $src;
  my $content=eval { read_all($src) };
  return $c->render(json=>{ok=>0,error=>"Backup konnte nicht gelesen werden: $@"},status=>500) if $@;
  my $cfg=eval { decode_json($content) };
  return $c->render(json=>{ok=>0,error=>"Backup enthaelt ungueltiges JSON: $@"},status=>400) if $@ || ref($cfg) ne 'HASH';
  my ($summary,$clean);
  my $ok=eval { ($summary,$clean)=_validate_git_profiles_candidate($cfg);1 };
  if (!$ok) { my $e=_deploy_error_hash($@); return $c->render(json=>{ok=>0,error=>$e->{message}},status=>400); }
  my ($pre_backup,$state);
  eval {
    _with_named_locks(['git-deploy-config',$globalfile,$gitfile],sub {
      _load_git_configuration();
      ($summary,$clean)=_validate_git_profiles_candidate($cfg);
      my $old_exists=-f $gitfile && !-l $gitfile;
      my $old_content=$old_exists ? read_all($gitfile) : undef;
      $pre_backup=_create_git_config_backup();
      safe_write_file($gitfile,_pretty_json_text($clean),1);
      _apply_git_config_meta();
      $state=_load_git_configuration();
      unless ($state->{valid}) {
        if ($old_exists) { safe_write_file($gitfile,$old_content,1); _apply_git_config_meta(); }
        else { unlink($gitfile) if -f $gitfile && !-l $gitfile; }
        _load_git_configuration();
        die "Restore wuerde Git-Deploy ungueltig machen; vorheriger Stand wiederhergestellt: $git_config_error";
      }
    });
    1;
  } or return $c->render(json=>{ok=>0,error=>"Restore fehlgeschlagen: $@"},status=>500);
  $c->render(json=>{ok=>1,restored=>$filename,pre_restore_backup=>$pre_backup,generation=>$git_config_generation,sha256=>$git_profiles_digest,summary=>$summary,degraded=>false()});
};

# Git-Deploy-Profile fuer das Portal auflisten (keine Credentials/Preflight-Details)
get '/git_deployments' => sub {
  my $c = shift;
  my $git_state = _load_git_configuration();
  unless ($git_state->{valid}) {
    return $c->render(json=>{
      ok=>1, enabled=>false(), degraded=>true(), config_valid=>false(),
      settings_file=>'global.json:git_deploy', profiles_file=>'git_deploy.json',
      config_generation=>$git_config_generation, state_dir=>$git_state_dir,
      deploy_token_source=>$git_deploy_token_source,
      requires_deploy_token=>($git_deploy_token_source eq 'request' ? true() : false()),
      error=>$git_config_error,
      (length($git_settings_error)?(settings_error=>$git_settings_error):()),
      (length($git_profiles_error)?(profiles_error=>$git_profiles_error):()),
      profiles=>[],
    });
  }
  my @profiles;
  for my $id (sort keys %$git_profiles_raw) {
    next unless _safe_deploy_id($id);
    my $p = $git_profiles_raw->{$id};
    next unless ref($p) eq 'HASH';
    my $target = $p->{target_path} // '';
    my $effective_releases = $p->{releases_dir};
    if ((!defined($effective_releases) || !length($effective_releases)) && length($target)) {
      my $target_parent = path($target)->dirname->to_string;
      my $target_base   = path($target)->basename;
      $effective_releases = "$target_parent/.${target_base}.releases";
    }
    push @profiles, {
      id=>$id, deploy_mode=>lc($p->{deploy_mode}//'symlink_release'),
      enabled=>(exists($p->{enabled}) ? ($p->{enabled} ? true() : false()) : true()),
      git_url=>$p->{git_url}, target_path=>$p->{target_path}, releases_dir=>$effective_releases, allowed_ref=>$p->{allowed_ref},
      ref_policy=>($p->{ref_policy}//(($p->{allowed_ref}//'') =~ m{^refs/tags/} ? 'exact' : 'ancestor')),
      restart_service=>$p->{restart_service},
      post_deploy=>(exists($p->{post_deploy}) ? true() : false()),
      healthcheck_type=>(ref($p->{healthcheck}) eq 'HASH' ? ($p->{healthcheck}{type}//'') : (defined($p->{restart_service}) ? 'systemd' : 'none')),
      require_signed_commit=>($p->{require_signed_commit} ? true() : false()),
      preserve_paths=>[map {{path=>$_->{path}, policy=>$_->{policy}, required=>($_->{required}?true():false())}} @{_preserve_specs_or_throw($p, "Profil $id")}],
    };
  }
  $c->render(json=>{
    ok=>1, enabled=>($git_deploy_enabled ? true() : false()),
    settings_file=>'global.json:git_deploy', profiles_file=>'git_deploy.json', config_file=>'git_deploy.json', config_valid=>true(), degraded=>false(), config_generation=>$git_config_generation,
    state_dir=>$git_state_dir,
    allow_direct_request=>($git_allow_direct_request ? true() : false()),
    deploy_token_source=>$git_deploy_token_source,
    requires_deploy_token=>($git_deploy_token_source eq 'request' ? true() : false()),
    profiles=>\@profiles,
  });
};

# Letzten persistierten Deploy-Status und aktuellen Repository-Commit lesen.
# Auch vor dem ersten Deploy wird HTTP 200 geliefert: active_commit bleibt dann
# undef, waehrend repository_commit bereits sichtbar sein kann.
get '/git_deploy/status/:deployment' => sub {
  my $c = shift;
  my $git_state = _load_git_configuration();
  my $id = $c->stash('deployment');
  return $c->render(json=>{ok=>0,error=>'Ungueltige Deployment-ID'}, status=>400) unless _safe_deploy_id($id);
  my $profile = $git_profiles_raw->{$id};
  return $c->render(json=>{ok=>0,error=>'Unbekanntes Deployment-Profil'}, status=>404) unless ref($profile) eq 'HASH';
  my $status = _read_deploy_status($id);
  my $active_commit = _valid_git_commit_id(ref($status) eq 'HASH' ? $status->{active_commit} : undef);
  my $request_token = $c->req->headers->header('X-Deploy-Token');
  $request_token = undef unless defined($request_token) && length($request_token);

  $c->render_later;
  my $sp = Mojo::IOLoop::Subprocess->new;
  $sp->run(
    sub {
      my $repository = eval { _repository_commit_status($id, $request_token) };
      return $repository if ref($repository) eq 'HASH';
      my $error = _deploy_error_hash($@);
      return {repository_error=>$error->{message}, repository_error_stage=>$error->{stage}};
    },
    sub {
      my ($subprocess, $sub_err, $repository) = @_;
      $repository = {} unless ref($repository) eq 'HASH';
      $repository->{repository_error} = "$sub_err" if $sub_err && !length($repository->{repository_error} // '');
      my $repository_commit = _valid_git_commit_id($repository->{repository_commit});
      my $comparison = !defined($active_commit) ? 'installed_unknown'
        : !defined($repository_commit) ? 'repository_unknown'
        : $active_commit eq $repository_commit ? 'current'
        : 'update_available';
      $c->render(json=>{
        ok=>1,
        status=>$status,
        active_commit=>$active_commit,
        repository_commit=>$repository_commit,
        comparison=>$comparison,
        allowed_ref=>($repository->{allowed_ref} // $profile->{allowed_ref} // ''),
        repository_token_required=>(($git_deploy_token_source eq 'request' && !defined($request_token)) ? true() : false()),
        (length($repository->{repository_error} // '') ? (
          repository_error=>$repository->{repository_error},
          repository_error_stage=>($repository->{repository_error_stage} // 'repository_status'),
        ) : ()),
        config_valid=>($git_state->{valid} ? true() : false()),
        (length($git_config_error) ? (config_warning=>$git_config_error) : ()),
      });
    }
  );
  return;
};

# Bekannte aktive/archivierte Commits fuer einen sicheren manuellen Restore.
# Die GUI erhaelt nur Commit-IDs; ein Restore laeuft anschliessend als normaler,
# vollstaendig validierter Deploy dieses Commits mit Preserve und Auto-Rollback.
get '/git_deploy/releases/:deployment' => sub {
  my $c = shift;
  my $git_state = _load_git_configuration();
  return $c->render(json=>{ok=>0,error=>'Git-Deploy-Konfiguration ist ungueltig',config_error=>$git_config_error,degraded=>true()}, status=>503)
    unless $git_state->{valid};
  return $c->render(json=>{ok=>0,error=>'Git-Deploy ist deaktiviert'}, status=>503) unless $git_deploy_enabled;
  my $id = $c->stash('deployment');
  my $request_token = $c->req->headers->header('X-Deploy-Token');
  $request_token = undef unless defined($request_token) && length($request_token);
  my $result = eval { _list_deploy_release_commits($id, $request_token) };
  unless ($result) {
    my $e = _deploy_error_hash($@);
    return $c->render(json=>{ok=>0,error=>$e->{message},error_stage=>$e->{stage}}, status=>400);
  }
  $c->render(json=>{ok=>1,%$result});
};

# Sichere Diff-Vorschau zwischen aktivem und gewaehltem Commit.
post '/git_deploy/compare/:deployment' => sub {
  my $c = shift;
  my $git_state = _load_git_configuration();
  return $c->render(json=>{ok=>0,error=>'Git-Deploy-Konfiguration ist ungueltig',config_error=>$git_config_error,degraded=>true()}, status=>503)
    unless $git_state->{valid};
  return $c->render(json=>{ok=>0,error=>'Git-Deploy ist deaktiviert'}, status=>503) unless $git_deploy_enabled;
  my $id = $c->stash('deployment');
  my $body = eval { _read_body_or_die($c) };
  return $c->render(json=>{ok=>0,error=>'Request-Body konnte nicht gelesen werden'}, status=>400) if $@;
  my $payload = eval { decode_json($body) };
  return $c->render(json=>{ok=>0,error=>'Ungueltiges JSON'}, status=>400) if $@ || ref($payload) ne 'HASH';
  my $commit = lc($payload->{commit_sha} // 'auto');
  return $c->render(json=>{ok=>0,error=>'Commit muss auto oder eine vollstaendige SHA sein'}, status=>400)
    unless $commit eq 'auto' || defined(_valid_git_commit_id($commit));
  my $token = $payload->{deploy_token};
  $token = undef unless defined($token) && length($token);
  my $result = eval { _compare_deploy_commits($id, $commit, $token) };
  unless ($result) {
    my $e = _deploy_error_hash($@);
    return $c->render(json=>{ok=>0,error=>$e->{message},error_stage=>$e->{stage}}, status=>400);
  }
  $c->render(json=>{ok=>1,%$result});
};

# Profilgebundener Git-Pull-Deploy
post '/git_deploy' => sub {
  my $c = shift;
  my $git_state = _load_git_configuration();
  return $c->render(json=>{ok=>0,error=>'Git-Deploy-Konfiguration ist ungueltig',config_error=>$git_config_error,degraded=>true()}, status=>503)
    unless $git_state->{valid};
  return $c->render(json=>{ok=>0,error=>'Git-Deploy ist deaktiviert'}, status=>503) unless $git_deploy_enabled;
  return $c->render(json=>{ok=>0,error=>'Git-Deploy erfordert einen konfigurierten API-Token'}, status=>503)
    if $git_require_api_token && (!defined($api_token) || !length($api_token));
  return $c->render(json=>{ok=>0,error=>'Git-Deploy erfordert eine nicht-leere allowed_ips-Liste'}, status=>503)
    if $git_require_ip_acl && (!ref($allowed_ips) || !@$allowed_ips);

  my $body = eval { _read_body_or_die($c) };
  if (my $exc = $@) {
    if (ref($exc) eq 'RequestTooLarge') {
      return $c->render(json=>{ok=>0,error=>'Anfrage zu gross (max_message_size ueberschritten)'}, status=>413);
    }
    my $msg = ref($exc) ? "$exc" : $exc;
    return $c->render(json=>{ok=>0,error=>"Request-Body konnte nicht gelesen werden: $msg"}, status=>500);
  }
  my $payload = eval { decode_json($body) };
  return $c->render(json=>{ok=>0,error=>'Ungueltiges JSON'}, status=>400) if $@ || ref($payload) ne 'HASH';

  my $header_actor = $c->req->headers->header('X-Deploy-Actor');
  $payload->{requested_by} = $header_actor if defined($header_actor) && length($header_actor) && !exists($payload->{requested_by});

  my ($id, $profile, $commit, $token, $actor);
  my $resolved = eval {
    ($id, $profile, $commit, $token, $actor) = _resolve_deploy_profile($payload);
    1;
  };
  unless ($resolved) {
    my $e = _deploy_error_hash($@);
    return $c->render(json=>{ok=>0,error=>$e->{message},error_stage=>$e->{stage}}, status=>400);
  }

  $logger->info(sprintf(
    'GIT_DEPLOY begin %s deployment=%s commit=%s actor=%s',
    _fmt_req($c), $id, $commit, ($actor // '')
  ));

  my $start = time();
  $c->render_later;
  my $sp = Mojo::IOLoop::Subprocess->new;
  $sp->run(
    sub {
      return _git_deploy_execute($id, $profile, $commit, $token, $actor, $payload);
    },
    sub {
      my ($subprocess, $sub_err, $result) = @_;
      my $dur = time() - $start;
      if ($sub_err || ref($result) ne 'HASH') {
        my $msg = _redact_secrets($sub_err // 'ungueltiges Subprozess-Ergebnis', [$token]);
        $logger->error(sprintf('GIT_DEPLOY subprocess_failed %s deployment=%s commit=%s time=%.3fs err=%s',
          _fmt_req($c), $id, $commit, $dur, $msg));
        return $c->render(status=>500, json=>{ok=>0,error=>'Git-Deploy-Subprozess fehlgeschlagen',detail=>$msg});
      }

      if ($result->{ok}) {
        $logger->info(sprintf(
          'GIT_DEPLOY done %s deployment=%s action=%s commit=%s previous=%s service=%s time=%.3fs',
          _fmt_req($c), $id, ($result->{action}//''), $commit,
          ($result->{previous_commit}//''), ($result->{restart_service}//''), $dur
        ));
        return $c->render(json=>$result);
      }

      my $stage = $result->{error_stage} // 'unknown';
      my $status = $stage eq 'validation' ? 400
                 : $stage eq 'disabled'   ? 503
                 : $stage =~ /^(?:git_fetch|git_init|git_cache|ref_resolve)$/ ? 502
                 : $stage =~ /^(?:healthcheck|restart|rollback)/ ? 500
                 : 500;
      $logger->error(sprintf(
        'GIT_DEPLOY failed %s deployment=%s commit=%s stage=%s rollback=%s time=%.3fs error=%s',
        _fmt_req($c), $id, $commit, $stage,
        (ref($result->{rollback}) eq 'HASH' ? ($result->{rollback}{ok} ? 'ok' : ($result->{rollback}{attempted} ? 'failed' : 'none')) : 'none'),
        $dur, ($result->{error}//'')
      ));
      return $c->render(status=>$status, json=>$result);
    }
  );
  return;
};


1;
