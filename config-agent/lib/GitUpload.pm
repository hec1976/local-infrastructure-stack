package main;
use strict;
use warnings;
use utf8;

# Forgejo Repository Upload
# - Repositorys und Branches ueber Forgejo REST auflisten
# - Browser-Verzeichnis oder ZIP sicher in ein Staging uebernehmen
# - Vorschau ueber einen temporaeren Git-Workspace
# - Commit und Push ohne frei eingebbare Git-Befehle

use Mojo::JSON qw(encode_json decode_json true false);
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(url_escape);
use Mojo::File qw(path);
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use Time::HiRes qw(time);
use Fcntl qw(:DEFAULT :flock);
use Scalar::Util qw(blessed);

our ($global, $logger, $tmpDir, $lockTimeoutS, $api_token, $allowed_ips, $git_bin, $git_timeout);

our (
  $git_upload_cfg, $git_upload_enabled, $git_upload_valid, $git_upload_error,
  $git_upload_base_url, $git_upload_token_file, $git_upload_workspace_root,
  $git_upload_stage_root, $git_upload_work_root, $git_upload_max_bytes,
  $git_upload_max_files, $git_upload_ttl, $git_upload_verify_tls,
  $git_upload_ca_file, $git_upload_allow_http, $git_upload_allow_mirror,
  $git_upload_allow_default_branch, $git_upload_cleanup_on_success,
  $git_upload_commit_name, $git_upload_commit_email, $git_upload_timeout,
  $git_upload_unzip_bin, $git_upload_cache_seconds, $git_upload_allowed_owners,
  $git_upload_ignore_patterns, $git_upload_secret_patterns,
  $git_upload_repo_cache, $git_upload_repo_cache_at
);

sub _gu_bool_value {
  my ($value, $label) = @_;
  if (ref($value)) {
    my $class = blessed($value) // '';
    return $value ? 1 : 0 if $class =~ /Boolean$/;
    die "$label muss boolean sein";
  }
  return 0 if defined($value) && "$value" eq '0';
  return 1 if defined($value) && "$value" eq '1';
  die "$label muss boolean sein";
}

sub _gu_bool_cfg {
  my ($cfg, $key, $default) = @_;
  return $default unless exists($cfg->{$key});
  return _gu_bool_value($cfg->{$key}, "git_upload.$key");
}

sub _gu_uint_strict {
  my ($cfg, $key, $default, $min, $max) = @_;
  return $default unless exists($cfg->{$key});
  my $value = $cfg->{$key};
  die "git_upload.$key muss eine Ganzzahl sein"
    unless defined($value) && !ref($value) && "$value" =~ /^\d+$/;
  my $n = 0 + $value;
  die "git_upload.$key muss zwischen $min und $max liegen" if $n < $min || $n > $max;
  return $n;
}

sub _gu_validate_config_shape {
  my ($cfg) = @_;
  my %allowed = map { $_=>1 } qw(
    enabled api_base_url base_url token_file workspace_root max_upload_bytes max_files
    stage_ttl_seconds verify_tls ca_file allow_http allow_mirror
    allow_default_branch cleanup_on_success commit_name commit_email timeout
    unzip_bin repository_cache_seconds allowed_owners ignore_patterns
    secret_name_patterns
  );
  for my $key (keys %$cfg) {
    die "Unbekanntes git_upload-Feld: $key" unless $allowed{$key};
  }
  for my $key (qw(enabled verify_tls allow_http allow_mirror allow_default_branch cleanup_on_success)) {
    _gu_bool_value($cfg->{$key}, "git_upload.$key") if exists($cfg->{$key});
  }
  _gu_uint_strict($cfg, 'max_upload_bytes', 536_870_912, 1_048_576, 2_147_483_648);
  _gu_uint_strict($cfg, 'max_files', 10_000, 1, 100_000);
  _gu_uint_strict($cfg, 'stage_ttl_seconds', 3600, 300, 86_400);
  _gu_uint_strict($cfg, 'timeout', 300, 30, 3600);
  _gu_uint_strict($cfg, 'repository_cache_seconds', 30, 0, 3600);
  for my $key (qw(allowed_owners ignore_patterns secret_name_patterns)) {
    die "git_upload.$key muss ein Array sein" if exists($cfg->{$key}) && ref($cfg->{$key}) ne 'ARRAY';
  }
  for my $key (qw(api_base_url base_url token_file workspace_root ca_file commit_name commit_email unzip_bin)) {
    die "git_upload.$key muss ein String sein" if exists($cfg->{$key}) && (ref($cfg->{$key}) || !defined($cfg->{$key}));
  }
  return 1;
}

$git_upload_cfg = ref($global->{git_upload}) eq 'HASH' ? {%{$global->{git_upload}}} : {};
my $forgejo_shared = ref($global->{forgejo}) eq 'HASH' ? $global->{forgejo} : {};
$git_upload_valid = 1;
$git_upload_error = '';
my $shape_ok = eval { _gu_validate_config_shape($git_upload_cfg); 1 };
if (!$shape_ok) {
  $git_upload_valid = 0;
  $git_upload_error = "$@";
  $git_upload_error =~ s/\s+$//;
}
$git_upload_enabled = $git_upload_valid ? _gu_bool_cfg($git_upload_cfg, 'enabled', 0) : 0;
$git_upload_base_url = $git_upload_cfg->{api_base_url} // $git_upload_cfg->{base_url} // $forgejo_shared->{api_base_url} // $forgejo_shared->{url} // $forgejo_shared->{base_url} // '';
if (exists($git_upload_cfg->{api_base_url}) && exists($git_upload_cfg->{base_url}) && $git_upload_cfg->{api_base_url} ne $git_upload_cfg->{base_url}) {
  $git_upload_valid = 0;
  $git_upload_error = 'git_upload.api_base_url und git_upload.base_url widersprechen sich';
}
$git_upload_token_file = $git_upload_cfg->{token_file} // $forgejo_shared->{token_file} // '/opt/service/env/forgejo-api.token';
$git_upload_workspace_root = $git_upload_cfg->{workspace_root} // "$tmpDir/git-upload";
$git_upload_stage_root = "$git_upload_workspace_root/staging";
$git_upload_work_root = "$git_upload_workspace_root/workspaces";
$git_upload_max_bytes = $git_upload_valid ? _gu_uint_strict($git_upload_cfg, 'max_upload_bytes', 536_870_912, 1_048_576, 2_147_483_648) : 536_870_912;
$git_upload_max_files = $git_upload_valid ? _gu_uint_strict($git_upload_cfg, 'max_files', 10_000, 1, 100_000) : 10_000;
$git_upload_ttl = $git_upload_valid ? _gu_uint_strict($git_upload_cfg, 'stage_ttl_seconds', 3600, 300, 86_400) : 3600;
$git_upload_verify_tls = $git_upload_valid && exists($git_upload_cfg->{verify_tls}) ? _gu_bool_cfg($git_upload_cfg, 'verify_tls', 1) : (exists($forgejo_shared->{verify_tls}) ? ($forgejo_shared->{verify_tls} ? 1 : 0) : 1);
$git_upload_ca_file = $git_upload_cfg->{ca_file} // $forgejo_shared->{ca_file};
$git_upload_allow_http = $git_upload_valid && exists($git_upload_cfg->{allow_http}) ? _gu_bool_cfg($git_upload_cfg, 'allow_http', 0) : (($git_upload_base_url // '') =~ m{^http://}i ? 1 : 0);
$git_upload_allow_mirror = $git_upload_valid ? _gu_bool_cfg($git_upload_cfg, 'allow_mirror', 0) : 0;
$git_upload_allow_default_branch = $git_upload_valid ? _gu_bool_cfg($git_upload_cfg, 'allow_default_branch', 1) : 0;
$git_upload_cleanup_on_success = $git_upload_valid ? _gu_bool_cfg($git_upload_cfg, 'cleanup_on_success', 1) : 1;
$git_upload_commit_name = $git_upload_cfg->{commit_name} // 'Service Repository Upload';
$git_upload_commit_email = $git_upload_cfg->{commit_email} // 'git-upload@service.internal';
$git_upload_timeout = $git_upload_valid ? _gu_uint_strict($git_upload_cfg, 'timeout', ($git_timeout || 300), 30, 3600) : ($git_timeout || 300);
$git_upload_unzip_bin = $git_upload_cfg->{unzip_bin} // '/usr/bin/unzip';
$git_upload_cache_seconds = $git_upload_valid ? _gu_uint_strict($git_upload_cfg, 'repository_cache_seconds', 30, 0, 3600) : 30;
$git_upload_allowed_owners = ref($git_upload_cfg->{allowed_owners}) eq 'ARRAY' ? $git_upload_cfg->{allowed_owners} : [];
$git_upload_ignore_patterns = ref($git_upload_cfg->{ignore_patterns}) eq 'ARRAY'
  ? $git_upload_cfg->{ignore_patterns}
  : ['.git', '.git/**', '*.log', '*.bak', '*.tmp', '.DS_Store', 'Thumbs.db'];
$git_upload_secret_patterns = ref($git_upload_cfg->{secret_name_patterns}) eq 'ARRAY'
  ? $git_upload_cfg->{secret_name_patterns}
  : ['*.key', '*.pem', '*private*key*', '*secret*', '*credential*', '*token*', '*password*'];
$git_upload_repo_cache = [];
$git_upload_repo_cache_at = 0;

sub _gu_uint {
  my ($value, $default, $min, $max) = @_;
  return $default unless defined($value) && !ref($value) && "$value" =~ /^\d+$/;
  my $n = 0 + $value;
  return $default if $n < $min || $n > $max;
  return $n;
}

sub _gu_fail {
  my ($message) = @_;
  die bless({message=>$message}, 'GitUploadError');
}

sub _gu_error_message {
  my ($err) = @_;
  return $err->{message} if ref($err) eq 'GitUploadError';
  my $msg = ref($err) ? "$err" : ($err // 'Unbekannter Fehler');
  $msg =~ s/\s+$//;
  return $msg;
}

sub _gu_validate_init {
  return unless $git_upload_valid;
  eval {
    # Die read-only Repository-Integration bleibt auch bei deaktiviertem Upload
    # verfügbar. Schreibspezifische Verzeichnisse werden nur bei aktiviertem
    # Upload angelegt.
    _gu_fail('git_upload.api_base_url/base_url fehlt') unless defined($git_upload_base_url) && length($git_upload_base_url);
    my $url = Mojo::URL->new($git_upload_base_url);
    my $scheme = lc($url->scheme // '');
    _gu_fail('git_upload.api_base_url/base_url muss HTTP oder HTTPS verwenden') unless $scheme eq 'https' || ($scheme eq 'http' && $git_upload_allow_http);
    _gu_fail('git_upload.api_base_url/base_url darf keine Zugangsdaten enthalten') if length($url->userinfo // '');
    _gu_fail('git_upload.api_base_url/base_url Host fehlt') unless length($url->host // '');
    _gu_fail('git_upload.token_file muss absolut sein') unless $git_upload_token_file =~ m{^/};
    _gu_fail('git_upload.workspace_root muss absolut sein') unless $git_upload_workspace_root =~ m{^/};
    _gu_fail('git_upload.commit_name ungueltig') unless !ref($git_upload_commit_name) && $git_upload_commit_name =~ /^[^\x00-\x1f\x7f]{1,128}$/;
    _gu_fail('git_upload.commit_email ungueltig') unless !ref($git_upload_commit_email) && $git_upload_commit_email =~ /^[A-Za-z0-9_.+\-]+\@[A-Za-z0-9.\-]+$/;
    for my $owner (@$git_upload_allowed_owners) {
      _gu_fail('git_upload.allowed_owners enthaelt ungueltigen Eintrag')
        unless defined($owner) && !ref($owner) && $owner =~ /^[A-Za-z0-9_.-]{1,128}$/;
    }
    if ($git_upload_enabled) {
      make_path($git_upload_stage_root, {mode=>0770}) unless -d $git_upload_stage_root;
      make_path($git_upload_work_root, {mode=>0770}) unless -d $git_upload_work_root;
      chmod(0770, $git_upload_workspace_root) if -d $git_upload_workspace_root;
      chmod(0770, $git_upload_stage_root) if -d $git_upload_stage_root;
      chmod(0770, $git_upload_work_root) if -d $git_upload_work_root;
    }
    1;
  } or do {
    $git_upload_valid = 0;
    $git_upload_error = _gu_error_message($@);
    $logger->error("GIT_UPLOAD degraded error=$git_upload_error") if $logger;
  };
}
_gu_validate_init();

sub _gu_require_forgejo_ready {
  _gu_fail('Forgejo URL fehlt') unless defined($git_upload_base_url) && length($git_upload_base_url);
  my $url = Mojo::URL->new($git_upload_base_url);
  my $scheme = lc($url->scheme // '');
  _gu_fail('Forgejo URL muss HTTP oder HTTPS verwenden') unless $scheme eq 'https' || ($scheme eq 'http' && $git_upload_allow_http);
  _gu_fail('Forgejo URL darf keine Zugangsdaten enthalten') if length($url->userinfo // '');
  _gu_fail('Forgejo URL Host fehlt') unless length($url->host // '');
  _gu_fail("Forgejo Integration ist nicht bereit: $git_upload_error") unless $git_upload_valid;
  _gu_fail("Forgejo Token-Datei fehlt: $git_upload_token_file") unless -f $git_upload_token_file && -r $git_upload_token_file && !-l $git_upload_token_file;
  _gu_fail("Git-Binary fehlt oder ist nicht ausfuehrbar: $git_bin") unless -f $git_bin && -x $git_bin;
  make_path($git_upload_stage_root, {mode=>0770}) unless -d $git_upload_stage_root;
  make_path($git_upload_work_root, {mode=>0770}) unless -d $git_upload_work_root;
}

sub _gu_require_ready {
  _gu_fail('Git Repository Upload ist deaktiviert') unless $git_upload_enabled;
  _gu_require_forgejo_ready();
}

sub _gu_read_token {
  _gu_require_forgejo_ready();
  my $token = read_all($git_upload_token_file);
  $token =~ s/[\r\n]+\z//;
  _gu_fail('Forgejo Token ist leer') unless length($token);
  _gu_fail('Forgejo Token ist zu lang') if length($token) > 4096;
  _gu_fail('Forgejo Token enthaelt ungueltige Zeichen') unless $token =~ /^[\x21-\x7e]+$/;
  return $token;
}

sub _gu_ua {
  my $ua = Mojo::UserAgent->new;
  $ua->connect_timeout(10);
  $ua->inactivity_timeout($git_upload_timeout);
  $ua->request_timeout($git_upload_timeout);
  $ua->max_redirects(0);
  $ua->insecure(1) unless $git_upload_verify_tls;
  if ($git_upload_verify_tls && defined($git_upload_ca_file) && length($git_upload_ca_file)) {
    _gu_fail("Forgejo CA-Datei nicht lesbar: $git_upload_ca_file") unless -f $git_upload_ca_file && -r $git_upload_ca_file && !-l $git_upload_ca_file;
    $ua->ca($git_upload_ca_file) if $ua->can('ca');
  }
  return $ua;
}

sub _gu_api {
  my ($method, $path, $body, $opts) = @_;
  $opts = {} unless ref($opts) eq 'HASH';
  my $token = _gu_read_token();
  my $base = $git_upload_base_url;
  $base =~ s{/+$}{};
  _gu_fail('Forgejo API-Pfad ungueltig') unless defined($path) && $path =~ m{^/api/v1/};
  my $url = $base . $path;
  my $ua = _gu_ua();
  my %headers = (Authorization => "token $token", Accept => 'application/json');
  my $tx;
  if (uc($method) eq 'GET') {
    $tx = $ua->get($url => \%headers);
  } elsif (uc($method) eq 'POST') {
    $tx = $ua->post($url => \%headers => json => ($body // {}));
  } elsif (uc($method) eq 'PUT') {
    $tx = $ua->put($url => \%headers => json => ($body // {}));
  } else {
    _gu_fail("Nicht unterstuetzte Forgejo API-Methode: $method");
  }
  my $res = $tx->result;
  my $code = $res->code // 0;
  if (!$res->is_success) {
    my $message = eval { $res->json->{message} } // $res->message // 'Forgejo API-Fehler';
    _gu_fail("Forgejo API HTTP $code: $message");
  }
  my $raw = $res->body // '';
  if (exists $opts->{empty_json} && ($raw !~ /\S/ || $raw =~ /^\s*null\s*$/i)) {
    return $opts->{empty_json};
  }
  my $json = $res->json;
  _gu_fail("Forgejo API lieferte kein gueltiges JSON ($method $path, HTTP $code)") unless defined $json;
  return $json;
}

sub _gu_owner_allowed {
  my ($owner) = @_;
  return 1 unless @$git_upload_allowed_owners;
  my %allowed = map { lc($_)=>1 } @$git_upload_allowed_owners;
  return $allowed{lc($owner // '')} ? 1 : 0;
}

sub _gu_repo_simple {
  my ($repo, $require_push) = @_;
  $require_push = 0 unless defined $require_push;
  my $owner = ref($repo->{owner}) eq 'HASH' ? ($repo->{owner}{login} // $repo->{owner}{username} // '') : '';
  my $name = $repo->{name} // '';
  return undef unless $owner =~ /^[A-Za-z0-9_.-]{1,128}$/ && $name =~ /^[A-Za-z0-9_.-]{1,128}$/;
  return undef unless _gu_owner_allowed($owner);
  return undef if $repo->{archived};
  my $permissions = ref($repo->{permissions}) eq 'HASH' ? $repo->{permissions} : {};
  my $can_push = $permissions->{push} || $permissions->{admin} ? 1 : 0;
  return undef if $require_push && !$can_push;
  return {
    owner=>$owner,
    name=>$name,
    full_name=>($repo->{full_name} // "$owner/$name"),
    private=>($repo->{private} ? true() : false()),
    default_branch=>($repo->{default_branch} // 'main'),
    clone_url=>($repo->{clone_url} // ''),
    html_url=>($repo->{html_url} // ''),
    can_push=>($can_push ? true() : false()),
    empty=>($repo->{empty} ? true() : false()),
  };
}

sub _gu_repositories {
  my ($force, $require_push) = @_;
  $require_push = 1 unless defined $require_push;
  _gu_require_forgejo_ready();
  if (!$force && $git_upload_cache_seconds > 0 && (time() - $git_upload_repo_cache_at) < $git_upload_cache_seconds) {
    my @cached = $require_push ? grep { $_->{can_push} } @$git_upload_repo_cache : @$git_upload_repo_cache;
    return \@cached;
  }
  my @repos;
  for my $page (1..100) {
    my $json = _gu_api('GET', "/api/v1/user/repos?limit=50&page=$page");
    _gu_fail('Forgejo Repository-Antwort ist kein Array') unless ref($json) eq 'ARRAY';
    for my $repo (@$json) {
      next unless ref($repo) eq 'HASH';
      my $simple = _gu_repo_simple($repo, 0);
      push @repos, $simple if $simple;
    }
    last if @$json < 50;
  }
  @repos = sort { lc($a->{full_name}) cmp lc($b->{full_name}) } @repos;
  $git_upload_repo_cache = \@repos;
  $git_upload_repo_cache_at = time();
  my @filtered = $require_push ? grep { $_->{can_push} } @repos : @repos;
  return \@filtered;
}


sub _gu_repo_path {
  my ($value, $allow_empty) = @_;
  my $rel = defined($value) ? "$value" : '';
  $rel =~ s{\\}{/}g;
  $rel =~ s{^/+}{};
  $rel =~ s{/+$}{};
  return '' if $allow_empty && $rel eq '';
  _gu_fail('Repository-Pfad fehlt') if $rel eq '';
  _gu_fail('Repository-Pfad ungueltig') if length($rel) > 2048 || $rel =~ /[\x00-\x1f\x7f]/;
  my @parts = split m{/}, $rel, -1;
  for my $part (@parts) {
    _gu_fail('Repository-Pfad ungueltig') if $part eq '' || $part eq '.' || $part eq '..';
  }
  return join('/', @parts);
}

sub _gu_api_repo_path {
  my ($path) = @_;
  return join('/', map { url_escape($_) } split m{/}, ($path // ''));
}

sub _gu_repo_tree {
  my ($owner, $repo, $branch, $dir) = @_;
  _gu_validate_owner_repo($owner, $repo);
  _gu_fail('Owner ist fuer Repository-Browser nicht erlaubt') unless _gu_owner_allowed($owner);
  _gu_fail('Branch ungueltig') unless _gu_valid_branch($branch);
  $dir = _gu_repo_path($dir, 1);
  my $suffix = $dir eq '' ? '' : '/' . _gu_api_repo_path($dir);
  my $json = _gu_api('GET', '/api/v1/repos/' . url_escape($owner) . '/' . url_escape($repo) . '/contents' . $suffix . '?ref=' . url_escape($branch));
  my @items = ref($json) eq 'ARRAY' ? @$json : ($json);
  my @out;
  for my $e (@items) {
    next unless ref($e) eq 'HASH';
    my $type = $e->{type} // '';
    next unless $type eq 'file' || $type eq 'dir' || $type eq 'symlink' || $type eq 'submodule';
    push @out, {
      name=>($e->{name}//''), path=>($e->{path}//''), type=>$type,
      size=>0+($e->{size}//0), sha=>($e->{sha}//''),
    };
  }
  @out = sort { ($a->{type} eq 'dir' ? 0 : 1) <=> ($b->{type} eq 'dir' ? 0 : 1) || lc($a->{name}) cmp lc($b->{name}) } @out;
  return {ok=>true(), path=>$dir, items=>\@out};
}

sub _gu_repo_file {
  my ($owner, $repo, $branch, $file) = @_;
  _gu_validate_owner_repo($owner, $repo);
  _gu_fail('Owner ist fuer Repository-Browser nicht erlaubt') unless _gu_owner_allowed($owner);
  _gu_fail('Branch ungueltig') unless _gu_valid_branch($branch);
  $file = _gu_repo_path($file, 0);
  my $json = _gu_api('GET', '/api/v1/repos/' . url_escape($owner) . '/' . url_escape($repo) . '/contents/' . _gu_api_repo_path($file) . '?ref=' . url_escape($branch));
  _gu_fail('Datei-Antwort ungueltig') unless ref($json) eq 'HASH' && ($json->{type}//'') eq 'file';
  my $size = 0 + ($json->{size}//0);
  _gu_fail('Datei ist fuer Browser zu gross (max. 2 MiB)') if $size > 2_097_152;
  my $encoding = lc($json->{encoding}//'base64');
  _gu_fail('Nicht unterstuetzte Datei-Codierung') unless $encoding eq 'base64';
  my $content = decode_base64($json->{content}//'');
  my $binary = index($content, "\0") >= 0 ? 1 : 0;
  return {ok=>true(), path=>$file, name=>($json->{name}//basename($file)), sha=>($json->{sha}//''), size=>$size, binary=>($binary?true():false()), content=>($binary?'':$content)};
}

sub _gu_repo_commits {
  my ($owner, $repo, $branch, $file, $limit) = @_;
  _gu_validate_owner_repo($owner, $repo);
  _gu_fail('Owner ist fuer Repository-Browser nicht erlaubt') unless _gu_owner_allowed($owner);
  _gu_fail('Branch ungueltig') unless _gu_valid_branch($branch);
  $limit = 0 + ($limit || 30); $limit = 30 if $limit < 1; $limit = 50 if $limit > 50;
  my $pathq = '';
  if (defined($file) && "$file" ne '') { my $rp = _gu_repo_path($file,0); $pathq = '&path=' . url_escape($rp); }
  my $json = _gu_api('GET', '/api/v1/repos/' . url_escape($owner) . '/' . url_escape($repo) . '/commits?sha=' . url_escape($branch) . '&limit=' . $limit . $pathq, undef, {empty_json=>[]});
  _gu_fail('Commit-Liste ungueltig') unless ref($json) eq 'ARRAY';
  my @out;
  for my $c (@$json) {
    next unless ref($c) eq 'HASH';
    my $cm = ref($c->{commit}) eq 'HASH' ? $c->{commit} : {};
    my $author = ref($cm->{author}) eq 'HASH' ? $cm->{author} : {};
    my @parents;
    if (ref($c->{parents}) eq 'ARRAY') { @parents = map { ref($_) eq 'HASH' ? ($_->{sha}//'') : '' } @{$c->{parents}}; @parents = grep { $_ ne '' } @parents; }
    push @out, {sha=>($c->{sha}//''), message=>($cm->{message}//''), author=>($author->{name}//''), email=>($author->{email}//''), date=>($author->{date}//''), parents=>\@parents};
  }
  return {ok=>true(), commits=>\@out};
}

sub _gu_repo_compare {
  my ($owner, $repo, $base, $head) = @_;
  _gu_validate_owner_repo($owner, $repo);
  _gu_fail('Owner ist fuer Repository-Browser nicht erlaubt') unless _gu_owner_allowed($owner);
  _gu_fail('Commit SHA ungueltig') unless defined($base) && defined($head) && $base =~ /^[0-9a-f]{7,64}$/i && $head =~ /^[0-9a-f]{7,64}$/i;
  my $json = _gu_api('GET', '/api/v1/repos/' . url_escape($owner) . '/' . url_escape($repo) . '/compare/' . url_escape($base) . '...' . url_escape($head));
  _gu_fail('Compare-Antwort ungueltig') unless ref($json) eq 'HASH';
  my @files;
  if (ref($json->{files}) eq 'ARRAY') {
    for my $f (@{$json->{files}}) {
      next unless ref($f) eq 'HASH';
      my $patch = $f->{patch}//''; $patch = substr($patch,0,200_000) if length($patch) > 200_000;
      push @files, {filename=>($f->{filename}//''), status=>($f->{status}//''), additions=>0+($f->{additions}//0), deletions=>0+($f->{deletions}//0), changes=>0+($f->{changes}//0), patch=>$patch};
    }
  }
  return {ok=>true(), files=>\@files, total_commits=>0+($json->{total_commits}//0)};
}

sub _gu_repo_update_file {
  my ($payload) = @_;
  _gu_require_ready();
  _gu_fail('JSON-Body fehlt') unless ref($payload) eq 'HASH';
  my $owner = $payload->{owner}//''; my $repo = $payload->{repository}//''; my $branch = $payload->{branch}//'';
  _gu_validate_owner_repo($owner,$repo); _gu_fail('Owner ist nicht erlaubt') unless _gu_owner_allowed($owner);
  _gu_fail('Branch ungueltig') unless _gu_valid_branch($branch);
  my $file = _gu_repo_path($payload->{path}//'',0);
  my $sha = $payload->{sha}//''; _gu_fail('Datei-SHA ungueltig') unless $sha =~ /^[0-9a-f]{40,64}$/i;
  my $message = $payload->{message}//''; _gu_fail('Commit-Nachricht ungueltig') if ref($message) || $message !~ /\S/ || length($message) > 500;
  my $content = $payload->{content}; _gu_fail('Dateiinhalt fehlt') unless defined($content) && !ref($content);
  _gu_fail('Dateiinhalt ist zu gross (max. 2 MiB)') if length($content) > 2_097_152;
  _gu_fail('Binaere Inhalte koennen nicht im Browser editiert werden') if index($content, "\0") >= 0;
  my $meta = _gu_repo_meta($owner,$repo); _gu_fail('Repository ist nicht beschreibbar') unless $meta->{can_push};
  my $result = _gu_api('PUT', '/api/v1/repos/' . url_escape($owner) . '/' . url_escape($repo) . '/contents/' . _gu_api_repo_path($file), {
    branch=>$branch, sha=>$sha, message=>$message, content=>encode_base64($content,''),
    author=>{name=>$git_upload_commit_name,email=>$git_upload_commit_email},
    committer=>{name=>$git_upload_commit_name,email=>$git_upload_commit_email},
  });
  return {ok=>true(), result=>$result};
}
sub _gu_validate_owner_repo {
  my ($owner, $repo) = @_;
  _gu_fail('Repository-Owner ungueltig') unless defined($owner) && !ref($owner) && $owner =~ /^[A-Za-z0-9_.-]{1,128}$/;
  _gu_fail('Repository-Name ungueltig') unless defined($repo) && !ref($repo) && $repo =~ /^[A-Za-z0-9_.-]{1,128}$/;
  _gu_fail("Repository-Owner ist nicht erlaubt: $owner") unless _gu_owner_allowed($owner);
}

sub _gu_repo_meta {
  my ($owner, $repo) = @_;
  _gu_validate_owner_repo($owner, $repo);
  my $json = _gu_api('GET', '/api/v1/repos/' . url_escape($owner) . '/' . url_escape($repo));
  _gu_fail('Forgejo Repository-Antwort ungueltig') unless ref($json) eq 'HASH';
  my $simple = _gu_repo_simple($json, 0);
  _gu_fail('Repository ist archiviert oder nicht erlaubt') unless $simple;
  _gu_fail('Repository-Zuordnung stimmt nicht') unless lc($simple->{owner}) eq lc($owner) && lc($simple->{name}) eq lc($repo);
  _gu_validate_clone_url($simple->{clone_url});
  return $simple;
}

sub _gu_validate_clone_url {
  my ($clone_url) = @_;
  _gu_fail('Forgejo clone_url fehlt') unless defined($clone_url) && !ref($clone_url) && length($clone_url);
  my $clone = Mojo::URL->new($clone_url);
  my $base = Mojo::URL->new($git_upload_base_url);
  my $scheme = lc($clone->scheme // '');
  _gu_fail('Forgejo clone_url muss HTTP/HTTPS verwenden') unless $scheme eq 'https' || ($scheme eq 'http' && $git_upload_allow_http);
  _gu_fail('Zugangsdaten in clone_url sind verboten') if length($clone->userinfo // '');
  _gu_fail('clone_url Host weicht von base_url ab') unless lc($clone->host // '') eq lc($base->host // '');
  my $clone_port = $clone->port // ($scheme eq 'https' ? 443 : 80);
  my $base_scheme = lc($base->scheme // '');
  my $base_port = $base->port // ($base_scheme eq 'https' ? 443 : 80);
  _gu_fail('clone_url Port weicht von base_url ab') unless $clone_port == $base_port;
  return 1;
}

sub _gu_create_repository {
  my ($payload) = @_;
  _gu_require_ready();
  _gu_fail('JSON-Body fehlt') unless ref($payload) eq 'HASH';
  my $owner = $payload->{owner} // '';
  my $name = $payload->{name} // '';
  _gu_validate_owner_repo($owner, $name);
  my $description = $payload->{description} // '';
  _gu_fail('Repository-Beschreibung ungueltig') if ref($description) || length($description) > 1024 || $description =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
  my $default_branch = $payload->{default_branch} // 'main';
  _gu_fail('Default-Branch ungueltig') unless _gu_valid_branch($default_branch);
  my $private = exists($payload->{private}) ? _gu_bool_value($payload->{private}, 'repository.private') : 1;

  # Verify the authenticated Forgejo identity and its effective organization
  # permission before attempting repository creation. Forgejo can intentionally
  # return 404 for unauthorized organization resources, so fail with a useful
  # local diagnostic instead of exposing that opaque response to the portal.
  my $me = _gu_api('GET', '/api/v1/user');
  _gu_fail('Forgejo Benutzer-Antwort ungueltig') unless ref($me) eq 'HASH';
  my $login = $me->{login} // $me->{username} // '';
  _gu_fail('Forgejo Benutzername fehlt') unless $login =~ /^[A-Za-z0-9_.-]{1,128}$/;
  my $orgs = _gu_api('GET', '/api/v1/user/orgs?limit=100');
  _gu_fail('Forgejo Organisationsliste ungueltig') unless ref($orgs) eq 'ARRAY';
  my $org_visible = 0;
  for my $org (@$orgs) {
    next unless ref($org) eq 'HASH';
    my $org_name = $org->{name} // $org->{username} // '';
    if (lc($org_name) eq lc($owner)) { $org_visible = 1; last }
  }
  _gu_fail("Forgejo Service-User $login ist kein sichtbares Mitglied der Organisation $owner") unless $org_visible;

  # Fail fast on an existing name.  Do not silently reuse or overwrite repositories.
  my $exists = eval { _gu_repo_meta($owner, $name); 1 };
  if ($exists) { _gu_fail("Repository existiert bereits: $owner/$name") }
  my $err = $@;
  if ($err) {
    # _gu_fail() throws a blessed GitUploadError object.  Never regex-match the
    # raw $@ value because Perl stringifies it as GitUploadError=HASH(...),
    # hiding the actual Forgejo message.  A 404 here is the expected result for
    # a repository name that is still free.
    my $err_msg = _gu_error_message($err);
    if ($err_msg !~ /Forgejo API HTTP 404|nicht gefunden|Not Found/i) {
      die $err;
    }
  }

  my $created = eval { _gu_api('POST', '/api/v1/orgs/' . url_escape($owner) . '/repos', {
    name=>$name,
    description=>$description,
    private=>($private ? true() : false()),
    auto_init=>false(),
    default_branch=>$default_branch,
  }) };
  if (!$created) {
    my $e = $@ || 'unbekannter Forgejo Fehler';
    my $e_msg = _gu_error_message($e);
    if ($e_msg =~ /Forgejo API HTTP 404/i) {
      _gu_fail("Forgejo liefert 404 bei Repository-Erstellung fuer $owner; Organisation/Service-User-Zuordnung oder Token-Repository-Scope ist nicht konsistent. setup_teko_local.sh --force muss den Repository-Create Capability-Probe erfolgreich abschliessen");
    }
    die $e;
  }
  _gu_fail('Forgejo Create-Repository-Antwort ungueltig') unless ref($created) eq 'HASH';
  my $simple = _gu_repo_simple($created, 0);
  _gu_fail('Neu erstelltes Repository ist nicht zugaenglich oder nicht erlaubt') unless $simple;
  _gu_fail('Neu erstelltes Repository ist nicht beschreibbar') unless $simple->{can_push};
  $git_upload_repo_cache = [];
  $git_upload_repo_cache_at = 0;
  return {ok=>true(), repository=>$simple};
}

sub _gu_branches {
  my ($owner, $repo) = @_;
  my $meta = _gu_repo_meta($owner, $repo);
  my @branches;
  for my $page (1..100) {
    # Forgejo liefert fuer ein frisch angelegtes, noch leeres Repository je nach
    # Version 204/empty body bzw. JSON null statt []. Das ist kein Fehler: es
    # existiert schlicht noch kein Branch. Nur fuer diesen Endpoint wird eine
    # leere erfolgreiche Antwort deshalb als leeres Branch-Array interpretiert.
    my $json = _gu_api('GET', '/api/v1/repos/' . url_escape($owner) . '/' . url_escape($repo) . "/branches?limit=50&page=$page", undef, {empty_json=>[]});
    _gu_fail('Forgejo Branch-Antwort ist kein Array') unless ref($json) eq 'ARRAY';
    for my $b (@$json) {
      next unless ref($b) eq 'HASH';
      my $name = $b->{name} // '';
      next unless _gu_valid_branch($name);
      my $sha = ref($b->{commit}) eq 'HASH' ? ($b->{commit}{id} // $b->{commit}{sha} // '') : '';
      push @branches, {name=>$name, commit=>$sha, protected=>($b->{protected} ? true() : false())};
    }
    last if @$json < 50;
  }
  return {repository=>$meta, branches=>\@branches};
}

sub _gu_valid_branch {
  my ($branch) = @_;
  return 0 unless defined($branch) && !ref($branch) && length($branch) <= 128;
  return 0 unless $branch =~ /^[A-Za-z0-9][A-Za-z0-9._\/-]*$/;
  return 0 if $branch =~ m{//|\.\.|/\z|\A/|\.lock\z|\@\{};
  return 1;
}

sub _gu_validate_relpath {
  my ($rel) = @_;
  _gu_fail('Leerer relativer Dateipfad') unless defined($rel) && !ref($rel) && length($rel);
  $rel =~ s{\\}{/}g;
  $rel =~ s{^\./+}{};
  _gu_fail('Absoluter Pfad ist verboten') if $rel =~ m{^/} || $rel =~ /^[A-Za-z]:\//;
  _gu_fail('Ungueltiger Pfad') if $rel =~ /[\x00-\x1f\x7f]/;
  my @parts = split m{/+}, $rel;
  _gu_fail('Ungueltiger Pfadbestandteil') if grep { $_ eq '' || $_ eq '.' || $_ eq '..' } @parts;
  _gu_fail('Pfad ist zu lang') if length($rel) > 1024;
  return join('/', @parts);
}

sub _gu_glob_regex {
  my ($pattern) = @_;
  my $rx = quotemeta($pattern // '');
  $rx =~ s/\\\*\\\*/.*/g;
  $rx =~ s{\\\*}{[^/]*}g;
  $rx =~ s{\\\?}{[^/]}g;
  return qr/^$rx$/i;
}

sub _gu_matches_any {
  my ($rel, $patterns) = @_;
  for my $pattern (@$patterns) {
    next unless defined($pattern) && !ref($pattern) && length($pattern);
    return 1 if $rel =~ _gu_glob_regex($pattern);
    return 1 if basename($rel) =~ _gu_glob_regex($pattern);
  }
  return 0;
}

sub _gu_is_ignored {
  my ($rel) = @_;
  return 1 if $rel eq '.git' || $rel =~ m{(?:^|/)\.git(?:/|$)};
  return _gu_matches_any($rel, $git_upload_ignore_patterns);
}

sub _gu_secret_warnings {
  my ($rel, $full) = @_;
  my @warnings;
  push @warnings, "Sensibler Dateiname: $rel" if _gu_matches_any($rel, $git_upload_secret_patterns);
  if (-f $full && -s $full <= 2_097_152) {
    if (open my $fh, '<:raw', $full) {
      read($fh, my $head, 131072);
      close $fh;
      push @warnings, "Privater Schluessel erkannt: $rel" if $head =~ /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/;
      push @warnings, "Moegliches Secret im Inhalt: $rel" if $head =~ /(?:password|passwd|api[_-]?token|secret|private[_-]?key)\s*[:=]\s*[^\s"']{6,}/i;
    }
  }
  return @warnings;
}

sub _gu_make_stage_id {
  my ($actor) = @_;
  return substr(sha256_hex(join(':', time(), $$, rand(), ($actor // ''), $git_upload_base_url)), 0, 32);
}

sub _gu_stage_path {
  my ($stage_id) = @_;
  _gu_fail('Stage-ID ungueltig') unless defined($stage_id) && $stage_id =~ /^[0-9a-f]{32}$/;
  return "$git_upload_stage_root/$stage_id";
}

sub _gu_write_json {
  my ($file, $value) = @_;
  safe_write_file($file, _pretty_json_text($value), 1);
  chmod(0660, $file);
}

sub _gu_read_stage {
  my ($stage_id) = @_;
  my $root = _gu_stage_path($stage_id);
  my $meta_file = "$root/meta.json";
  _gu_fail('Upload-Stage nicht gefunden oder abgelaufen') unless -f $meta_file && !-l $meta_file;
  my $meta = eval { decode_json(read_all($meta_file)) };
  _gu_fail('Upload-Stage Metadaten ungueltig') if $@ || ref($meta) ne 'HASH';
  _gu_fail('Upload-Stage ist abgelaufen') if time() - ($meta->{created_at_epoch} // 0) > $git_upload_ttl;
  _gu_fail('Upload-Stage Inhalt fehlt') unless -d "$root/content" && !-l "$root/content";
  return ($root, $meta);
}

sub _gu_cleanup_stages {
  return unless -d $git_upload_stage_root;
  opendir(my $dh, $git_upload_stage_root) or return;
  for my $name (readdir($dh)) {
    next unless $name =~ /^[0-9a-f]{32}$/;
    my $root = "$git_upload_stage_root/$name";
    next unless -d $root && !-l $root;
    my $mtime = (stat($root))[9] // time();
    remove_tree($root) if time() - $mtime > $git_upload_ttl;
  }
  closedir($dh);
}

sub _gu_common_top {
  my ($paths) = @_;
  return '' unless ref($paths) eq 'ARRAY' && @$paths;
  my ($first) = split m{/}, $paths->[0], 2;
  return '' unless defined($first) && length($first);
  for my $p (@$paths) {
    my ($top, $rest) = split m{/}, $p, 2;
    return '' unless defined($rest) && length($rest) && $top eq $first;
  }
  return $first;
}

sub _gu_move_upload_to {
  my ($upload, $target) = @_;
  my $parent = dirname($target);
  make_path($parent, {mode=>0770}) unless -d $parent;
  _gu_fail("Upload-Ziel ist ein Symlink: $target") if -l $target;
  my $ok = eval { $upload->move_to($target); 1 };
  _gu_fail("Upload konnte nicht gespeichert werden: $@") unless $ok && -f $target;
  chmod(0660, $target);
}

sub _gu_copy_file {
  my ($src, $dst) = @_;
  _gu_fail("Quelldatei fehlt: $src") unless -f $src && !-l $src;
  make_path(dirname($dst), {mode=>0770}) unless -d dirname($dst);
  copy($src, $dst) or _gu_fail("Datei konnte nicht kopiert werden: $src -> $dst: $!");
  my $exec = 0;
  if (open my $fh, '<:raw', $src) {
    read($fh, my $head, 2);
    close $fh;
    $exec = 1 if $head eq '#!';
  }
  chmod($exec ? 0755 : 0644, $dst) or _gu_fail("chmod fehlgeschlagen: $dst: $!");
}

sub _gu_scan_content {
  my ($content) = @_;
  my (@files, @ignored, @warnings);
  my $bytes = 0;
  find({
    no_chdir=>1,
    wanted=>sub {
      my $full = $File::Find::name;
      return if $full eq $content;
      my $rel = substr($full, length($content) + 1);
      _gu_fail("Symlink im Upload ist verboten: $rel") if -l $full;
      if (-d $full) {
        if (_gu_is_ignored($rel)) {
          push @ignored, $rel . '/';
          $File::Find::prune = 1;
        }
        return;
      }
      _gu_fail("Nicht regulaerer Upload-Eintrag: $rel") unless -f $full;
      $rel = _gu_validate_relpath($rel);
      if (_gu_is_ignored($rel)) {
        push @ignored, $rel;
        unlink($full);
        return;
      }
      my $size = -s $full;
      $bytes += $size;
      push @files, {path=>$rel, size=>$size};
      push @warnings, _gu_secret_warnings($rel, $full);
      _gu_fail("Upload enthaelt mehr als $git_upload_max_files Dateien") if @files > $git_upload_max_files;
      _gu_fail("Upload ist groesser als $git_upload_max_bytes Bytes") if $bytes > $git_upload_max_bytes;
    }
  }, $content);
  @files = sort { $a->{path} cmp $b->{path} } @files;
  my $sha = Digest::SHA->new(256);
  for my $entry (@files) {
    my $full = "$content/$entry->{path}";
    $sha->add($entry->{path}, "\0", $entry->{size}, "\0");
    open my $fh, '<:raw', $full or _gu_fail("Datei kann nicht gelesen werden: $entry->{path}");
    $sha->addfile($fh);
    close $fh;
  }
  my %seen;
  @warnings = grep { !$seen{$_}++ } @warnings;
  return {files=>\@files, ignored=>\@ignored, warnings=>\@warnings, bytes=>$bytes, digest=>$sha->hexdigest};
}

sub _gu_stage_directory {
  my ($uploads, $paths, $content, $strip_top) = @_;
  _gu_fail('Keine Dateien hochgeladen') unless @$uploads;
  _gu_fail('relative_paths Anzahl stimmt nicht mit Dateien ueberein') unless @$paths == @$uploads;
  my @clean = map { _gu_validate_relpath($_) } @$paths;
  my $top = $strip_top ? _gu_common_top(\@clean) : '';
  my %seen;
  for my $i (0..$#$uploads) {
    my $rel = $clean[$i];
    $rel =~ s/^\Q$top\E\/// if length($top);
    next if _gu_is_ignored($rel);
    _gu_fail("Doppelter Upload-Pfad: $rel") if $seen{$rel}++;
    my $target = "$content/$rel";
    _gu_move_upload_to($uploads->[$i], $target);
  }
  return $top;
}

sub _gu_stage_zip {
  my ($upload, $root, $content, $strip_top) = @_;
  _gu_fail("ZIP-Unterstuetzung benoetigt $git_upload_unzip_bin") unless -f $git_upload_unzip_bin && -x $git_upload_unzip_bin;
  my $zip = "$root/upload.zip";
  _gu_move_upload_to($upload, $zip);
  my $list = _deploy_run_command(
    stage=>'git_upload_zip_list', argv=>[$git_upload_unzip_bin, '-Z1', $zip],
    timeout=>$git_upload_timeout, env=>_git_base_env(), capture_limit=>16_777_216,
  );
  my @names = grep { length } split /\n/, $list->{stdout};
  _gu_fail('ZIP ist leer') unless @names;
  _gu_fail("ZIP enthaelt mehr als $git_upload_max_files Eintraege") if @names > $git_upload_max_files * 2;

  # Vor dem Entpacken die im ZIP deklarierten unkomprimierten Groessen pruefen.
  # Dadurch wird ein offensichtliches ZIP-Bomb-Archiv abgewiesen, bevor es den
  # Staging-Datentraeger fuellen kann. Nach dem Entpacken folgt zusaetzlich die
  # reale Dateisystempruefung durch _gu_scan_content().
  my $sizes = _deploy_run_command(
    stage=>'git_upload_zip_sizes', argv=>[$git_upload_unzip_bin, '-l', $zip],
    timeout=>$git_upload_timeout, env=>_git_base_env(), capture_limit=>16_777_216,
  );
  my $declared_bytes = 0;
  my $declared_files = 0;
  for my $line (split /\n/, $sizes->{stdout}) {
    next unless $line =~ /^\s*(\d+)\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+(.+)$/;
    my ($size, $name) = (0 + $1, $2);
    next if $name =~ m{/\z};
    $declared_files++;
    $declared_bytes += $size;
    _gu_fail("ZIP enthaelt mehr als $git_upload_max_files Dateien") if $declared_files > $git_upload_max_files;
    _gu_fail("ZIP ist entpackt groesser als $git_upload_max_bytes Bytes") if $declared_bytes > $git_upload_max_bytes;
  }
  _gu_fail('ZIP-Dateiliste konnte nicht sicher ausgewertet werden') if $declared_files < 1;
  for my $name (@names) {
    $name =~ s/\r\z//;
    my $check = $name;
    $check =~ s{/\z}{};
    _gu_validate_relpath($check) if length($check);
    _gu_fail('ZIP enthaelt .git-Inhalte') if $check eq '.git' || $check =~ m{(?:^|/)\.git(?:/|$)};
  }
  my $raw = "$root/raw";
  make_path($raw, {mode=>0770});
  _deploy_run_command(
    stage=>'git_upload_zip_extract', argv=>[$git_upload_unzip_bin, '-qq', '-o', $zip, '-d', $raw],
    timeout=>$git_upload_timeout, env=>_git_base_env(), capture_limit=>4_194_304,
  );
  my @top_entries;
  opendir(my $dh, $raw) or _gu_fail("ZIP-Ziel kann nicht gelesen werden: $!");
  @top_entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
  closedir($dh);
  my $source = $raw;
  my $stripped = '';
  if ($strip_top && @top_entries == 1 && -d "$raw/$top_entries[0]" && !-l "$raw/$top_entries[0]") {
    $source = "$raw/$top_entries[0]";
    $stripped = $top_entries[0];
  }
  find({
    no_chdir=>1,
    wanted=>sub {
      my $full = $File::Find::name;
      return if $full eq $source;
      _gu_fail('Symlinks in ZIP sind verboten') if -l $full;
      return if -d $full;
      _gu_fail('Nicht regulaerer ZIP-Eintrag') unless -f $full;
      my $rel = _gu_validate_relpath(substr($full, length($source)+1));
      return if _gu_is_ignored($rel);
      _gu_copy_file($full, "$content/$rel");
    }
  }, $source);
  return $stripped;
}

sub _gu_stage_upload {
  my ($c) = @_;
  _gu_require_ready();
  _gu_cleanup_stages();
  my $upload_type = lc($c->param('upload_type') // 'directory');
  _gu_fail('upload_type muss directory oder zip sein') unless $upload_type eq 'directory' || $upload_type eq 'zip';
  my $strip_raw = $c->param('strip_top_level');
  my $strip_top = defined($strip_raw) ? ($strip_raw =~ /^(?:1|true|yes)$/i ? 1 : 0) : 1;
  my $actor = $c->req->headers->header('X-Deploy-Actor') // 'portal-user';
  $actor =~ s/[\x00-\x1f\x7f]/?/g;
  $actor = substr($actor, 0, 128);
  my $uploads_ref = $c->req->uploads;
  my @uploads = ref($uploads_ref) eq 'ARRAY' ? @$uploads_ref : ();
  _gu_fail('Keine Upload-Datei empfangen') unless @uploads;
  my $expected = $c->param('expected_count') // '';
  _gu_fail('Unvollstaendiger Browser-Upload: Dateianzahl stimmt nicht') if $expected =~ /^\d+$/ && $expected != @uploads;
  my $paths_raw = $c->param('relative_paths') // '[]';
  my $paths = eval { decode_json($paths_raw) };
  _gu_fail('relative_paths ist kein gueltiges JSON-Array') if $@ || ref($paths) ne 'ARRAY';

  my $stage_id = _gu_make_stage_id($actor);
  my $root = _gu_stage_path($stage_id);
  my $content = "$root/content";
  make_path($content, {mode=>0770});
  my $stripped_top = '';
  my $ok = eval {
    if ($upload_type eq 'directory') {
      $stripped_top = _gu_stage_directory(\@uploads, $paths, $content, $strip_top);
    } else {
      _gu_fail('ZIP-Upload erwartet genau eine Datei') unless @uploads == 1;
      $stripped_top = _gu_stage_zip($uploads[0], $root, $content, $strip_top);
    }
    my $scan = _gu_scan_content($content);
    _gu_fail('Upload enthaelt nach Filterung keine Dateien') unless @{$scan->{files}};
    my $meta = {
      schema_version=>1,
      stage_id=>$stage_id,
      upload_type=>$upload_type,
      created_at_epoch=>time(),
      created_at=>scalar(gmtime()).'Z',
      actor=>$actor,
      stripped_top_level=>$stripped_top,
      file_count=>scalar(@{$scan->{files}}),
      bytes=>$scan->{bytes},
      digest=>$scan->{digest},
      files=>$scan->{files},
      ignored=>$scan->{ignored},
      warnings=>$scan->{warnings},
    };
    _gu_write_json("$root/meta.json", $meta);
    $meta;
  };
  if (!defined($ok) || $@) {
    my $err = $@;
    remove_tree($root) if -d $root;
    die $err;
  }
  return $ok;
}

sub _gu_git_identity {
  my $json = _gu_api('GET', '/api/v1/user');
  _gu_fail('Forgejo Benutzerantwort ungueltig') unless ref($json) eq 'HASH';
  my $login = $json->{login} // $json->{username} // '';
  _gu_fail('Forgejo Benutzername ungueltig') unless $login =~ /^[A-Za-z0-9_.@+-]{1,128}$/;
  return $login;
}

sub _gu_auth_env {
  my ($token, $login) = @_;
  my $profile = {auth_scheme=>'basic', deploy_user=>$login};
  $profile->{ca_info} = $git_upload_ca_file if $git_upload_verify_tls && defined($git_upload_ca_file) && length($git_upload_ca_file);
  return _git_env_with_auth($profile, $token);
}

sub _gu_rm_workspace {
  my ($dir) = @_;
  return unless defined($dir) && $dir =~ /^\Q$git_upload_work_root\E\/[0-9a-f]{32}$/ && -d $dir;
  remove_tree($dir);
}

sub _gu_branch_map {
  my ($owner, $repo) = @_;
  my $data = _gu_branches($owner, $repo);
  my %map = map { $_->{name} => ($_->{commit} // '') } @{$data->{branches}};
  return ($data->{repository}, \%map);
}

sub _gu_prepare_workspace {
  my (%arg) = @_;
  my ($owner, $repo, $branch, $base_branch) = @arg{qw(owner repo branch base_branch)};
  _gu_fail('Branch ungueltig') unless _gu_valid_branch($branch);
  _gu_fail('Basis-Branch ungueltig') if defined($base_branch) && length($base_branch) && !_gu_valid_branch($base_branch);
  my ($meta, $branches) = _gu_branch_map($owner, $repo);
  my $branch_exists = exists $branches->{$branch};
  my $default_branch = $meta->{default_branch} || 'main';
  my $base = (defined($base_branch) && length($base_branch)) ? $base_branch : $default_branch;
  my $token = _gu_read_token();
  my $login = _gu_git_identity();
  my ($env, $secrets) = _gu_auth_env($token, $login);
  my $work_id = substr(sha256_hex(join(':', time(), $$, rand(), $owner, $repo, $branch)), 0, 32);
  my $workspace = "$git_upload_work_root/$work_id";
  my $clone_url = $meta->{clone_url};
  my $remote_head = '';
  my $base_head = '';

  if ($branch_exists) {
    _deploy_run_command(stage=>'git_upload_clone', argv=>[$git_bin, 'clone', '--no-tags', '--single-branch', '--branch', $branch, '--', $clone_url, $workspace], timeout=>$git_upload_timeout, env=>$env, secrets=>$secrets);
    $remote_head = $branches->{$branch} // '';
  } elsif (%$branches) {
    _gu_fail("Basis-Branch nicht gefunden: $base") unless exists $branches->{$base};
    _deploy_run_command(stage=>'git_upload_clone_base', argv=>[$git_bin, 'clone', '--no-tags', '--single-branch', '--branch', $base, '--', $clone_url, $workspace], timeout=>$git_upload_timeout, env=>$env, secrets=>$secrets);
    _deploy_run_command(stage=>'git_upload_new_branch', argv=>[$git_bin, '-C', $workspace, 'checkout', '-b', $branch], timeout=>$git_upload_timeout, env=>_git_base_env());
    $base_head = $branches->{$base} // '';
  } else {
    make_path($workspace, {mode=>0770});
    _deploy_run_command(stage=>'git_upload_init', argv=>[$git_bin, '-C', $workspace, 'init', '-b', $branch], timeout=>$git_upload_timeout, env=>_git_base_env());
    _deploy_run_command(stage=>'git_upload_remote', argv=>[$git_bin, '-C', $workspace, 'remote', 'add', 'origin', $clone_url], timeout=>$git_upload_timeout, env=>_git_base_env());
  }
  return {
    workspace=>$workspace, repository=>$meta, branches=>$branches,
    branch_exists=>$branch_exists, remote_head=>$remote_head, base_head=>$base_head,
    token=>$token, login=>$login, env=>$env, secrets=>$secrets,
  };
}

sub _gu_clear_worktree {
  my ($workspace) = @_;
  opendir(my $dh, $workspace) or _gu_fail("Workspace kann nicht gelesen werden: $!");
  for my $name (readdir($dh)) {
    next if $name eq '.' || $name eq '..' || $name eq '.git';
    my $p = "$workspace/$name";
    _gu_fail('Symlink im Workspace-Root ist verboten') if -l $p;
    if (-d $p) { remove_tree($p); }
    elsif (-f $p) { unlink($p) or _gu_fail("Datei konnte nicht entfernt werden: $p: $!"); }
    else { _gu_fail("Unerwarteter Workspace-Eintrag: $p"); }
  }
  closedir($dh);
}

sub _gu_safe_relative_symlink {
  my ($workspace, $full, $rel) = @_;
  my $link = readlink($full);
  _gu_fail("readlink fehlgeschlagen: $rel") unless defined $link;
  _gu_fail("NUL im Symlink-Ziel: $rel") if $link =~ /\0/;
  _gu_fail("Absoluter Symlink ist nicht erlaubt: $rel -> $link") if $link =~ m{^/};
  my $base = dirname($rel);
  my @parts;
  for my $part (split m{/+}, ($base eq '.' ? '' : "$base/") . $link) {
    next if $part eq '' || $part eq '.';
    if ($part eq '..') {
      _gu_fail("Symlink verlaesst Repository: $rel -> $link") unless @parts;
      pop @parts;
      next;
    }
    push @parts, $part;
  }
  return join('/', @parts);
}

sub _gu_assert_workspace_safe {
  my ($workspace, $allow_repo_symlinks) = @_;
  $allow_repo_symlinks = 0 unless defined $allow_repo_symlinks;
  find({
    no_chdir=>1,
    wanted=>sub {
      my $full = $File::Find::name;
      return if $full eq $workspace;
      my $rel = substr($full, length($workspace)+1);
      if ($rel eq '.git' || $rel =~ m{^\.git/}) {
        $File::Find::prune = 1 if -d $full;
        return;
      }
      if (-l $full) {
        _gu_fail("Symlink im Repository-Workspace ist fuer Web-Upload nicht erlaubt: $rel") unless $allow_repo_symlinks;
        _gu_safe_relative_symlink($workspace, $full, $rel);
        return;
      }
      _gu_fail("Unerwarteter Repository-Eintrag: $rel") unless -d $full || -f $full;
      if (-f $full) {
        my $nlink = (stat($full))[3] // 1;
        _gu_fail("Hardlink im Repository-Workspace ist nicht erlaubt: $rel") if $nlink > 1;
      }
    }
  }, $workspace);
}

sub _gu_apply_stage {
  my ($stage_root, $workspace, $mode) = @_;
  _gu_fail('Upload-Modus muss update oder mirror sein') unless $mode eq 'update' || $mode eq 'mirror';
  _gu_fail('Mirror-Modus ist serverseitig deaktiviert') if $mode eq 'mirror' && !$git_upload_allow_mirror;
  _gu_assert_workspace_safe($workspace);
  _gu_clear_worktree($workspace) if $mode eq 'mirror';
  my $content = "$stage_root/content";
  find({
    no_chdir=>1,
    wanted=>sub {
      my $src = $File::Find::name;
      return if $src eq $content;
      my $rel = substr($src, length($content)+1);
      _gu_fail("Symlink im Stage ist verboten: $rel") if -l $src;
      if (-d $src) {
        make_path("$workspace/$rel", {mode=>0755}) unless -d "$workspace/$rel";
        return;
      }
      _gu_fail("Nicht regulaere Stage-Datei: $rel") unless -f $src;
      _gu_copy_file($src, "$workspace/$rel");
    }
  }, $content);
}

sub _gu_staged_changes {
  my ($workspace) = @_;
  _deploy_run_command(stage=>'git_upload_add', argv=>[$git_bin, '-C', $workspace, 'add', '--all'], timeout=>$git_upload_timeout, env=>_git_base_env());
  my $res = _deploy_run_command(stage=>'git_upload_diff', argv=>[$git_bin, '-C', $workspace, 'diff', '--cached', '--name-status', '-z', '--find-renames=50%'], timeout=>$git_upload_timeout, env=>_git_base_env(), capture_limit=>16_777_216);
  my @parts = split /\0/, $res->{stdout}, -1;
  pop @parts if @parts && $parts[-1] eq '';
  my @changes;
  while (@parts) {
    my $status = shift @parts;
    _gu_fail('Unerwartetes git diff Format') unless defined($status) && $status =~ /^[ACDMRTUXB][0-9]*$/;
    if ($status =~ /^[RC]/) {
      my $old = shift @parts;
      my $new = shift @parts;
      _gu_fail('Unerwartetes Rename/Copy Format') unless defined($old) && defined($new);
      push @changes, {status=>$status, path=>$new, old_path=>$old};
    } else {
      my $p = shift @parts;
      _gu_fail('Unerwartetes git diff Format') unless defined $p;
      push @changes, {status=>$status, path=>$p};
    }
    _gu_fail('Zu viele Aenderungen fuer Vorschau') if @changes > $git_upload_max_files * 2;
  }
  my %counts = (added=>0, modified=>0, deleted=>0, renamed=>0, copied=>0, other=>0);
  for my $c (@changes) {
    my $s = substr($c->{status}, 0, 1);
    if ($s eq 'A') { $counts{added}++ }
    elsif ($s eq 'M') { $counts{modified}++ }
    elsif ($s eq 'D') { $counts{deleted}++ }
    elsif ($s eq 'R') { $counts{renamed}++ }
    elsif ($s eq 'C') { $counts{copied}++ }
    else { $counts{other}++ }
  }
  return {changes=>\@changes, counts=>\%counts, has_changes=>(@changes ? true() : false())};
}

sub _gu_validate_request_payload {
  my ($payload) = @_;
  _gu_fail('JSON-Body fehlt') unless ref($payload) eq 'HASH';
  my $stage_id = $payload->{stage_id} // '';
  _gu_stage_path($stage_id);
  my $owner = $payload->{owner} // '';
  my $repo = $payload->{repository} // '';
  _gu_validate_owner_repo($owner, $repo);
  my $branch = $payload->{branch} // '';
  _gu_fail('Branch ungueltig') unless _gu_valid_branch($branch);
  my $base_branch = $payload->{base_branch} // '';
  _gu_fail('Basis-Branch ungueltig') if length($base_branch) && !_gu_valid_branch($base_branch);
  my $mode = lc($payload->{mode} // 'update');
  _gu_fail('Modus muss update oder mirror sein') unless $mode eq 'update' || $mode eq 'mirror';
  _gu_fail('Mirror-Modus ist deaktiviert') if $mode eq 'mirror' && !$git_upload_allow_mirror;
  return ($stage_id, $owner, $repo, $branch, $base_branch, $mode);
}

sub _gu_preview_execute {
  my ($payload) = @_;
  _gu_require_ready();
  my ($stage_id, $owner, $repo, $branch, $base_branch, $mode) = _gu_validate_request_payload($payload);
  my ($stage_root, $stage) = _gu_read_stage($stage_id);
  my $prepared;
  my $result;
  eval {
    $prepared = _gu_prepare_workspace(owner=>$owner, repo=>$repo, branch=>$branch, base_branch=>$base_branch);
    _gu_apply_stage($stage_root, $prepared->{workspace}, $mode);
    my $diff = _gu_staged_changes($prepared->{workspace});
    my $default_branch = $prepared->{repository}{default_branch} // 'main';
    _gu_fail('Direkter Upload auf den Default-Branch ist serverseitig deaktiviert')
      if !$git_upload_allow_default_branch && $branch eq $default_branch;
    $result = {
      ok=>true(), stage_id=>$stage_id, stage_digest=>$stage->{digest},
      repository=>"$owner/$repo", owner=>$owner, name=>$repo,
      branch=>$branch, base_branch=>$base_branch,
      branch_exists=>($prepared->{branch_exists} ? true() : false()),
      remote_head=>$prepared->{remote_head}, base_head=>$prepared->{base_head},
      default_branch=>$default_branch,
      mode=>$mode, file_count=>$stage->{file_count}, bytes=>$stage->{bytes},
      warnings=>$stage->{warnings}, ignored=>$stage->{ignored},
      %$diff,
    };
    1;
  } or do {
    my $err = $@;
    _gu_rm_workspace($prepared->{workspace}) if $prepared && $prepared->{workspace};
    die $err;
  };
  _gu_rm_workspace($prepared->{workspace}) if $prepared && $prepared->{workspace};
  return $result;
}

sub _gu_push_execute {
  my ($payload, $actor) = @_;
  _gu_require_ready();
  my ($stage_id, $owner, $repo, $branch, $base_branch, $mode) = _gu_validate_request_payload($payload);
  my ($stage_root, $stage) = _gu_read_stage($stage_id);
  my $expected_digest = $payload->{stage_digest} // '';
  _gu_fail('Stage wurde seit der Vorschau veraendert') if length($expected_digest) && $expected_digest ne ($stage->{digest} // '');
  my $message = $payload->{commit_message} // '';
  $message =~ s/\r\n?/\n/g;
  $message =~ s/[\x00\x0b\x0c\x0e-\x1f\x7f]/?/g;
  $message =~ s/^\s+|\s+$//g;
  _gu_fail('Commit-Nachricht fehlt') unless length($message);
  _gu_fail('Commit-Nachricht ist zu lang') if length($message) > 4096;
  $actor //= 'portal-user';
  $actor =~ s/[\x00-\x1f\x7f]/?/g;
  $actor = substr($actor, 0, 128);
  $message .= "\n\nUploaded-by: $actor";

  return _with_named_locks(["git-upload:$owner/$repo"], sub {
    my $prepared;
    my $result;
    eval {
      $prepared = _gu_prepare_workspace(owner=>$owner, repo=>$repo, branch=>$branch, base_branch=>$base_branch);
      my $expected_head = $payload->{expected_remote_head} // '';
      my $expected_exists = $payload->{expected_branch_exists} ? 1 : 0;
      _gu_fail('Branch-Zustand wurde seit der Vorschau geaendert; Vorschau neu laden')
        if $expected_exists != ($prepared->{branch_exists} ? 1 : 0);
      if ($prepared->{branch_exists}) {
        _gu_fail('Repository wurde seit der Vorschau geaendert; Vorschau neu laden')
          if $expected_head ne ($prepared->{remote_head} // '');
      } else {
        my $expected_base = $payload->{expected_base_head} // '';
        _gu_fail('Basis-Branch wurde seit der Vorschau geaendert; Vorschau neu laden')
          if length($expected_base) && $expected_base ne ($prepared->{base_head} // '');
      }
      my $default_branch = $prepared->{repository}{default_branch} // 'main';
      _gu_fail('Direkter Upload auf den Default-Branch ist serverseitig deaktiviert')
        if !$git_upload_allow_default_branch && $branch eq $default_branch;
      _gu_apply_stage($stage_root, $prepared->{workspace}, $mode);
      my $diff = _gu_staged_changes($prepared->{workspace});
      if (!$diff->{has_changes}) {
        $result = {ok=>true(), noop=>true(), repository=>"$owner/$repo", branch=>$branch, message=>'Keine Aenderungen erkannt', %$diff};
      } else {
        _deploy_run_command(
          stage=>'git_upload_commit',
          argv=>[$git_bin, '-C', $prepared->{workspace}, '-c', "user.name=$git_upload_commit_name", '-c', "user.email=$git_upload_commit_email", 'commit', '--no-gpg-sign', '-m', $message],
          timeout=>$git_upload_timeout, env=>_git_base_env(), capture_limit=>4_194_304,
        );
        my $commit = _deploy_run_command(stage=>'git_upload_rev_parse', argv=>[$git_bin, '-C', $prepared->{workspace}, 'rev-parse', 'HEAD'], timeout=>$git_upload_timeout, env=>_git_base_env());
        my $sha = $commit->{stdout}; $sha =~ s/\s+\z//;
        _deploy_run_command(
          stage=>'git_upload_push',
          argv=>[$git_bin, '-C', $prepared->{workspace}, 'push', '--porcelain', 'origin', "HEAD:refs/heads/$branch"],
          timeout=>$git_upload_timeout, env=>$prepared->{env}, secrets=>$prepared->{secrets}, capture_limit=>8_388_608,
        );
        $result = {
          ok=>true(), noop=>false(), repository=>"$owner/$repo", branch=>$branch,
          commit=>$sha, actor=>$actor, mode=>$mode, stage_id=>$stage_id,
          %$diff,
        };
      }
      1;
    } or do {
      my $err = $@;
      _gu_rm_workspace($prepared->{workspace}) if $prepared && $prepared->{workspace};
      die $err;
    };
    _gu_rm_workspace($prepared->{workspace}) if $prepared && $prepared->{workspace};
    remove_tree($stage_root) if $git_upload_cleanup_on_success && -d $stage_root;
    return $result;
  });
}

sub _gu_json_body {
  my ($c) = @_;
  my $body = _read_body_or_die($c);
  my $payload = eval { decode_json($body) };
  _gu_fail('Ungueltiger JSON-Body') if $@ || ref($payload) ne 'HASH';
  return $payload;
}



# ---------------------------------------------------------------------------
# Repository-Analyse fuer den Deployment-Profil-Assistenten
# ---------------------------------------------------------------------------
sub _gu_scan_example_path {
  my ($rel) = @_;
  my $lc = lc($rel // '');
  return 1 if $lc =~ m{(?:^|/)(?:example|examples|sample|samples|template|templates|test|tests)(?:/|$)};
  return 1 if $lc =~ /(?:\.example|\.sample|\.dist|\.template)(?:\.|$)/;
  return 0;
}

sub _gu_scan_config_candidate {
  my ($rel) = @_;
  return 0 if _gu_scan_example_path($rel);
  my $base = lc(basename($rel // ''));
  return 0 if $base eq 'service-install.ini';
  return 1 if $base =~ /^(?:config|settings|application|app|local|global|managed_configs|git_deploy)\.(?:json|ya?ml|toml|ini|conf)$/;
  return 1 if $base =~ /^(?:.+_config|.+-config)\.(?:json|ya?ml|toml|ini|conf)$/;
  return 1 if $rel !~ m{/} && $base =~ /\.(?:conf|ini|toml|ya?ml)$/;
  return 0;
}

sub _gu_scan_persistent_dir_kind {
  my ($rel) = @_;
  my $base = lc(basename($rel // ''));
  return 'backup'  if $base =~ /^(?:backup|backups|archive|archives)$/;
  return 'data'    if $base =~ /^(?:data|incoming|uploads|upload|spool|state|quarantine)$/;
  return 'runtime' if $base =~ /^(?:tmp|temp|cache|run|log|logs)$/;
  return '';
}

sub _gu_scan_preflight_candidate {
  my ($rel, $repo) = @_;
  my $base = basename($rel // '');
  my $lc = lc($base);
  my ($kind, $argv, $label);
  if ($lc =~ /\.pl$/) {
    $kind = 'perl_syntax';
    $argv = ['/usr/bin/perl', '-c', "{release}/$rel"];
    $label = "Perl-Syntax: $rel";
  } elsif ($lc =~ /\.php$/) {
    $kind = 'php_syntax';
    $argv = ['/usr/bin/php', '-l', "{release}/$rel"];
    $label = "PHP-Syntax: $rel";
  } elsif ($lc =~ /\.sh$/) {
    $kind = 'shell_syntax';
    $argv = ['/usr/bin/bash', '-n', "{release}/$rel"];
    $label = "Shell-Syntax: $rel";
  } else {
    return undef;
  }
  my $score = 0;
  $score += 40 if $rel !~ m{/};
  my $repo_norm = lc($repo // ''); $repo_norm =~ s/[^a-z0-9]+//g;
  my $file_norm = lc($base); $file_norm =~ s/\.[^.]+$//; $file_norm =~ s/[^a-z0-9]+//g;
  $score += 100 if length($repo_norm) && $repo_norm eq $file_norm;
  $score += 25 if $lc =~ /(?:agent|service|daemon)/;
  return {type=>$kind, path=>$rel, label=>$label, argv=>$argv, cwd=>'{release}', timeout=>30, score=>$score};
}

sub _gu_scan_service_install_ini {
  my ($workspace) = @_;
  my $file = "$workspace/service-install.ini";
  return {} unless -f $file && !-l $file;
  my @st = stat($file);
  return {} unless @st && ($st[7] // 0) <= 262_144;

  open my $fh, '<:raw', $file or return {};
  my (%ini, $section);
  while (my $line = <$fh>) {
    $line =~ s/\r?\n\z//;
    $line =~ s/^\s+|\s+$//g;
    next if $line eq '' || $line =~ /^[#;]/;
    if ($line =~ /^\[([^\]]+)\]$/) { $section = lc($1); next; }
    next unless defined $section && $line =~ /^([A-Za-z0-9_.-]+)\s*=\s*(.*)$/;
    my ($key, $value) = (lc($1), $2);
    $value =~ s/^\s+|\s+$//g;
    $ini{$section}{$key} = $value;
  }
  close $fh;

  my $app_dir = $ini{application}{app_dir} // '';
  my $unit = $ini{service}{unit} // '';
  return {} unless $app_dir =~ m{^/} && $app_dir !~ /\0/ && $app_dir !~ m{(?:^|/)\.\.(?:/|$)};
  return {} if length($unit) && $unit !~ /^[A-Za-z0-9_.\@:-]+\.service$/;

  my $expand = sub {
    my ($value) = @_;
    $value //= '';
    $value =~ s/\$\{APP_DIR\}/$app_dir/g;
    $value =~ s/\$\{UNIT\}/$unit/g;
    return $value;
  };

  my %paths;
  for my $sec (keys %ini) {
    next unless $sec =~ /^(?:directory|file):/;
    my $abs = $expand->($ini{$sec}{path} // '');
    next unless $abs =~ m{^/} && index($abs, "$app_dir/") == 0;
    my $rel = substr($abs, length($app_dir) + 1);
    next unless length($rel);
    eval { $rel = _gu_validate_relpath($rel); 1 } or next;
    my %meta;
    for my $key (qw(owner group mode required)) {
      next unless exists $ini{$sec}{$key};
      my $value = $expand->($ini{$sec}{$key});
      if ($key eq 'required') {
        $meta{$key} = $value =~ /^(?:1|true|yes|on)$/i ? true() : false();
      } elsif ($key eq 'mode' && $value =~ /^0?[0-7]{3,4}$/) {
        my $mode = oct($value);
        # Preserve-Metadaten bleiben ohne Sonderbits validierbar. Ein optionaler
        # post_deploy-Installer setzt danach die endgueltigen setgid-Rechte.
        $meta{$key} = sprintf('%04o', $mode & 0777);
      } else {
        $meta{$key} = $value;
      }
    }
    $paths{$rel} = \%meta if %meta;
  }
  return {app_dir=>$app_dir, unit=>$unit, paths=>\%paths, file=>'service-install.ini'};
}

sub _gu_scan_post_deploy_candidate {
  my ($rel, $full) = @_;
  my $base = lc(basename($rel // ''));
  return undef unless $base eq '_install.sh' || $base eq 'install.sh';
  return undef if $rel =~ m{/};

  my @args;
  my $content = eval {
    open my $fh, '<:raw', $full or die $!;
    read($fh, my $buf, 262144);
    close $fh;
    $buf;
  };
  push @args, '--no-start' if defined($content) && $content =~ /--no-start/;
  my @st = stat($full);
  my $executable = @st && (($st[2] // 0) & 0111) ? true() : false();
  return {
    script=>$rel, args=>\@args, timeout=>120, run_on_rollback=>true(),
    label=>"Installationsskript nach Aktivierung: $rel" . (@args ? ' --no-start' : ''),
    executable=>$executable, selected=>$executable,
  };
}

sub _gu_repo_scan_execute {
  my ($owner, $repo, $branch) = @_;
  _gu_require_forgejo_ready();
  _gu_validate_owner_repo($owner, $repo);
  _gu_fail('Branch ungueltig') unless _gu_valid_branch($branch);

  my $prepared;
  my $result;
  eval {
    $prepared = _gu_prepare_workspace(owner=>$owner, repo=>$repo, branch=>$branch, base_branch=>'');
    _gu_fail("Branch nicht gefunden: $branch") unless $prepared->{branch_exists};
    my $workspace = $prepared->{workspace};
    _gu_assert_workspace_safe($workspace, 1);

    my (@files, @dirs, @preserve, @services, @preflight, @post_deploy, @warnings);
    my ($file_count, $dir_count, $bytes) = (0, 0, 0);
    my %persistent_roots;
    my %dir_file_count;

    find({
      no_chdir=>1,
      wanted=>sub {
        my $full = $File::Find::name;
        return if $full eq $workspace;
        my $rel = substr($full, length($workspace) + 1);
        if ($rel eq '.git' || $rel =~ m{^\.git/}) {
          $File::Find::prune = 1 if -d $full;
          return;
        }
        if (-l $full) {
          $rel = _gu_validate_relpath($rel);
          my $target = readlink($full);
          _gu_safe_relative_symlink($workspace, $full, $rel);
          my $size = length($target // '');
          $file_count++;
          $bytes += $size;
          _gu_fail("Repository enthaelt mehr als $git_upload_max_files Dateien") if $file_count > $git_upload_max_files;
          _gu_fail("Repository ist groesser als $git_upload_max_bytes Bytes") if $bytes > $git_upload_max_bytes;
          push @files, {path=>$rel,size=>$size,mode=>'0777',symlink=>true(),target=>$target} if @files < 1000;
          push @warnings, "Interner relativer Symlink erkannt: $rel -> $target";
          return;
        }
        $rel = _gu_validate_relpath($rel);
        if (-d $full) {
          $dir_count++;
          my $kind = _gu_scan_persistent_dir_kind($rel);
          if ($kind ne '') {
            my $covered = 0;
            for my $root (keys %persistent_roots) {
              if ($rel eq $root || index($rel, "$root/") == 0) { $covered = 1; last; }
            }
            if (!$covered) {
              $persistent_roots{$rel} = $kind;
              push @preserve, {
                path=>$rel, type=>'directory', kind=>$kind,
                reason=>($kind eq 'backup' ? 'Backup-/Archivverzeichnis erkannt' : $kind eq 'data' ? 'Daten-/Eingangsverzeichnis erkannt' : 'Laufzeitverzeichnis erkannt'),
                selected=>true(), policy=>'preserve_existing', required=>false(), owner=>'root', group=>'taskmgmt', mode=>'0770',
              };
            }
          }
          push @dirs, $rel if @dirs < 500;
          return;
        }
        _gu_fail("Nicht regulaerer Repository-Eintrag: $rel") unless -f $full;
        my @st = stat($full);
        my $size = $st[7] // 0;
        my $mode = sprintf('%04o', ($st[2] // 0) & 07777);
        $file_count++;
        $bytes += $size;
        _gu_fail("Repository enthaelt mehr als $git_upload_max_files Dateien") if $file_count > $git_upload_max_files;
        _gu_fail("Repository ist groesser als $git_upload_max_bytes Bytes") if $bytes > $git_upload_max_bytes;
        push @files, {path=>$rel,size=>$size,mode=>$mode,executable=>(($st[2] // 0) & 0111 ? true() : false())} if @files < 1000;
        push @warnings, _gu_secret_warnings($rel, $full);
        push @warnings, "Backup-Datei im Repository erkannt: $rel" if $rel =~ m{(?:^|/)(?:backup|backups)/}i && $rel =~ /\.bak(?:\.|$)/i;
        for my $root (keys %persistent_roots) {
          $dir_file_count{$root}++ if index($rel, "$root/") == 0;
        }
        if (_gu_scan_config_candidate($rel)) {
          push @preserve, {
            path=>$rel, type=>'file', kind=>'config', reason=>'Lokale Konfigurationsdatei erkannt',
            selected=>true(), policy=>'preserve_existing', required=>false(), owner=>'root', group=>'taskmgmt', mode=>($mode =~ /^0?\d{3}$/ ? $mode : '0640'),
          };
        }
        if ($rel =~ /(?:^|\/)([^\/]+\.service)(?:\.example)?$/i) {
          push @services, {path=>$rel, name=>$1};
        }
        my $candidate = _gu_scan_preflight_candidate($rel, $repo);
        push @preflight, $candidate if $candidate;
        my $post_candidate = _gu_scan_post_deploy_candidate($rel, $full);
        push @post_deploy, $post_candidate if $post_candidate;
      }
    }, $workspace);

    for my $root (sort keys %persistent_roots) {
      my $kind = $persistent_roots{$root};
      my $count = $dir_file_count{$root} // 0;
      push @warnings, "Laufzeitverzeichnis enthaelt $count Datei(en) im Repository: $root/" if $count > 0 && $kind eq 'runtime';
      push @warnings, "Backup-/Datenverzeichnis enthaelt $count Datei(en) im Repository: $root/" if $count > 0 && ($kind eq 'backup' || $kind eq 'data');
    }

    my $service_install = _gu_scan_service_install_ini($workspace);
    if (ref($service_install->{paths}) eq 'HASH') {
      for my $item (@preserve) {
        my $meta = $service_install->{paths}{$item->{path}};
        next unless ref($meta) eq 'HASH';
        for my $key (qw(owner group mode required)) {
          $item->{$key} = $meta->{$key} if exists $meta->{$key};
        }
        $item->{reason} .= ' · Rechte aus service-install.ini';
      }
    }

    @preserve = sort { $a->{path} cmp $b->{path} } @preserve;
    @services = sort { $a->{name} cmp $b->{name} } @services;
    @preflight = sort { ($b->{score}//0) <=> ($a->{score}//0) || $a->{path} cmp $b->{path} } @preflight;
    for my $i (0..$#preflight) { $preflight[$i]{selected} = $i == 0 ? true() : false(); delete $preflight[$i]{score}; }
    @post_deploy = sort { $a->{script} cmp $b->{script} } @post_deploy;
    if (@post_deploy) {
      for my $i (0..$#post_deploy) { $post_deploy[$i]{selected} = ($i == 0 && $post_deploy[$i]{executable}) ? true() : false(); }
      push @warnings, "Installationsskript erkannt. Es wird beim Repository-Scan nicht ausgefuehrt und erst nach ausdruecklicher Profiluebernahme aktiviert.";
      push @warnings, "Installationsskript ist im Repository nicht ausfuehrbar: $post_deploy[0]{script}" unless $post_deploy[0]{executable};
    }
    my %seen_warning;
    @warnings = grep { defined($_) && length($_) && !$seen_warning{$_}++ } @warnings;

    my $service = length($service_install->{unit} // '')
      ? $service_install->{unit}
      : (@services == 1 ? $services[0]{name} : '');
    my $target_name = lc($repo); $target_name =~ s/[^a-z0-9._-]+/-/g;
    $target_name =~ s/^-+|-+$//g;
    my $target = length($service_install->{app_dir} // '')
      ? $service_install->{app_dir}
      : "/opt/service/$target_name";
    my @selected_preserve = map {
      my %copy = %$_;
      delete @copy{qw(type kind reason selected)};
      \%copy;
    } grep { $_->{selected} } @preserve;

    $result = {
      ok=>true(),
      repository=>{
        owner=>$owner, name=>$repo, full_name=>"$owner/$repo",
        clone_url=>$prepared->{repository}{clone_url}, default_branch=>$prepared->{repository}{default_branch},
      },
      branch=>$branch,
      commit=>($prepared->{remote_head} // ''),
      summary=>{
        files=>$file_count, directories=>$dir_count, bytes=>$bytes,
        preserve_candidates=>scalar(@preserve), service_candidates=>scalar(@services), preflight_candidates=>scalar(@preflight), post_deploy_candidates=>scalar(@post_deploy), warnings=>scalar(@warnings),
      },
      preserve_candidates=>\@preserve,
      service_candidates=>\@services,
      preflight_candidates=>\@preflight,
      post_deploy_candidates=>\@post_deploy,
      warnings=>\@warnings,
      files=>\@files,
      directories=>\@dirs,
      service_install=>(length($service_install->{file} // '') ? {
        file=>$service_install->{file}, app_dir=>$service_install->{app_dir}, unit=>$service_install->{unit},
      } : undef),
      profile_template=>{
        repository=>$prepared->{repository}{clone_url}, branch=>$branch, target=>$target,
        owner=>'root', group=>'taskmgmt', (length($service) ? (service=>$service) : ()),
        preserve=>\@selected_preserve,
        (@preflight ? (preflight=>$preflight[0]{argv}) : ()),
        (@post_deploy && $post_deploy[0]{selected} ? (post_deploy=>{
          script=>$post_deploy[0]{script}, args=>$post_deploy[0]{args},
          timeout=>$post_deploy[0]{timeout}, run_on_rollback=>true(),
        }) : ()),
      },
    };
    1;
  } or do {
    my $err = $@;
    _gu_rm_workspace($prepared->{workspace}) if $prepared && $prepared->{workspace};
    die $err;
  };
  _gu_rm_workspace($prepared->{workspace}) if $prepared && $prepared->{workspace};
  return $result;
}

get '/git_upload/info' => sub {
  my $c = shift;
  my $token_ok = -f $git_upload_token_file && -r $git_upload_token_file && !-l $git_upload_token_file;
  $c->render(json=>{
    ok=>true(), enabled=>($git_upload_enabled ? true() : false()), valid=>($git_upload_valid ? true() : false()),
    degraded=>(($git_upload_enabled && (!$git_upload_valid || !$token_ok)) ? true() : false()),
    error=>(!$git_upload_valid ? $git_upload_error : (!$token_ok && $git_upload_enabled ? "Token-Datei fehlt: $git_upload_token_file" : '')),
    base_url=>$git_upload_base_url, workspace_root=>$git_upload_workspace_root,
    max_upload_bytes=>$git_upload_max_bytes, max_files=>$git_upload_max_files,
    stage_ttl_seconds=>$git_upload_ttl, allow_mirror=>($git_upload_allow_mirror ? true() : false()),
    allow_default_branch=>($git_upload_allow_default_branch ? true() : false()),
    allowed_owners=>$git_upload_allowed_owners, repository_create=>true(),
    zip_supported=>(-f $git_upload_unzip_bin && -x $git_upload_unzip_bin ? true() : false()),
  });
};

# Read-only Repository-Browser fuer den Git-Deploy-Profilassistenten.
# Dieser Pfad ist bewusst NICHT an git_upload.enabled gekoppelt. Ein Forgejo-
# Token mit Leserecht reicht; Commit/Push bleibt ausschliesslich unter
# /git_upload und verlangt _gu_require_ready().
get '/git_deploy/repositories' => sub {
  my $c = shift;
  my $force = ($c->param('refresh') // '') =~ /^(?:1|true)$/i ? 1 : 0;
  my $repos = eval { _gu_require_forgejo_ready(); _gu_repositories($force, 0) };
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
    sub { _gu_require_forgejo_ready(); return _gu_repo_scan_execute($owner, $repository, $branch); },
    sub {
      my ($sub, $err, $result) = @_;
      if ($err || ref($result) ne 'HASH') {
        return $c->render(json=>{ok=>false(),error=>_gu_error_message($err // 'Ungueltiges Scan-Ergebnis')},status=>400);
      }
      $c->render(json=>$result);
    }
  );
};

get '/git_deploy/repositories/:owner/:repository/branches' => sub {
  my $c = shift;
  my $data = eval { _gu_require_forgejo_ready(); _gu_branches($c->stash('owner'), $c->stash('repository')) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  $c->render(json=>{ok=>true(), %$data});
};


get '/git_deploy/repositories/:owner/:repository/tree' => sub {
  my $c=shift; my $r=eval { _gu_require_forgejo_ready(); _gu_repo_tree($c->stash('owner'),$c->stash('repository'),$c->param('branch')//'',$c->param('path')//'') };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@; $c->render(json=>$r);
};
get '/git_deploy/repositories/:owner/:repository/file' => sub {
  my $c=shift; my $r=eval { _gu_require_forgejo_ready(); _gu_repo_file($c->stash('owner'),$c->stash('repository'),$c->param('branch')//'',$c->param('path')//'') };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@; $c->render(json=>$r);
};
get '/git_deploy/repositories/:owner/:repository/commits' => sub {
  my $c=shift; my $r=eval { _gu_require_forgejo_ready(); _gu_repo_commits($c->stash('owner'),$c->stash('repository'),$c->param('branch')//'',$c->param('path')//'',$c->param('limit')//30) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@; $c->render(json=>$r);
};
get '/git_deploy/repositories/:owner/:repository/compare' => sub {
  my $c=shift; my $r=eval { _gu_require_forgejo_ready(); _gu_repo_compare($c->stash('owner'),$c->stash('repository'),$c->param('base')//'',$c->param('head')//'') };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@; $c->render(json=>$r);
};
get '/git_upload/repositories/:owner/:repository/tree' => sub {
  my $c=shift; my $r=eval { _gu_require_forgejo_ready(); _gu_repo_tree($c->stash('owner'),$c->stash('repository'),$c->param('branch')//'',$c->param('path')//'') };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@; $c->render(json=>$r);
};
get '/git_upload/repositories/:owner/:repository/file' => sub {
  my $c=shift; my $r=eval { _gu_require_forgejo_ready(); _gu_repo_file($c->stash('owner'),$c->stash('repository'),$c->param('branch')//'',$c->param('path')//'') };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@; $c->render(json=>$r);
};
get '/git_upload/repositories/:owner/:repository/commits' => sub {
  my $c=shift; my $r=eval { _gu_require_forgejo_ready(); _gu_repo_commits($c->stash('owner'),$c->stash('repository'),$c->param('branch')//'',$c->param('path')//'',$c->param('limit')//30) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@; $c->render(json=>$r);
};
get '/git_upload/repositories/:owner/:repository/compare' => sub {
  my $c=shift; my $r=eval { _gu_require_forgejo_ready(); _gu_repo_compare($c->stash('owner'),$c->stash('repository'),$c->param('base')//'',$c->param('head')//'') };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@; $c->render(json=>$r);
};

post '/git_upload/repositories/:owner/:repository/file' => sub {
  my $c=shift; my $payload=eval { _gu_json_body($c) }; return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  $payload->{owner}=$c->stash('owner'); $payload->{repository}=$c->stash('repository');
  my $r=eval { _gu_repo_update_file($payload) }; return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  $logger->info(sprintf('GIT_REPOSITORY_EDIT %s repo=%s/%s branch=%s path=%s actor=%s', _fmt_req($c), $payload->{owner}, $payload->{repository}, ($payload->{branch}//''), ($payload->{path}//''), ($c->req->headers->header('X-Deploy-Actor') // 'portal-user')));
  $c->render(json=>$r);
};

post '/git_upload/repositories/create' => sub {
  my $c = shift;
  my $payload = eval { _gu_json_body($c) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  my $result = eval { _gu_create_repository($payload) };
  if ($@) {
    my $msg = _gu_error_message($@);
    my $status = $msg =~ /existiert bereits/i ? 409 : ($msg =~ /HTTP 403|permission|Berechtigung/i ? 403 : 400);
    return $c->render(json=>{ok=>false(),error=>$msg},status=>$status);
  }
  my $repo = $result->{repository} || {};
  $logger->info(sprintf('GIT_REPOSITORY_CREATE %s repo=%s actor=%s', _fmt_req($c), ($repo->{full_name}//'?'), ($c->req->headers->header('X-Deploy-Actor') // 'portal-user')));
  $c->render(json=>$result,status=>201);
};

get '/git_upload/repositories' => sub {
  my $c = shift;
  my $force = ($c->param('refresh') // '') =~ /^(?:1|true)$/i ? 1 : 0;
  my $repos = eval { _gu_require_ready(); _gu_repositories($force, 1) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>503) if $@;
  $c->render(json=>{ok=>true(), repositories=>$repos});
};



get '/git_upload/repositories/:owner/:repository/scan' => sub {
  my $c = shift;
  my $owner = $c->stash('owner');
  my $repository = $c->stash('repository');
  my $branch = $c->param('branch') // '';
  $c->render_later;
  my $sp = Mojo::IOLoop::Subprocess->new;
  $sp->run(
    sub { _gu_require_ready(); return _gu_repo_scan_execute($owner, $repository, $branch); },
    sub {
      my ($sub, $err, $result) = @_;
      if ($err || ref($result) ne 'HASH') {
        return $c->render(json=>{ok=>false(),error=>_gu_error_message($err // 'Ungueltiges Scan-Ergebnis')},status=>400);
      }
      $logger->info(sprintf('GIT_REPOSITORY_SCAN %s repo=%s/%s branch=%s files=%d warnings=%d', _fmt_req($c), $owner, $repository, $branch, ($result->{summary}{files}//0), ($result->{summary}{warnings}//0)));
      $c->render(json=>$result);
    }
  );
};

get '/git_upload/repositories/:owner/:repository/branches' => sub {
  my $c = shift;
  my $data = eval { _gu_require_ready(); _gu_branches($c->stash('owner'), $c->stash('repository')) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  $c->render(json=>{ok=>true(), %$data});
};

post '/git_upload/stage' => sub {
  my $c = shift;
  my $meta = eval { _gu_stage_upload($c) };
  my $err = $@;
  if ($err) {
    my $status = _gu_error_message($err) =~ /zu gross|mehr als|Unvollstaendiger/i ? 413 : 400;
    return $c->render(json=>{ok=>false(),error=>_gu_error_message($err)},status=>$status);
  }
  $logger->info(sprintf('GIT_UPLOAD staged %s stage=%s files=%d bytes=%d actor=%s', _fmt_req($c), $meta->{stage_id}, $meta->{file_count}, $meta->{bytes}, $meta->{actor}));
  $c->render(json=>{ok=>true(), stage=>$meta});
};

post '/git_upload/preview' => sub {
  my $c = shift;
  my $payload = eval { _gu_json_body($c) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  $c->render_later;
  my $sp = Mojo::IOLoop::Subprocess->new;
  $sp->run(
    sub { return _gu_preview_execute($payload); },
    sub {
      my ($sub, $err, $result) = @_;
      if ($err || ref($result) ne 'HASH') {
        return $c->render(json=>{ok=>false(),error=>_gu_error_message($err // 'Ungueltiges Vorschau-Ergebnis')},status=>400);
      }
      $c->render(json=>$result);
    }
  );
};

post '/git_upload/push' => sub {
  my $c = shift;
  my $payload = eval { _gu_json_body($c) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  my $actor = $c->req->headers->header('X-Deploy-Actor') // ($payload->{requested_by} // 'portal-user');
  $logger->info(sprintf('GIT_UPLOAD push_begin %s repo=%s/%s branch=%s actor=%s', _fmt_req($c), ($payload->{owner}//''), ($payload->{repository}//''), ($payload->{branch}//''), $actor));
  $c->render_later;
  my $sp = Mojo::IOLoop::Subprocess->new;
  $sp->run(
    sub { return _gu_push_execute($payload, $actor); },
    sub {
      my ($sub, $err, $result) = @_;
      if ($err || ref($result) ne 'HASH') {
        my $message = _gu_error_message($err // 'Ungueltiges Push-Ergebnis');
        my $status = $message =~ /seit der Vorschau|bereits angelegt/i ? 409 : 400;
        $logger->error(sprintf('GIT_UPLOAD push_failed %s error=%s', _fmt_req($c), $message));
        return $c->render(json=>{ok=>false(),error=>$message},status=>$status);
      }
      $logger->info(sprintf('GIT_UPLOAD push_done %s repo=%s branch=%s commit=%s actor=%s', _fmt_req($c), ($result->{repository}//''), ($result->{branch}//''), ($result->{commit}//''), $actor));
      $c->render(json=>$result);
    }
  );
};

del '/git_upload/stage/:stage_id' => sub {
  my $c = shift;
  my $root = eval { _gu_stage_path($c->stash('stage_id')) };
  return $c->render(json=>{ok=>false(),error=>_gu_error_message($@)},status=>400) if $@;
  remove_tree($root) if -d $root && !-l $root;
  $c->render(json=>{ok=>true(), deleted=>$c->stash('stage_id')});
};

1;
