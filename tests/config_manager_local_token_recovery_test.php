<?php
declare(strict_types=1);
require __DIR__ . '/../config-manager-standalone/lib/config_manager_runtime.php';
$tmp = sys_get_temp_dir() . '/teko-local-token-recovery-' . getmypid();
@mkdir($tmp, 0700, true);
$missing = $tmp . '/missing.token';
$cfgLocal = $tmp . '/local.php';
file_put_contents($cfgLocal, '<?php return ' . var_export([
    'api_token' => str_repeat('a', 64),
    'servers' => [[
        'name' => 'local',
        'url' => 'https://127.0.0.1:5008',
        'token_file' => $missing,
    ]],
], true) . ';');
$servers = cm_load_config_manager_servers($cfgLocal);
if (count($servers) !== 1) { fwrite(STDERR, "local server missing\n"); exit(1); }
if (($servers[0]['token_source'] ?? '') !== 'global-fallback') { fwrite(STDERR, "no local fallback\n"); exit(1); }
if (($servers[0]['token'] ?? '') !== str_repeat('a', 64)) { fwrite(STDERR, "wrong fallback token\n"); exit(1); }
if (($servers[0]['runtime_warning'] ?? '') === '') { fwrite(STDERR, "warning missing\n"); exit(1); }

$cfgRemote = $tmp . '/remote.php';
file_put_contents($cfgRemote, '<?php return ' . var_export([
    'api_token' => str_repeat('a', 64),
    'servers' => [[
        'name' => 'remote01',
        'url' => 'https://192.0.2.10:5008',
        'token_file' => $missing,
    ]],
], true) . ';');
$remoteServers = cm_load_config_manager_servers($cfgRemote);
if (count($remoteServers) !== 1) { fwrite(STDERR, "remote server missing\n"); exit(1); }
if (($remoteServers[0]['runtime_available'] ?? true) !== false) { fwrite(STDERR, "remote missing token not degraded\n"); exit(1); }
if (($remoteServers[0]['runtime_error'] ?? '') === '') { fwrite(STDERR, "remote runtime error missing\n"); exit(1); }
if (($remoteServers[0]['token_source'] ?? '') !== 'missing') { fwrite(STDERR, "remote token source wrong\n"); exit(1); }
@unlink($cfgLocal); @unlink($cfgRemote); @rmdir($tmp);
echo "config_manager_local_token_recovery_test: PASS\n";
