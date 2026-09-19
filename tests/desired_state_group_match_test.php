<?php
require __DIR__ . '/../config-manager-standalone/lib/desired_state.php';
$s1=['name'=>'teko','groups'=>['local','mail'],'labels'=>['env'=>'lab','role'=>'mailrelay']];
$s2=['name'=>'suse01','groups'=>['linux'],'labels'=>[]];
$selAny=['groups'=>['linux','mail'],'labels'=>[],'group_match'=>'any'];
$selAll=['groups'=>['linux','mail'],'labels'=>[],'group_match'=>'all'];
if (!ds_selector_matches($s1,$selAny) || !ds_selector_matches($s2,$selAny)) { fwrite(STDERR,"any failed\n"); exit(1); }
if (ds_selector_matches($s1,$selAll) || ds_selector_matches($s2,$selAll)) { fwrite(STDERR,"all failed\n"); exit(1); }
$selLabel=['groups'=>['linux','mail'],'labels'=>['env'=>'lab'],'group_match'=>'any'];
if (!ds_selector_matches($s1,$selLabel) || ds_selector_matches($s2,$selLabel)) { fwrite(STDERR,"label failed\n"); exit(1); }
echo "desired_state_group_match_test: PASS\n";
