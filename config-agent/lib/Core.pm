package main;
use strict;
use warnings;
use utf8;

# Mojolicious::Lite wird absichtlich nur in config-agent.pl geladen.
# Dieses Modul laeuft in package main und registriert seine Routen
# in derselben bereits initialisierten Lite-App.

use strict;
use warnings;
use utf8;

use Mojo::Log;
use Mojo::JSON qw(encode_json decode_json true false);
use Mojo::File qw(path);
use Mojo::URL;
use Mojo::Util qw(secure_compare);
use IO::Handle ();
use Time::Piece;
use Time::HiRes qw(time sleep);
use Fcntl qw(:DEFAULT :mode :flock O_RDONLY O_WRONLY O_APPEND O_CREAT O_NONBLOCK);
use File::Temp qw(tempfile); # bewusst behalten: Mojo::File::tempfile liefert kein
                              # nutzbares Filehandle, nur ein Mojo::File-Objekt
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use MIME::Base64 qw(encode_base64);
use Net::CIDR ();
use Digest::SHA qw(sha256_hex);
use Mojo::IOLoop::Subprocess;
use Text::ParseWords qw(shellwords);
use POSIX (); # fsync
use Errno qw(EINTR);

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

use constant {
  DEFAULT_LOCK_TIMEOUT_S => 3.0,
  DEFAULT_MAX_BACKUPS    => 10,
  DEFAULT_SCRIPT_TIMEOUT    => 60,
  MAX_SCRIPT_OUTPUT         => 65_536,
  DEFAULT_GIT_TIMEOUT       => 180,
  DEFAULT_GIT_KEEP_RELEASES => 5,
  DEFAULT_GIT_MAX_FILES     => 100_000,
  DEFAULT_GIT_MAX_BYTES     => 2_147_483_648,
};


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

# ---------------- Umask (grundlegend) ----------------
umask 0007;

$VERSION = '2.23.15';
$SYSTEMCTL       = '/usr/bin/systemctl';
$SYSTEMCTL_FLAGS = '';

# ==================================================
# Logging-Setup & Grundkonfiguration
# ==================================================
$Bin = app->home->to_string;
$globalfile = "$Bin/global.json";
$gitfile    = "$Bin/git_deploy.json";
$legacy_configs_file = "$Bin/configs.json";
die "global.json fehlt\n" unless -f $globalfile;

sub read_all {
  my ($path) = @_;
  open my $fh, '<:raw', $path or die "Kann $path nicht lesen: $!";
  local $/; my $data = <$fh>;
  close $fh;
  return $data;
}

$global = eval { decode_json(read_all($globalfile)) };
die "global.json ungültig: $@" if $@ || ref($global) ne 'HASH';

# Browser-Verzeichnis- und ZIP-Uploads koennen deutlich groesser als normale
# JSON-Requests sein. Die Grenze bleibt serverseitig konfiguriert und wird
# hart auf 2 GiB begrenzt.
my $configured_request_size = 16_777_216;
if (ref($global->{git_upload}) eq 'HASH' && defined($global->{git_upload}{max_upload_bytes}) && "$global->{git_upload}{max_upload_bytes}" =~ /^\d+$/) {
  $configured_request_size = 0 + $global->{git_upload}{max_upload_bytes} + 8_388_608;
}
$configured_request_size = 2_147_483_648 if $configured_request_size > 2_147_483_648;
$configured_request_size = 16_777_216 if $configured_request_size < 16_777_216;
app->max_request_size($configured_request_size) if app->can('max_request_size');

# Kanonischer Name ab 2.0.0. Ein abweichender absoluter Pfad kann optional in
# global.json über managed_configs_file definiert werden. configs.json bleibt
# nur als Start-/API-Kompatibilitätsfallback erhalten.
$managed_configs_file = $ENV{MANAGED_CONFIGS_FILE}
  // $global->{managed_configs_file}
  // "$Bin/managed_configs.json";
die "managed_configs_file muss absolut sein\n" unless $managed_configs_file =~ m{^/};
$using_legacy_configs = 0;
if (-f $managed_configs_file) {
  $configsfile = $managed_configs_file;
} elsif ($managed_configs_file eq "$Bin/managed_configs.json" && -f $legacy_configs_file) {
  $configsfile = $legacy_configs_file;
  $using_legacy_configs = 1;
} else {
  # Das Config-Datei-Modul startet im Degraded Mode und kann die Datei über
  # die Raw-Editor-Route neu anlegen. Git-Deploy und der Grunddienst bleiben
  # verfügbar.
  $configsfile = $managed_configs_file;
}

$SYSTEMCTL       = $global->{systemctl} if defined $global->{systemctl} && $global->{systemctl} ne '';
$SYSTEMCTL_FLAGS = exists $ENV{SYSTEMCTL_FLAGS} ? $ENV{SYSTEMCTL_FLAGS}
                  : (defined $global->{systemctl_flags} ? $global->{systemctl_flags} : '');

# App-Secret ist ein Credential und darf nicht in global.json liegen.
# Es wird ausschliesslich ueber die geschuetzte systemd EnvironmentFile geliefert.
my $app_secret = $ENV{CONFIG_AGENT_SECRET};
die "CONFIG_AGENT_SECRET fehlt in der Service-Environment\n"
  unless defined($app_secret) && length($app_secret) >= 32;
die "CONFIG_AGENT_SECRET enthaelt einen unsicheren Platzhalterwert\n"
  if $app_secret =~ /^(?:change[_-]?me|ein[_-]?langes|example|test)/i;
app->secrets([$app_secret]);

my $logfile = $global->{logfile} // "/var/log/service/config-manager.log";
my $logdir  = path($logfile)->dirname->to_string;
die "Log-Verzeichnis fehlt: $logdir\n" unless -d $logdir;
die "Logfile darf kein Symlink sein: $logfile\n" if -l $logfile;

$log_level = lc($ENV{LOG_LEVEL} // ($global->{log_level} // 'info'));
$log_level = 'info' unless $log_level =~ /^(?:trace|debug|info|warn|error|fatal)$/;

my $o_nofollow = eval { Fcntl::O_NOFOLLOW() } || 0;
sysopen(my $log_fh, $logfile, O_WRONLY | O_APPEND | O_CREAT | $o_nofollow, 0660)
  or die "Logfile kann nicht sicher geöffnet werden: $!\n";
chmod(0660, $logfile) or die "Logfile-Rechte konnten nicht gesetzt werden: $!\n";
binmode($log_fh, ':raw') or die "Logfile binmode fehlgeschlagen: $!\n";
$log_fh->autoflush(1);

$logger = Mojo::Log->new(handle => $log_fh, level => $log_level);
app->log($logger);
$logger->warn("LEGACY managed config file in use: $legacy_configs_file; rename to $managed_configs_file")
  if $using_legacy_configs;
$logger->error("MANAGED_CONFIG missing file=$configsfile; module starts degraded")
  unless -f $configsfile;

# ==================================================
# Security & Verzeichnisse
# ==================================================
# API-Authentisierung ist fuer den Agent immer aktiv. Der Token ist ein Credential
# und wird ausschliesslich aus der geschuetzten Service-Environment gelesen.
$api_token = $ENV{CONFIG_AGENT_API_TOKEN};
die "CONFIG_AGENT_API_TOKEN fehlt in der Service-Environment\n"
  unless defined($api_token) && length($api_token) >= 32;
die "CONFIG_AGENT_API_TOKEN enthaelt einen unsicheren Platzhalterwert\n"
  if $api_token =~ /^(?:change[_-]?me|ein[_-]?langer|example|test)/i;
$allowed_ips = $global->{allowed_ips};
$allowed_ips = [] unless ref($allowed_ips) eq 'ARRAY';

$tmpDir     = $global->{tmpDir}    // "$Bin/tmp";
$backupRoot = $global->{backupDir} // "$Bin/backup";
die "Backup-Verzeichnis fehlt: $backupRoot\n" unless -d $backupRoot;
die "Tmp-Verzeichnis fehlt: $tmpDir\n" unless -d $tmpDir;

$maxBackups = $global->{maxBackups} // DEFAULT_MAX_BACKUPS;
$backupRetentionDays = (defined($global->{backupRetentionDays}) && $global->{backupRetentionDays} =~ /^\d+$/) ? 0 + $global->{backupRetentionDays} : 90;
$minimumBackups = (defined($global->{minimumBackups}) && $global->{minimumBackups} =~ /^\d+$/) ? 0 + $global->{minimumBackups} : 10;
$minimumBackups = $maxBackups if $minimumBackups > $maxBackups;
$lockTimeoutS = (defined $global->{lock_timeout} && $global->{lock_timeout} =~ /^\d+(\.\d+)?$/)
  ? 0 + $global->{lock_timeout} : DEFAULT_LOCK_TIMEOUT_S;
$configs_lockfile = "$configsfile.lock";

$path_guard = lc($ENV{PATH_GUARD} // ($global->{path_guard} // 'off'));
$path_guard = 'off' unless $path_guard =~ /^(?:off|audit|enforce)$/;
$ALLOWED = [];
if (ref($global->{allowed_roots}) eq 'ARRAY') {
  for my $root (@{$global->{allowed_roots}}) {
    next unless defined $root && length $root;
    my $rr = eval { path($root)->realpath->to_string };
    next unless defined $rr && -d $rr;
    $rr =~ s{/+$}{} unless $rr eq '/';
    push @$ALLOWED, $rr;
  }
}

$apply_meta_enabled         = $global->{apply_meta}          // 0;
$auto_create_backup_subdirs = $global->{auto_create_backups} // 0;
$fsync_dir_enabled          = $global->{fsync_dir}           // 0;

# ==================================================
# Hilfsfunktionen (Security, FS, Ownership)
# ==================================================
# Harte Schutzliste fuer sicherheitskritische Systempfade.
# Diese Sperre gilt IMMER fuer generische File-API-/Datei-Manager-Aktionen,
# auch wenn path_guard=off gesetzt ist oder /etc als allowed_root freigegeben
# wurde. Git-Deploy-/Package-Hooks laufen bewusst als privilegierte Deployment-
# Ebene und werden separat ueber Profil, Repository und Capability autorisiert.
my @HARD_PROTECTED_PATHS = qw(
  /etc/shadow
  /etc/gshadow
  /etc/sudoers
  /etc/sudoers.d
  /etc/ssh
  /etc/pam.d
  /etc/security
  /etc/ssl/private
  /opt/service/env
  /opt/service/ssl
);

sub _guard_normalize_path {
  my ($p) = @_;
  return undef unless defined $p && length $p;

  # Existierende Ziele werden komplett kanonisiert. Bei neuen Dateien wird
  # der reale Parent aufgeloest, damit ../ und Symlink-Parents die Sperre
  # nicht umgehen koennen.
  my $rp = eval {
    if (-e $p || -l $p) {
      path($p)->realpath->to_string;
    } else {
      my $parent = path($p)->dirname->realpath->to_string;
      my $base   = path($p)->basename;
      "$parent/$base";
    }
  };
  return undef unless defined $rp && length $rp;
  $rp =~ s{/+}{/}g;
  $rp =~ s{/$}{} unless $rp eq '/';
  return $rp;
}

sub _matches_hard_protected_path {
  my ($candidate) = @_;
  return 0 unless defined $candidate && length $candidate;
  $candidate =~ s{/+}{/}g;
  $candidate =~ s{/$}{} unless $candidate eq '/';
  for my $protected (@HARD_PROTECTED_PATHS) {
    return 1 if $candidate eq $protected;
    return 1 if index($candidate, "$protected/") == 0;
  }
  return 0;
}

sub _is_declared_hard_protected_path {
  my ($p) = @_;

  # Registry-/Deklarationspruefung: Ein noch nicht existierendes Ziel ist nicht
  # automatisch ein geschuetzter Systempfad. Lexikal bekannte Schutzpfade
  # bleiben gesperrt; wenn eine sichere Kanonisierung moeglich ist, werden auch
  # Symlink-Aliase erkannt. Der Runtime-Guard bleibt weiter fail-closed.
  return 1 if _matches_hard_protected_path($p);
  my $rp = _guard_normalize_path($p);
  return 0 unless defined $rp;
  return _matches_hard_protected_path($rp);
}

sub _is_hard_protected_path {
  my ($p) = @_;

  # Runtime-Schreibzugriffe bleiben fail-closed: kann ein Ziel nicht sicher
  # kanonisiert werden, wird es nicht freigegeben.
  return 1 if _matches_hard_protected_path($p);

  my $rp = _guard_normalize_path($p);
  return 1 unless defined $rp;
  return _matches_hard_protected_path($rp);
}

sub _mode_str {
  my ($path) = @_;
  return undef unless -e $path;
  my $m = (stat($path))[2];
  return sprintf('%04o', S_IMODE($m));
}

sub _cur_umask {
  my $o = umask();
  umask($o); # restore
  return $o;
}

sub _fsync_dir {
  return unless $fsync_dir_enabled;
  my ($path) = @_;
  my $dir = path($path)->dirname->to_string;
  sysopen(my $dh, $dir, O_RDONLY) or return; # best effort
  POSIX::fsync(fileno($dh));
  close $dh;
}

sub _is_allowed_path {
  my ($p) = @_;

  # Sicherheitskritische Systempfade sind immer gesperrt, unabhaengig vom
  # konfigurierten path_guard oder allowed_roots.
  if (_is_hard_protected_path($p)) {
    $logger->warn("HARD-PATH-GUARD blockiert geschuetzten Pfad: $p") if $logger;
    return 0;
  }

  # Symlink am Ziel hart verbieten
  return 0 if -l $p;

  # Guard vollständig aus: Symlinks bleiben immer verboten, Hardlinks
  # werden aus Rueckwaertskompatibilitaet aber nicht zusaetzlich abgelehnt.
  return 1 if $path_guard eq 'off';

  # Hardlink-Schutz nur bei aktivem Guard.
  if (-e $p && !-d $p) {
    my $nlink = (stat($p))[3];
    return 0 if defined $nlink && $nlink > 1;
  }

  # Für nicht existierende Dateien: auf Elternverzeichnis prüfen
  my $rp = eval { -e $p ? path($p)->realpath->to_string : path($p)->dirname->realpath->to_string };
  return 0 unless defined $rp;

  # Keine Liste -> effektiv aus
  return 1 unless @$ALLOWED;

  for my $root (@$ALLOWED) {
    return 1 if $rp eq $root;
    return 1 if $root eq '/';
    return 1 if index($rp, "$root/") == 0;
  }

  if ($path_guard eq 'audit') {
    $logger->warn("PATH-GUARD audit: $rp liegt nicht unter allowed_roots");
    return 1;
  }
  return 0; # enforce
}

sub _name2uid { my ($n)=@_; return undef unless defined $n && length $n; return $n =~ /^\d+$/ ? 0+$n : scalar((getpwnam($n))[2]); }
sub _name2gid { my ($n)=@_; return undef unless defined $n && length $n; return $n =~ /^\d+$/ ? 0+$n : scalar((getgrnam($n))[2]); }

sub _apply_meta {
  my ($e,$path) = @_;

  # Auto-enable, wenn user/group/mode gesetzt
  my $auto_wanted = (defined $e->{user} || defined $e->{group} || defined $e->{mode}) ? 1 : 0;
  my $enabled = defined $e->{apply_meta} ? $e->{apply_meta} : ($apply_meta_enabled || $auto_wanted);

  unless ($enabled) { $logger->info("APPLY_META skipped (disabled) path=$path"); return; }

  die "Pfad nicht erlaubt" unless _is_allowed_path($path);
  die "refuse symlink" if -l $path;

  my $uid = _name2uid($e->{user});
  my $gid = _name2gid($e->{group});

  my $mode;
  if (defined $e->{mode}) {
    my $m = "$e->{mode}";
    $m =~ s/^0+//;                       # 0640 -> 640
    die "ungültiger mode" unless $m =~ /^[0-7]{3,4}$/;
    $mode = oct($m);
  }

  if (defined $uid || defined $gid) {
    my $u = defined($uid) ? $uid : -1;
    my $g = defined($gid) ? $gid : -1;
    chown($u, $g, $path) or die "chown failed: $!";
  }
  chmod($mode, $path) if defined $mode;
}

# Backup-Unterordner je Config (kollisionsfrei)
sub _backup_dir_for {
  my ($name) = @_;
  my $sub = $name;
  $sub =~ s{[^A-Za-z0-9._-]+}{_}g;
  return "$backupRoot/$sub";
}

sub _with_configs_lock {
  my ($lock_mode, $code) = @_;
  die "interner Fehler: Lock-Modus fehlt" unless defined $lock_mode;
  die "interner Fehler: Callback fehlt" unless ref($code) eq 'CODE';

  sysopen(my $lfh, $configs_lockfile, O_RDWR | O_CREAT, 0660)
    or die "Kann Lockdatei $configs_lockfile nicht öffnen: $!";
  chmod(0660, $configs_lockfile)
    or die "Kann Rechte der Lockdatei $configs_lockfile nicht setzen: $!";
  my $deadline = time() + $lockTimeoutS;
  my $locked = 0;
  while (time() < $deadline) {
    if (flock($lfh, $lock_mode | LOCK_NB)) {
      $locked = 1;
      last;
    }
    sleep 0.05;
  }
  die sprintf("flock(%s) Timeout nach %.1fs", $configs_lockfile, $lockTimeoutS)
    unless $locked;

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

  flock($lfh, LOCK_UN);
  close $lfh;
  die $err unless $ok;
  return $wantarray ? @ret : defined($wantarray) ? $ret : undef;
}

# Serialisiert Save/Restore auf denselben Zielpfad, damit Lesen des alten
# Inhalts (im Rahmen von Backup+Schreiben), Backup-Erstellung und der
# eigentliche Schreibvorgang nicht mit einem gleichzeitigen zweiten Request
# auf dieselbe Config verschraenkt werden koennen. Eigene Lockdatei pro
# Zielpfad (SHA256-Hash des absoluten Pfads), damit ein langsamer Schreib-
# vorgang auf Config A niemals einen Request auf Config B blockiert.
sub _with_config_file_lock {
  my ($target_path, $code) = @_;
  die "interner Fehler: Zielpfad fehlt" unless defined $target_path && length $target_path;
  die "interner Fehler: Callback fehlt" unless ref($code) eq 'CODE';

  my $lockfile = "$tmpDir/config-manager-" . sha256_hex($target_path) . ".lock";
  sysopen(my $lfh, $lockfile, O_RDWR | O_CREAT, 0660)
    or die "Kann Lockdatei $lockfile nicht öffnen: $!";
  chmod(0660, $lockfile)
    or die "Kann Rechte der Lockdatei $lockfile nicht setzen: $!";
  my $deadline = time() + $lockTimeoutS;
  my $locked = 0;
  while (time() < $deadline) {
    if (flock($lfh, LOCK_EX | LOCK_NB)) {
      $locked = 1;
      last;
    }
    sleep 0.05;
  }
  die sprintf("flock(%s) Timeout nach %.1fs (Ziel: %s)", $lockfile, $lockTimeoutS, $target_path)
    unless $locked;

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

  flock($lfh, LOCK_UN);
  close $lfh;
  die $err unless $ok;
  return $wantarray ? @ret : defined($wantarray) ? $ret : undef;
}

sub _ensure_backup_dir {
  my ($e) = @_;
  my $bdir = $e->{backup_dir};
  if (!-d $bdir) {
    if ($auto_create_backup_subdirs) {
      mkdir $bdir or die "Backup-Verzeichnis konnte nicht angelegt werden: $!";
    } else {
      die "Backup-Verzeichnis fehlt: $bdir";
    }
  }
  return $bdir;
}

sub _backup_timestamp {
  # Time::HiRes::time() ist bereits importiert (siehe use-Zeile oben),
  # liefert Sekunden mit Nachkommaanteil -> Millisekunden-Auflösung.
  my $now = time();
  my $ts  = localtime(int($now))->strftime('%Y%m%d_%H%M%S');
  my $ms  = sprintf('%03d', int(($now - int($now)) * 1000));
  return "${ts}_${ms}";
}

sub _create_current_backup {
  my ($e, $path, $reason) = @_;
  return undef unless -f $path;

  my $bdir = _ensure_backup_dir($e);
  my $base = path($path)->basename;

  my $bfile;
  my $attempts = 0;
  while (1) {
    my $ts = _backup_timestamp();
    my $candidate = "$bdir/$base.bak.$ts";
    if (!-e $candidate) { $bfile = $candidate; last; }
    die "Backup-Datei existiert bereits: $candidate (mehrfach kollidiert)"
      if ++$attempts >= 5;
    Time::HiRes::sleep(0.001);
  }

  path($path)->copy_to($bfile);
  $logger->info(uc($reason // 'backup')." backup $bfile");

  _rotate_backup_files($bdir, $base);
  return $bfile;
}

# Einheitliche Rotation fuer alle JSON-/Config-Backups.
# 1. Die neuesten minimumBackups bleiben immer erhalten.
# 2. Danach werden Backups entfernt, die aelter als backupRetentionDays sind.
# 3. Abschliessend wird auf maxBackups begrenzt.
# Loeschfehler werden protokolliert, duerfen aber den erfolgreichen Save nicht
# nachtraeglich fehlschlagen lassen.
sub _rotate_backup_files {
  my ($dir, $base) = @_;
  return unless defined($dir) && length($dir) && -d $dir;
  return unless defined($base) && length($base);

  my @files = grep { defined($_) && -f $_ && !-l $_ }
              glob("$dir/$base.bak.*");
  @files = sort {
    ((stat($b))[9] // 0) <=> ((stat($a))[9] // 0) || $b cmp $a
  } @files;

  my $min_keep = $minimumBackups // 0;
  my $max_keep = $maxBackups // 0;
  my $days     = $backupRetentionDays // 0;
  $min_keep = 0 if $min_keep < 0;
  $max_keep = 0 if $max_keep < 0;
  $min_keep = $max_keep if $max_keep > 0 && $min_keep > $max_keep;

  my %protected = map { $files[$_] => 1 }
                  grep { $_ <= $#files } (0 .. ($min_keep ? $min_keep - 1 : -1));

  if ($days > 0) {
    my $cutoff = time() - ($days * 86400);
    for my $file (@files) {
      next if $protected{$file};
      my $mtime = (stat($file))[9] // 0;
      next unless $mtime > 0 && $mtime < $cutoff;
      unlink($file) or $logger->warn("BACKUP_ROTATE age unlink_failed file=$file error=$!");
    }
  }

  @files = grep { -f $_ && !-l $_ } @files;
  @files = sort {
    ((stat($b))[9] // 0) <=> ((stat($a))[9] // 0) || $b cmp $a
  } @files;

  if ($max_keep > 0 && @files > $max_keep) {
    for my $idx ($max_keep .. $#files) {
      my $file = $files[$idx];
      unlink($file) or $logger->warn("BACKUP_ROTATE count unlink_failed file=$file error=$!");
    }
  }
}

# ==================================================
# Request-Helfer & Access-Control
# ==================================================
sub _req_meta {
  my ($c) = @_;
  return {
    req_id => $c->stash('req_id') // '',
    ip     => $c->stash('client_ip') // '',
    method => $c->req->method // '',
    path   => $c->req->url->path->to_string // '',
    ua     => $c->req->headers->user_agent // '',
  };
}

sub _fmt_req {
  my ($c) = @_;
  my $m = _req_meta($c);
  return sprintf('req_id=%s ip=%s %s %s', $m->{req_id}, $m->{ip}, $m->{method}, $m->{path});
}

# Liest den rohen Request-Body und gibt bei Ueberschreitung von max_message_size
# (Mojolicious-Default 16 MiB) ein deutliches Fehlersignal zurueck, statt den
# Body still gekuerzt weiterzuverarbeiten. Mojolicious selbst setzt in diesem
# Fall req->error/is_limit_exceeded, meldet aber keinen HTTP-Fehler von sich aus,
# solange die Anwendung den Body trotzdem liest.
sub _read_body_or_die {
  my ($c) = @_;
  my $body = $c->req->body // '';
  my $limit_exceeded = $c->req->can('is_limit_exceeded') && $c->req->is_limit_exceeded;
  my $err = $c->req->error;
  if ($limit_exceeded || ($err && ($err->{message} // '') =~ /size exceeded/i)) {
    die bless({ message => 'REQUEST_TOO_LARGE' }, 'RequestTooLarge');
  }
  return $body;
}


# Capability Scopes fuer den Agent-Token. Legacy-Installationen ohne
# CONFIG_AGENT_TOKEN_SCOPES bleiben kompatibel ('*'). Enrollment setzt
# explizit die benoetigten Rechte. Das Token bleibt host-spezifisch.
my $scope_raw = $ENV{CONFIG_AGENT_TOKEN_SCOPES} // '*';
my %TOKEN_SCOPES = map { $_ => 1 } grep { length } map { s/^\s+|\s+$//gr } split /,/, $scope_raw;
sub _required_scope {
  my($method,$path)=@_; $method=uc($method//'GET'); $path//='/';
  return 'status.read' if $method eq 'GET' && ($path eq '/' || $path =~ m{\A/(?:monit/status|baseline/info|packages/status|services/status)});
  return 'file.read' if $method eq 'GET' && $path =~ m{\A/files/};
  return 'file.manage' if $path =~ m{\A/files/};
  return 'baseline.manage' if $path =~ m{\A/baseline/};
  return 'package.manage' if $path =~ m{\A/(?:packages|package)/};
  return 'security.manage' if $path =~ m{\A/(?:firewall|fail2ban|modsecurity)/};
  return 'git.deploy' if $path =~ m{\A/(?:git|deploy)/};
  return 'service.control' if $path =~ m{\A/(?:actions|service)/};
  return $method eq 'GET' ? 'config.read' : 'config.write';
}
sub _scope_allowed {
  my($need)=@_; return 1 if $TOKEN_SCOPES{'*'} || $TOKEN_SCOPES{$need};
  return 1 if $need eq 'file.read' && $TOKEN_SCOPES{'file.manage'};
  return 1 if $need eq 'config.read' && $TOKEN_SCOPES{'config.write'};
  return 0;
}

# Trusted Proxies (optional)
my %TRUSTED = map { $_ => 1 } (
  ref($global->{trusted_proxies}) eq 'ARRAY' ? @{$global->{trusted_proxies}} : ()
);

sub _client_ip {
  my ($c) = @_;
  my $rip = $c->tx->remote_address // '';
  if ($TRUSTED{$rip}) {
    my $xff = $c->req->headers->header('X-Forwarded-For') // '';
    if ($xff) {
      my @ips = map { s/^\s+|\s+$//gr } split /,/, $xff; # erste ist original client
      return $ips[0] // $rip;
    }
  }
  return $rip;
}

# CORS: optional erlaubte Origins
# Rueckwaertskompatibel: Fehlt der Eintrag, bleibt das Verhalten der
# Originalversion erhalten und jede Origin ist erlaubt.
my $cors_allow_any_origin = exists $global->{cors_allow_any_origin}
  ? ($global->{cors_allow_any_origin} ? 1 : 0)
  : 0;
my $origin_list = ref($global->{allowed_origins}) eq 'ARRAY' ? $global->{allowed_origins}
                : ref($global->{allow_origins})   eq 'ARRAY' ? $global->{allow_origins}
                : [];
my %ALLOW_ORIGIN = map { $_ => 1 } grep { defined $_ && length $_ } @$origin_list;

app->hook(before_dispatch => sub {
  my $c = shift;

  $c->stash(req_id => sprintf('%x-%x', int(time()*1000), $$));
  $c->stash(t0     => time());
  $c->stash(client_ip => _client_ip($c));

  my $origin = $c->req->headers->origin;
  if (defined $origin && length $origin) {
    if ($cors_allow_any_origin) {
      $c->res->headers->header('Access-Control-Allow-Origin' => '*');
    } elsif ($ALLOW_ORIGIN{$origin}) {
      $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
    } else {
      $c->res->headers->remove('Access-Control-Allow-Origin');
    }
  }
  $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, DELETE, OPTIONS');
  $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, X-API-Token, Authorization, X-Deploy-Actor');
  $c->res->headers->header('Access-Control-Max-Age'       => '86400');
  $c->res->headers->header('Vary'                         => 'Origin');
  $c->res->headers->header('X-Content-Type-Options'       => 'nosniff');
  $c->res->headers->header('Referrer-Policy'              => 'no-referrer');
  $c->res->headers->header('Cache-Control'                => 'no-store');

  my $method = $c->req->method // '';
  $logger->info(sprintf('REQ  %s', _fmt_req($c))) unless $method eq 'GET' || $method eq 'OPTIONS';
  return $c->render(text => '', status => 204) if $method eq 'OPTIONS';

  # IP-ACL
  if ($allowed_ips && @{$allowed_ips}) {
    my $rip = $c->stash('client_ip') // '';
    unless (Net::CIDR::cidrlookup($rip, @{$allowed_ips})) {
      $logger->warn(sprintf('ACCESS %s -> 403 Forbidden', _fmt_req($c)));
      return $c->render(status => 403, json => { ok=>0, error => 'Forbidden' });
    }
  }

  # Token-Auth (Header X-API-Token oder Bearer)
  if (defined $api_token && length $api_token) {
    my $hdr     = $c->req->headers->header('X-API-Token') // '';
    my $auth    = $c->req->headers->authorization // '';
    my $bearer  = $auth =~ /^Bearer\s+(.+)/i ? $1 : '';
    my $token   = $hdr || $bearer;
    unless (secure_compare($token, $api_token)) {
      $logger->warn(sprintf('ACCESS %s -> 401 Unauthorized', _fmt_req($c)));
      return $c->render(status => 401, json => { ok=>0, error => 'Unauthorized' });
    }
  }

  my $need=_required_scope($method,$c->req->url->path->to_string);
  unless (_scope_allowed($need)) {
    $logger->warn(sprintf('ACCESS %s -> 403 scope=%s', _fmt_req($c), $need));
    return $c->render(status=>403,json=>{ok=>0,error=>'Token scope verweigert',required_scope=>$need});
  }
});

app->hook(after_dispatch => sub {
  my $c = shift;
  my $t0 = $c->stash('t0') // time();
  my $dt = time() - $t0;
  my $code = $c->res->code // 200;
  my $bytes = $c->res->headers->content_length;
  $bytes = length($c->res->body // '') unless defined $bytes;
  my $method = $c->req->method // '';
  my $msg = sprintf('RESP %s status=%d time=%.3fs bytes=%d', _fmt_req($c), $code, $dt, $bytes);

  # Erfolgreiche GET-/OPTIONS-Polling-Aufrufe erzeugen bewusst keine Logflut.
  if ($method eq 'GET') {
    if ($code >= 500) {
      $logger->error($msg);
    } elsif ($code >= 400) {
      $logger->warn($msg);
    }
  } elsif ($method ne 'OPTIONS') {
    if ($code >= 500) {
      $logger->error($msg);
    } elsif ($code >= 400) {
      $logger->warn($msg);
    } else {
      $logger->info($msg);
    }
  }
});

# ==================================================
# I/O-Helfer (Atomic Write, Plain Fallback)
# ==================================================
sub write_atomic {
  my ($path, $bytes) = @_;
  my $dir = path($path)->dirname->to_string;
  my ($fh, $tmp);

  my $ok = eval {
    ($fh, $tmp) = tempfile('.tmp_XXXXXX', DIR => $dir, UNLINK => 0);
    binmode($fh, ':raw') or die "binmode failed: $!";
    print {$fh} $bytes or die "write failed: $!";
    $fh->flush() if $fh->can('flush');
    $fh->sync()  if $fh->can('sync');
    close $fh or die "close failed: $!";
    undef $fh;

    # Tempfile-Mode auf umask-basierten Mode setzen (z.B. 0660 bei umask 0007)
    my $mode = 0666 & ~_cur_umask();
    chmod $mode, $tmp or die "chmod($tmp) failed: $!";

    rename $tmp, $path or die "rename failed: $!";
    undef $tmp;
    _fsync_dir($path);
    1;
  };

  my $err = $@;
  close $fh if $fh;
  unlink $tmp if defined $tmp && -e $tmp;
  die $err unless $ok;
  return 'atomic';
}

sub safe_write_file {
  my ($path, $bytes, $atomic_required) = @_;

  # Defense in depth: Auch interne Aufrufer, die _is_allowed_path vergessen,
  # duerfen die hart geschuetzten Systempfade niemals schreiben.
  die "Schreiben auf geschuetzten Systempfad verweigert: $path"
    if _is_hard_protected_path($path);

  my $method = 'atomic';
  my $ok = eval { write_atomic($path, $bytes); 1 };
  if (!$ok) {
    my $atomic_error = $@;
    die $atomic_error if $atomic_required;

    $method = 'plain';
    open my $fh, '>:raw', $path or do {
      my $plain_error = "$!";
      $atomic_error =~ s/\s+$// if defined $atomic_error;
      die "plain open failed: $plain_error"
        . (defined($atomic_error) && length($atomic_error) ? " (atomic write zuvor fehlgeschlagen: $atomic_error)" : "");
    };
    print {$fh} $bytes or die "plain write failed: $!";
    $fh->flush() if $fh->can('flush');
    $fh->sync()  if $fh->can('sync');
    close $fh or die "plain close failed: $!";
    _fsync_dir($path);
  }
  return $method;
}


1;
