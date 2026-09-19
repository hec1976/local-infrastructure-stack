<?php
/**
 * TEKO Config Manager runtime configuration.
 * Secrets bleiben in standalone/data/config-manager.env.
 * Die Server-Flotte liegt getrennt in einer root-gepflegten JSON-Registry.
 */
require_once __DIR__ . '/../standalone/env.php';

$registryFile = trim((string)(cfg('CONFIG_MANAGER_SERVER_REGISTRY_FILE') ?? ''));
if ($registryFile === '') $registryFile = '/opt/service/config-manager/servers.json';

$servers = [];
if (is_file($registryFile) && !is_link($registryFile) && is_readable($registryFile)) {
    $raw = file_get_contents($registryFile);
    $decoded = is_string($raw) ? json_decode($raw, true) : null;
    if (!is_array($decoded) || !is_array($decoded['servers'] ?? null)) {
        throw new RuntimeException('Server-Registry ist ungueltig: ' . $registryFile);
    }
    $servers = array_values($decoded['servers']);
}
if ($servers === []) {
    $servers = [[
        'name' => cfg('CONFIG_MANAGER_SERVERS_0_NAME'),
        'url' => cfg('CONFIG_MANAGER_SERVERS_0_URL'),
        'groups' => ['local'],
        'labels' => ['env' => 'lab'],
    ]];
}

$desiredStateFile = trim((string)(cfg('CONFIG_MANAGER_DESIRED_STATE_FILE') ?? ''));
if ($desiredStateFile === '') {
    $desiredStateFile = __DIR__ . '/../standalone/data/desired_state.json';
}

return [
    'api_token' => secret_env('CONFIG_MANAGER_API_TOKEN'),
    'server_registry_file' => $registryFile,
    'desired_state' => ['file' => $desiredStateFile, 'max_targets' => 100],
    'tls' => [
        'verify' => cfg('CONFIG_MANAGER_TLS_VERIFY'),
        'verify_host' => cfg('CONFIG_MANAGER_TLS_VERIFY_HOST'),
        'ca_file' => cfg('CONFIG_MANAGER_TLS_CA_FILE'),
    ],
    'http' => [
        'connect_timeout' => cfg('CONFIG_MANAGER_HTTP_CONNECT_TIMEOUT'),
        'timeout' => cfg('CONFIG_MANAGER_HTTP_TIMEOUT'),
    ],
    'git_deploy' => [
        'timeout' => cfg('CONFIG_MANAGER_GIT_DEPLOY_HTTP_TIMEOUT'),
        'required_service' => cfg('CONFIG_MANAGER_GIT_DEPLOY_REQUIRED_SERVICE'),
    ],
    'git_upload' => [
        'timeout' => cfg('CONFIG_MANAGER_GIT_UPLOAD_HTTP_TIMEOUT'),
        'required_service' => cfg('CONFIG_MANAGER_GIT_UPLOAD_REQUIRED_SERVICE'),
    ],
    'servers' => $servers,
];
