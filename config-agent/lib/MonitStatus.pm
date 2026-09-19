package main;
use strict;
use warnings;
use utf8;
use Mojo::JSON qw(true false);
use Mojo::UserAgent;
use MIME::Base64 qw(encode_base64);
use XML::LibXML;
use Time::HiRes qw(time);

our ($global, $logger);

sub _monit_text {
  my ($node, $xpath) = @_;
  return '' unless $node;
  my ($n) = $node->findnodes($xpath);
  return '' unless $n;
  my $v = $n->textContent // '';
  $v =~ s/^\s+|\s+$//g;
  return $v;
}

sub _monit_num {
  my ($node, $xpath) = @_;
  my $v = _monit_text($node, $xpath);
  return undef if $v eq '' || $v !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
  return 0 + $v;
}

sub _monit_type_name {
  my ($type) = @_;
  my %m = (
    0=>'filesystem', 1=>'directory', 2=>'file', 3=>'process', 4=>'host',
    5=>'system', 6=>'fifo', 7=>'program', 8=>'network'
  );
  return $m{$type} // 'unknown';
}

sub _monit_service_details {
  my ($n, $type) = @_;
  my %d;
  if ($type == 0) {
    $d{filesystem} = {
      block_percent => _monit_num($n, './block/percent'),
      block_usage   => _monit_num($n, './block/usage'),
      block_total   => _monit_num($n, './block/total'),
      inode_percent => _monit_num($n, './inode/percent'),
      inode_usage   => _monit_num($n, './inode/usage'),
      inode_total   => _monit_num($n, './inode/total'),
    };
  } elsif ($type == 3) {
    $d{process} = {
      pid => _monit_num($n, './pid'), ppid => _monit_num($n, './ppid'),
      uptime => _monit_num($n, './uptime'), threads => _monit_num($n, './threads'),
      children => _monit_num($n, './children'),
      cpu_percent => _monit_num($n, './cpu/percent'),
      cpu_percent_total => _monit_num($n, './cpu/percenttotal'),
      memory_percent => _monit_num($n, './memory/percent'),
      memory_percent_total => _monit_num($n, './memory/percenttotal'),
      memory_kb => _monit_num($n, './memory/kilobyte'),
      memory_kb_total => _monit_num($n, './memory/kilobytetotal'),
    };
  } elsif ($type == 4) {
    my @ports;
    for my $p ($n->findnodes('./port')) {
      push @ports, {
        hostname => _monit_text($p, './hostname'),
        port => _monit_num($p, './portnumber'),
        protocol => _monit_text($p, './protocol'),
        response_time => _monit_num($p, './responsetime'),
      };
    }
    $d{host} = { icmp_response_time => _monit_num($n, './icmp/responsetime'), ports => \@ports };
  } elsif ($type == 5) {
    $d{system} = {
      load_1 => _monit_num($n, './system/load/avg01'),
      load_5 => _monit_num($n, './system/load/avg05'),
      load_15 => _monit_num($n, './system/load/avg15'),
      cpu_user => _monit_num($n, './system/cpu/user'),
      cpu_system => _monit_num($n, './system/cpu/system'),
      cpu_wait => _monit_num($n, './system/cpu/wait'),
      memory_percent => _monit_num($n, './system/memory/percent'),
      memory_kb => _monit_num($n, './system/memory/kilobyte'),
      swap_percent => _monit_num($n, './system/swap/percent'),
      swap_kb => _monit_num($n, './system/swap/kilobyte'),
    };
  } elsif ($type == 7) {
    $d{program} = {
      started => _monit_num($n, './program/started'),
      status => _monit_num($n, './program/status'),
      output => _monit_text($n, './program/output'),
    };
  } elsif ($type == 8) {
    $d{network} = {
      link_state => _monit_num($n, './link/state'), speed => _monit_num($n, './link/speed'),
      duplex => _monit_num($n, './link/duplex'),
      rx_bytes => _monit_num($n, './download/bytes/total'), rx_packets => _monit_num($n, './download/packets/total'),
      rx_errors => _monit_num($n, './download/errors/total'),
      tx_bytes => _monit_num($n, './upload/bytes/total'), tx_packets => _monit_num($n, './upload/packets/total'),
      tx_errors => _monit_num($n, './upload/errors/total'),
    };
  } else {
    $d{filemeta} = {
      mode => _monit_num($n, './mode'), uid => _monit_num($n, './uid'), gid => _monit_num($n, './gid'),
      timestamp => _monit_num($n, './timestamp'), size => _monit_num($n, './size'), checksum => _monit_text($n, './checksum'),
    };
  }
  return \%d;
}

sub _monit_parse_xml {
  my ($xml) = @_;
  my $parser = XML::LibXML->new(no_network => 1, recover => 0);
  my $doc = $parser->load_xml(string => $xml);
  my ($root) = $doc->findnodes('/monit');
  die "Monit XML: Root-Element fehlt" unless $root;

  my ($server) = $root->findnodes('./server');
  my ($platform) = $root->findnodes('./platform');
  my @services;
  my ($healthy, $failed, $unmonitored) = (0,0,0);
  my $system;
  for my $n ($root->findnodes('./service')) {
    my $type = 0 + ($n->getAttribute('type') // -1);
    my $status = _monit_num($n, './status'); $status = -1 unless defined $status;
    my $monitor = _monit_num($n, './monitor'); $monitor = 0 unless defined $monitor;
    my $ok = ($status == 0 && $monitor != 0) ? 1 : 0;
    $unmonitored++ if $monitor == 0;
    $healthy++ if $ok;
    $failed++ if $status != 0;
    my $details = _monit_service_details($n, $type);
    $system = $details->{system} if $type == 5 && $details->{system};
    my @groups = map { my $v = $_->textContent // ''; $v =~ s/^\s+|\s+$//g; $v } $n->findnodes('./servicegroup');
    push @services, {
      name => _monit_text($n, './name'), type_id => $type, type => _monit_type_name($type), groups => \@groups,
      status => $status, monitor => $monitor,
      monitor_mode => (_monit_num($n, './monitormode') // 0),
      collected_sec => _monit_num($n, './collected_sec'),
      healthy => ($ok ? true() : false()), %$details,
    };
  }
  return {
    server => {
      id => _monit_text($server, './id'), version => _monit_text($server, './version'),
      uptime => _monit_num($server, './uptime'), poll => _monit_num($server, './poll'),
      hostname => _monit_text($server, './localhostname'),
    },
    platform => {
      name => _monit_text($platform, './name'), release => _monit_text($platform, './release'),
      machine => _monit_text($platform, './machine'), cpu => _monit_num($platform, './cpu'),
      memory_kb => _monit_num($platform, './memory'), swap_kb => _monit_num($platform, './swap'),
    },
    summary => {
      total => scalar(@services), healthy => $healthy, failed => $failed, unmonitored => $unmonitored,
      overall => ($failed > 0 ? 'failed' : ($unmonitored > 0 ? 'warning' : 'ok')),
    },
    system => ($system // {}), services => \@services,
  };
}

sub _monit_credentials {
  my $cfg = (ref($global->{monit_status}) eq 'HASH') ? $global->{monit_status} : {};
  my $file = $cfg->{credentials_file} // '/var/lib/service/config-agent/secrets/monit-status.env';
  return ('','',$file) unless -f $file && -r $file && !-l $file;
  open my $fh,'<',$file or return ('','',$file);
  my ($user,$pass)=('','');
  while(my $line=<$fh>){
    $line =~ s/[\r\n]+$//; next if $line =~ /^\s*(?:#|$)/;
    my($k,$v)=split(/=/,$line,2); next unless defined $v;
    $user=$v if $k eq 'MONIT_USER'; $pass=$v if $k eq 'MONIT_PASSWORD';
  }
  close $fh;
  return ($user,$pass,$file);
}

sub _monit_fetch_status {
  my $cfg = (ref($global->{monit_status}) eq 'HASH') ? $global->{monit_status} : {};
  my $url = $cfg->{url} // 'http://127.0.0.1:2812/_status?format=xml&level=full';
  die "Monit URL muss localhost/loopback sein" unless $url =~ m{^https?://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?/}i;
  my $timeout = ($cfg->{timeout} // 5); $timeout = 5 unless $timeout =~ /^\d+(?:\.\d+)?$/ && $timeout >= 1 && $timeout <= 30;
  my $max_bytes = ($cfg->{max_bytes} // 4_194_304); $max_bytes = 4_194_304 unless $max_bytes =~ /^\d+$/ && $max_bytes >= 65_536 && $max_bytes <= 16_777_216;
  my ($user,$pass) = _monit_credentials();
  my %headers=(Accept => 'application/xml,text/xml;q=0.9');
  $headers{Authorization} = 'Basic '.encode_base64($user.':'.$pass,'') if length($user) && length($pass);
  my $ua = Mojo::UserAgent->new;
  $ua->connect_timeout($timeout); $ua->request_timeout($timeout); $ua->inactivity_timeout($timeout);
  my $tx = $ua->get($url => \%headers);
  my $res = $tx->result;
  die "Monit nicht erreichbar: ".($tx->error->{message}//'unbekannter Fehler') unless $res;
  die "Monit HTTP ".$res->code unless $res->is_success;
  my $xml = $res->body // '';
  die "Monit XML leer" unless length $xml;
  die "Monit XML zu gross" if length($xml) > $max_bytes;
  my $parsed = _monit_parse_xml($xml);
  return { ok=>true(), collected_at=>time(), source=>'monit-xml', source_url=>$url, %$parsed };
}

get '/monit/status' => sub {
  my $c = shift;
  my $data = eval { _monit_fetch_status() };
  if ($@ || ref($data) ne 'HASH') {
    my $err = $@ || 'Monit Status konnte nicht gelesen werden';
    $err =~ s/[\r\n]+/ /g; $err =~ s/\s+$//;
    $logger->warn("MONIT_STATUS failed: $err") if $logger;
    return $c->render(json=>{ok=>false(),error=>$err},status=>503);
  }
  $c->render(json=>$data);
};

1;
