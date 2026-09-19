<?php
declare(strict_types=1);
$root=$argv[1];
require $root . '/config-manager-standalone/lib/config_manager_runtime.php';

$tmp=sys_get_temp_dir().'/teko-registry-test-'.bin2hex(random_bytes(4));
mkdir($tmp,0700,true);
$tokenFile=$tmp.'/node2.token';
file_put_contents($tokenFile,str_repeat('2',64));
chmod($tokenFile,0600);

$configFile=$tmp.'/config.php';
$global=str_repeat('1',64);
$tf=var_export($tokenFile,true);
$g=var_export($global,true);
file_put_contents($configFile,<<<PHP
<?php
return [
 'api_token'=>$g,
 'tls'=>['verify'=>false,'verify_host'=>false,'ca_file'=>''],
 'http'=>['connect_timeout'=>10,'timeout'=>20],
 'git_deploy'=>['timeout'=>300],
 'git_upload'=>['timeout'=>600],
 'servers'=>[
  ['name'=>'mail01','url'=>'https://127.0.0.1:5008','groups'=>['mail','prod'],'labels'=>['env'=>'prod','role'=>'mailrelay']],
  ['name'=>'web01','url'=>'https://127.0.0.1:5009','groups'=>['web'],'labels'=>['env'=>'prod'],'token_file'=>$tf]
 ]
];
PHP);

$servers=cm_load_config_manager_servers($configFile);
assert(count($servers)===2);
assert($servers[0]['name']==='mail01');
assert($servers[0]['groups']===['mail','prod']);
assert($servers[0]['labels']['role']==='mailrelay');
assert($servers[0]['token_source']==='global');
assert($servers[0]['token']===$global);
assert($servers[1]['token_source']==='file');
assert($servers[1]['token']===str_repeat('2',64));

$link=$tmp.'/token-link';
symlink($tokenFile,$link);
$badConfig=$tmp.'/bad.php';
$lf=var_export($link,true);
file_put_contents($badConfig,<<<PHP
<?php
return [
 'api_token'=>$g,
 'tls'=>['verify'=>false,'verify_host'=>false,'ca_file'=>''],
 'http'=>['connect_timeout'=>10,'timeout'=>20],
 'git_deploy'=>['timeout'=>300],
 'git_upload'=>['timeout'=>600],
 'servers'=>[['name'=>'bad01','url'=>'https://192.0.2.10:5010','token_file'=>$lf]]
];
PHP);
$badServers=cm_load_config_manager_servers($badConfig);
assert(count($badServers)===1);
assert($badServers[0]['name']==='bad01');
assert($badServers[0]['runtime_available']===false);
assert($badServers[0]['token_source']==='missing');
assert(str_contains((string)$badServers[0]['runtime_error'], 'Token-Datei fehlt/ist unsicher/nicht lesbar'));

@unlink($badConfig);@unlink($link);@unlink($configFile);@unlink($tokenFile);@rmdir($tmp);
echo "fleet_registry_test: OK\n";
