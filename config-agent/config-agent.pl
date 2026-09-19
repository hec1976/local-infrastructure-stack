#!/usr/bin/env perl
# Config Agent — modular
# Version 2.23.15
#
# Dateien:
#   global.json          Dienst- und allgemeine Git-Einstellungen
#   managed_configs.json verwaltete Konfigurationsdateien und Actions
#   git_deploy.json      Git-Deployment-Profile
#
# Legacy:
#   configs.json wird nur verwendet, wenn managed_configs.json fehlt.
#
use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/lib";
use Mojolicious::Lite;

our ($VERSION, $global, $logger);

require Core;
require ConfigFiles;
require Actions;
require GitDeploy;
require GitUpload;
require PackageMgmt;
require ModSecurity;
require Fail2Ban;
require Firewall;
require MonitStatus;
require PlatformBaseline;
require FileManager;
require Routes;

$logger->info("BOOT_READY version=$VERSION architecture=modular modules=Core,ConfigFiles,Actions,GitDeploy,GitUpload,PackageMgmt,ModSecurity,Fail2Ban,Firewall,MonitStatus,PlatformBaseline,FileManager,Routes");

my $listen_url;
if ($global->{ssl_enable} && $global->{ssl_cert_file} && $global->{ssl_key_file}) {
  $listen_url = "https://$global->{listen}?cert=$global->{ssl_cert_file}&key=$global->{ssl_key_file}";
  $logger->info("HTTPS: $listen_url");
} else {
  $listen_url = "http://$global->{listen}";
  $logger->info("HTTP: $listen_url");
}

app->start('daemon', '-l', $listen_url);
