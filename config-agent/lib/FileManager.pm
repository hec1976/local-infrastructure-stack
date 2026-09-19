package main;
use strict;
use warnings;
use utf8;
use Mojo::JSON qw(true false);
use Cwd qw(realpath);
use File::Basename qw(dirname basename);
use File::Spec;
use POSIX qw(strftime);
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);

our ($global,$logger,$backupRoot,$git_profiles_cfg);
our (%cfgmap);
my $FM_MAX=1024*1024;

# File Manager: Lesen und Schreiben bewusst getrennt.
# Lesen darf standardmaessig das normale Host-Dateisystem traversieren; virtuelle
# Kernel-/Runtime-Dateisysteme und harte Secret-Pfade bleiben ausgeschlossen.
# Schreiben ist auf administrative Konfigurations-/Applikationsbaeume begrenzt.
sub _fm_read_roots {
  my $r=$global->{file_manager_read_roots};
  $r=$global->{file_manager_roots} unless ref($r) eq 'ARRAY' && @$r;
  $r=['/'] unless ref($r) eq 'ARRAY' && @$r;
  my @o; for my $x(@$r){next unless defined $x && $x =~ m{\A/[A-Za-z0-9_./-]*\z}; $x =~ s{/+$}{} unless $x eq '/'; push @o,$x unless _is_hard_protected_path($x);} return \@o;
}
sub _fm_write_roots {
  my $r=$global->{file_manager_write_roots};
  $r=$global->{file_manager_roots} unless ref($r) eq 'ARRAY' && @$r;
  $r=['/etc','/opt','/srv','/var/lib','/var/log','/usr/local'] unless ref($r) eq 'ARRAY' && @$r;
  my @o; for my $x(@$r){next unless defined $x && $x =~ m{\A/[A-Za-z0-9_./-]+\z}; $x =~ s{/+$}{}; push @o,$x unless _is_hard_protected_path($x);} return \@o;
}
sub _fm_roots { return _fm_read_roots(); } # Rueckwaertskompatibel fuer Portal/API

my @FM_RUNTIME_BLOCK = qw(/proc /sys /dev /run);
# Zusaetzlicher File-Manager-Schutz fuer Credentials/Schluessel. Diese Pfade
# bleiben fuer spezialisierte Agent-Module erreichbar, werden aber nie ueber
# den generischen Datei-Manager exponiert.
sub _fm_sensitive_path {
  my($p)=@_; $p=_fm_clean($p);
  return 1 if _is_hard_protected_path($p);
  return 1 if $p eq '/var/lib/service/config-agent/secrets' || index($p,'/var/lib/service/config-agent/secrets/')==0;
  return 1 if $p =~ m{\A/(?:root|home/[^/]+)/(?:\.ssh|\.gnupg)(?:/|\z)};
  return 1 if $p =~ m{(?:^|/)(?:id_rsa|id_ed25519|id_ecdsa|authorized_keys|known_hosts)(?:\z|/)};
  return 1 if $p =~ m{(?:^|/)[^/]*\.(?:key|p12|pfx)\z}i;
  return 1 if $p =~ m{(?:^|/)(?:config-manager\.env|[^/]+\.env)\z}i;
  return 0;
}
sub _fm_runtime_blocked {
  my($p)=@_;
  for my $r(@FM_RUNTIME_BLOCK){ return 1 if $p eq $r || index($p,$r.'/')==0; }
  return 0;
}
sub _fm_inside_roots {
  my($p,$roots)=@_;
  for my $r(@$roots){ return 1 if $r eq '/' || $p eq $r || index($p,$r.'/')==0; }
  return 0;
}
sub _fm_clean {
  my($p)=@_; die 'Pfad fehlt' unless defined $p && length $p; die 'Pfad muss absolut sein' unless $p =~ m{\A/}; die 'Ungueltige Pfadzeichen' if $p =~ /[\x00\r\n]/; die 'Pfad-Traversal verweigert' if $p =~ m{(?:^|/)\.\.(?:/|$)}; $p =~ s{//+}{/}g; $p =~ s{/$}{} if length($p)>1; return $p;
}
sub _fm_allowed_read {
  my($p)=@_; $p=_fm_clean($p); die "Geschuetzter/verborgener Systempfad" if _fm_sensitive_path($p); die "Virtuelles/Runtime-Dateisystem ist im File Manager gesperrt" if _fm_runtime_blocked($p);
  return 1 if _fm_inside_roots($p,_fm_read_roots()); die "Pfad liegt ausserhalb der File-Manager-Lesebereiche";
}
sub _fm_allowed_write {
  my($p)=@_; $p=_fm_clean($p); die "Geschuetzter/verborgener Systempfad" if _fm_sensitive_path($p); die "Virtuelles/Runtime-Dateisystem ist im File Manager gesperrt" if _fm_runtime_blocked($p);
  return 1 if _fm_inside_roots($p,_fm_write_roots()); die "Pfad liegt ausserhalb der File-Manager-Schreibbereiche";
}
sub _fm_no_symlink_path {
  my($p,$mode)=@_; $mode//= 'read'; $mode eq 'write' ? _fm_allowed_write($p) : _fm_allowed_read($p); my @parts=File::Spec->splitdir($p); my $cur=''; for my $part(@parts){next if $part eq ''; $cur.='/'.$part; my @st=lstat($cur); next unless @st; die "Symlink im Pfad verweigert: $cur" if -l _; } return 1;
}


sub _fm_ownership {
  my($p)=@_; $p=_fm_clean($p);
  for my $id(sort keys %cfgmap){
    my $c=$cfgmap{$id}; next unless ref($c) eq 'HASH';
    my $cp=$c->{path}//''; next unless $cp;
    return {managed=>true(),owner=>'managed-config',id=>$id,source=>'Managed Configs',message=>"Datei wird durch Managed Config '$id' verwaltet."} if $p eq $cp;
  }
  if ($p eq '/etc/systemd/system' || index($p,'/etc/systemd/system/')==0) {
    return {managed=>true(),owner=>'systemd',id=>'systemd-runtime',source=>'systemd',message=>'Systemd-Units sind systemkritisch. Direkte Aenderungen erfordern einen Expert-Override; fuer paketierte Units ist Package Management zu bevorzugen.'};
  }
  my %baseline=(
    '/etc/monit.d/cm-baseline.monitrc'=>'Client Baseline / Monit',
    '/etc/monit/conf-enabled/cm-baseline.monitrc'=>'Client Baseline / Monit',
    '/etc/alloy/config.alloy'=>'Client Baseline / Grafana Alloy',
  );
  return {managed=>true(),owner=>'baseline',id=>$baseline{$p},source=>'Client Baseline',message=>"Datei gehoert zur Management-Baseline und sollte dort geaendert werden."} if exists $baseline{$p};
  if(ref($git_profiles_cfg) eq 'HASH'){
    for my $id(sort keys %$git_profiles_cfg){
      my $g=$git_profiles_cfg->{$id}; next unless ref($g) eq 'HASH';
      my $tp=$g->{target_path}//''; $tp =~ s{/+$}{};
      if($tp && ($p eq $tp || index($p,$tp.'/')==0)){
        return {managed=>true(),owner=>'git-deploy',id=>$id,source=>'Git Deploy',message=>"Pfad wird durch Git-Deploy-Profil '$id' verwaltet; direkte Aenderungen koennen ueberschrieben werden."};
      }
    }
  }
  return {managed=>false(),owner=>'manual',source=>'Datei Manager',message=>'Keine bekannte zentrale Ownership erkannt.'};
}
sub _fm_require_override {
  my($p,$override)=@_; my $o=_fm_ownership($p); return $o unless $o->{managed};
  die $o->{message}." Direkter Expert-Override ist erforderlich." unless $override;
  return $o;
}
sub _fm_backup {
  my($p,$reason)=@_; return '' unless -f $p && !-l $p;
  my $root=($backupRoot && $backupRoot =~ m{\A/}) ? "$backupRoot/file-manager" : '/opt/service/config-agent/backup/file-manager';
  make_path($root,{mode=>0700}) unless -d $root;
  my $stamp=strftime('%Y%m%d_%H%M%S',localtime); my $base=basename($p); $base =~ s/[^A-Za-z0-9_.-]/_/g;
  my $dst="$root/${stamp}-".substr(sha256_hex($p),0,12)."-$base";
  open my $in,'<:raw',$p or die "Backup-Quelle nicht lesbar: $!"; open my $out,'>:raw',$dst or die "Backup kann nicht angelegt werden: $!";
  while(read($in,my $buf,65536)){print {$out}$buf or die "Backup schreiben fehlgeschlagen: $!"} close $in; close $out; chmod 0600,$dst;
  return $dst;
}
sub _fm_list {
  my($dir)=@_; $dir=_fm_clean($dir); _fm_no_symlink_path($dir); die 'Verzeichnis existiert nicht' unless -d $dir; opendir my $dh,$dir or die "Verzeichnis nicht lesbar: $!"; my @rows; my $hidden=0;
  for my $n(sort readdir $dh){next if $n eq '.'||$n eq '..'; my $p=($dir eq '/' ? '' : $dir)."/$n"; $p =~ s{//+}{/}g;
    if (_fm_sensitive_path($p) || _fm_runtime_blocked($p)) { $hidden++; next; }
    my @st=lstat($p); next unless @st; my $own=(-f _ && !-l _)?_fm_ownership($p):{managed=>false(),owner=>'manual'}; push @rows,{name=>$n,path=>$p,type=>(-l _?'symlink':-d _?'dir':-f _?'file':'other'),size=>$st[7],mode=>sprintf('%04o',$st[2]&07777),mtime=>$st[9],ownership=>$own};} closedir $dh; return {ok=>true(),path=>$dir,roots=>_fm_roots(),entries=>\@rows,hidden_protected=>$hidden};
}
sub _fm_read {
  my($p)=@_; $p=_fm_clean($p); _fm_no_symlink_path($p); die 'Nur regulaere Dateien koennen gelesen werden' unless -f $p && !-l $p; my $s=-s $p; die 'Datei ist zu gross' if $s>$FM_MAX; open my $fh,'<:raw',$p or die "Datei nicht lesbar: $!"; local $/; my $b=<$fh>//''; close $fh; return {ok=>true(),path=>$p,content=>$b,size=>$s,mode=>sprintf('%04o',(stat($p))[2]&07777),ownership=>_fm_ownership($p)};
}
sub _fm_write {
  my($p,$content,$mode,$override)=@_; $p=_fm_clean($p); _fm_no_symlink_path($p,'write'); _fm_require_override($p,$override); die 'Inhalt zu gross' if length($content)>$FM_MAX; my $parent=dirname($p); die 'Zielverzeichnis existiert nicht' unless -d $parent; die 'Zieldatei ist Symlink' if -l $p;
  my $backup=(-f $p)?_fm_backup($p,'write'):'';
  safe_write_file($p,$content,1); my $m=defined($mode)&&$mode =~ /\A0?[0-7]{3,4}\z/?oct($mode):0640; chmod $m,$p or die "chmod fehlgeschlagen: $!"; return {ok=>true(),path=>$p,mode=>sprintf('%04o',$m),backup=>$backup};
}
sub _fm_delete { my($p,$override)=@_; $p=_fm_clean($p); _fm_no_symlink_path($p,'write'); _fm_require_override($p,$override); die 'Nur regulaere Dateien duerfen geloescht werden' unless -f $p && !-l $p; my $backup=_fm_backup($p,'delete'); unlink $p or die "Loeschen fehlgeschlagen: $!"; return {ok=>true(),path=>$p,backup=>$backup}; }
sub _fm_rename { my($src,$dst,$override)=@_; $src=_fm_clean($src);$dst=_fm_clean($dst);_fm_no_symlink_path($src,'write');_fm_no_symlink_path($dst,'write');_fm_require_override($src,$override);_fm_require_override($dst,$override);die 'Quelle muss regulaere Datei sein' unless -f $src&&! -l $src;die 'Zieldatei existiert bereits' if -e $dst;die 'Zielverzeichnis fehlt' unless -d dirname($dst);rename $src,$dst or die "Umbenennen fehlgeschlagen: $!";return {ok=>true(),path=>$dst}; }

get '/files/roots' => sub { my $c=shift;$c->render(json=>{ok=>true(),roots=>_fm_read_roots(),read_roots=>_fm_read_roots(),write_roots=>_fm_write_roots(),runtime_blocked=>\@FM_RUNTIME_BLOCK}); };
get '/files/list' => sub { my $c=shift;my $r=eval{_fm_list($c->param('path')//'')};return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;$c->render(json=>$r); };
get '/files/read' => sub { my $c=shift;my $r=eval{_fm_read($c->param('path')//'')};return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;$c->render(json=>$r); };
post '/files/write' => sub { my $c=shift;my $in=$c->req->json;return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in)eq'HASH';my $r=eval{_fm_write($in->{path}//'',defined($in->{content})?$in->{content}:'',$in->{mode},$in->{override_managed}?1:0)};return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;$logger->info('FILE_WRITE path='.($in->{path}//'').' '._fmt_req($c));$c->render(json=>$r); };
post '/files/delete' => sub { my $c=shift;my $in=$c->req->json;return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in)eq'HASH';my $r=eval{_fm_delete($in->{path}//'',$in->{override_managed}?1:0)};return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;$logger->info('FILE_DELETE path='.($in->{path}//'').' '._fmt_req($c));$c->render(json=>$r); };
post '/files/rename' => sub { my $c=shift;my $in=$c->req->json;return $c->render(json=>{ok=>false(),error=>'JSON-Objekt erforderlich'},status=>400) unless ref($in)eq'HASH';my $r=eval{_fm_rename($in->{source}//'',$in->{target}//'',$in->{override_managed}?1:0)};return $c->render(json=>{ok=>false(),error=>"$@"},status=>400) if $@;$logger->info('FILE_RENAME source='.($in->{source}//'').' target='.($in->{target}//'').' '._fmt_req($c));$c->render(json=>$r); };
1;
