<?php
declare(strict_types=1);

/**
 * Runtime-Loader fuer config-manager.
 *
 * Die config/config.php bleibt bewusst statisch und lesbar.
 * Diese Datei normalisiert nur die Struktur fuer die bestehenden Seiten.
 */

function cm_bool_value(mixed $value, bool $default): bool
{
    if (is_bool($value)) {
        return $value;
    }

    if ($value === null || $value === '') {
        return $default;
    }

    $normalized = strtolower(trim((string)$value));
    if (in_array($normalized, ['1', 'true', 'yes', 'y', 'on', 'enabled', 'enable'], true)) {
        return true;
    }
    if (in_array($normalized, ['0', 'false', 'no', 'n', 'off', 'disabled', 'disable'], true)) {
        return false;
    }

    return $default;
}

function cm_int_value(mixed $value, int $default, int $min, int $max): int
{
    if ($value === null || $value === '') {
        return $default;
    }

    if (is_int($value)) {
        $intValue = $value;
    } else {
        $raw = trim((string)$value);
        if ($raw === '' || !preg_match('/^-?\d+$/', $raw)) {
            return $default;
        }
        $intValue = (int)$raw;
    }

    if ($intValue < $min || $intValue > $max) {
        return $default;
    }

    return $intValue;
}

function cm_validate_server_name(string $name, string $field): void
{
    if ($name === '') {
        throw new RuntimeException($field . ' ist leer. Beispiel: mail01-a');
    }

    if (preg_match('/\s/', $name)) {
        throw new RuntimeException($field . ' darf keine Leerzeichen enthalten. Beispiel: mail01-a');
    }

    if (!preg_match('/^[A-Za-z0-9._:-]{1,128}$/', $name)) {
        throw new RuntimeException($field . ' enthält ungültige Zeichen. Erlaubt sind A-Z, a-z, 0-9, Punkt, Unterstrich, Doppelpunkt und Minus.');
    }
}

function cm_validate_server_url(string $url, string $field): void
{
    if ($url === '') {
        throw new RuntimeException($field . ' ist leer. Beispiel: https://mail01-a:5010');
    }

    $parts = parse_url($url);
    $scheme = strtolower((string)($parts['scheme'] ?? ''));
    $host = (string)($parts['host'] ?? '');

    if (!in_array($scheme, ['http', 'https'], true) || $host === '') {
        throw new RuntimeException($field . ' ist keine gültige HTTP/HTTPS URL. Beispiel: https://mail01-a:5010');
    }
}

/**
 * Laedt config/config.php und liefert eine serverlist-kompatible Struktur.
 *
 * Neue Struktur:
 * [
 *   'api_token' => secret_env('CONFIG_MANAGER_APITOKEN'),
 *   'tls' => [...],
 *   'http' => [...],
 *   'servers' => [[name, url], ...],
 * ]
 *
 * Legacy-Struktur wird weiterhin toleriert:
 * [[name, url, token], ...]
 */
function cm_load_config_manager_servers(string $configFile): array
{
    if (!is_file($configFile)) {
        throw new RuntimeException('Datei /config/config.php fehlt.');
    }

    $cfg = require $configFile;
    if (!is_array($cfg) || $cfg === []) {
        throw new RuntimeException('config.php liefert keine gültige Konfiguration.');
    }

    $isStructured = array_key_exists('servers', $cfg) && is_array($cfg['servers']);

    $apiToken = '';
    $tls = [
        'verify' => true,
        'verify_host' => false,
        'ca_file' => '',
    ];

    $http = [
        'connect_timeout' => 10,
        'timeout' => 20,
    ];

    $gitDeploy = [
        'timeout' => 300,
    ];

    $gitUpload = [
        'timeout' => 600,
    ];

    $servers = [];

    if ($isStructured) {
        $apiToken = (string)($cfg['api_token'] ?? $cfg['apiToken'] ?? '');
        $tlsCfg = is_array($cfg['tls'] ?? null) ? $cfg['tls'] : [];
        $tls = [
            'verify' => cm_bool_value($tlsCfg['verify'] ?? true, true),
            'verify_host' => cm_bool_value($tlsCfg['verify_host'] ?? false, false),
            'ca_file' => trim((string)($tlsCfg['ca_file'] ?? '')),
        ];

        $httpCfg = is_array($cfg['http'] ?? null) ? $cfg['http'] : [];
        $http = [
            'connect_timeout' => cm_int_value($httpCfg['connect_timeout'] ?? 10, 10, 1, 300),
            'timeout' => cm_int_value($httpCfg['timeout'] ?? 20, 20, 1, 900),
        ];

        $gitDeployCfg = is_array($cfg['git_deploy'] ?? null) ? $cfg['git_deploy'] : [];
        $gitDeploy = [
            'timeout' => cm_int_value($gitDeployCfg['timeout'] ?? 300, 300, 30, 3600),
        ];

        $gitUploadCfg = is_array($cfg['git_upload'] ?? null) ? $cfg['git_upload'] : [];
        $gitUpload = [
            'timeout' => cm_int_value($gitUploadCfg['timeout'] ?? 600, 600, 30, 3600),
        ];

        $servers = $cfg['servers'];
    } else {
        $servers = $cfg;
    }

    if ($servers === []) {
        throw new RuntimeException('Keine Server konfiguriert.');
    }

    $out = [];
    $seen = [];

    foreach ($servers as $idx => $srv) {
        if (!is_array($srv)) {
            throw new RuntimeException('Server-Eintrag #' . (string)$idx . ' ist kein Array.');
        }

        // Inaktive Registry-Eintraege bleiben gespeichert, werden aber nicht als Laufzeitziel verwendet.
        if (array_key_exists('enabled', $srv) && !cm_bool_value($srv['enabled'], true)) {
            continue;
        }

        $name = (string)($srv['name'] ?? '');
        $url = (string)($srv['url'] ?? '');

        cm_validate_server_name($name, 'CONFIG_MANAGER_SERVERS_' . ((int)$idx + 1) . '_NAME');
        cm_validate_server_url($url, 'CONFIG_MANAGER_SERVERS_' . ((int)$idx + 1) . '_URL');

        $key = strtolower($name);
        if (isset($seen[$key])) {
            throw new RuntimeException('Servername doppelt konfiguriert: ' . $name);
        }
        $seen[$key] = true;

        $token = $isStructured ? $apiToken : (string)($srv['token'] ?? '');
        $tokenFile = trim((string)($srv['token_file'] ?? ''));
        $tokenSource = $tokenFile !== '' ? 'file' : 'global';
        $runtimeWarning = '';
        $runtimeError = '';
        $runtimeAvailable = true;
        if ($tokenFile !== '') {
            if ($tokenFile[0] !== '/' || str_contains($tokenFile, "\0")) {
                $runtimeError = 'token_file ist ungueltig: ' . $tokenFile;
                $token = '';
                $tokenSource = 'invalid';
                $runtimeAvailable = false;
            } elseif (!is_file($tokenFile) || is_link($tokenFile) || !is_readable($tokenFile)) {
                // Nur der lokale Loopback-Agent darf kontrolliert auf den bereits
                // geladenen Manager-Token zurueckfallen. Ein defekter Remote-Agent
                // degradiert nur sich selbst und darf niemals das ganze Portal sperren.
                $parts = parse_url($url);
                $host = strtolower((string)($parts['host'] ?? ''));
                $isLocalLoopback = in_array($host, ['127.0.0.1', '::1', 'localhost'], true);
                if ($isLocalLoopback && $apiToken !== '') {
                    $token = $apiToken;
                    $tokenSource = 'global-fallback';
                    $runtimeWarning = 'Lokale Token-Datei fehlt/ist nicht lesbar; Manager-Token wird temporaer verwendet: ' . $tokenFile;
                } else {
                    $token = '';
                    $tokenSource = 'missing';
                    $runtimeError = 'Token-Datei fehlt/ist unsicher/nicht lesbar: ' . $tokenFile;
                    $runtimeAvailable = false;
                }
            } else {
                $tokenRaw = file_get_contents($tokenFile);
                $token = is_string($tokenRaw) ? trim($tokenRaw) : '';
                if ($token === '') {
                    $tokenSource = 'invalid';
                    $runtimeError = 'Token-Datei ist leer: ' . $tokenFile;
                    $runtimeAvailable = false;
                }
            }
        }
        if ($token === '' && $runtimeError === '') {
            $runtimeError = 'API-Token ist leer oder fehlt.';
            $runtimeAvailable = false;
        }

        $serverTls = $tls;
        if (isset($srv['tls']) && is_array($srv['tls'])) {
            $serverTls = [
                'verify' => cm_bool_value($srv['tls']['verify'] ?? $tls['verify'], $tls['verify']),
                'verify_host' => cm_bool_value($srv['tls']['verify_host'] ?? $tls['verify_host'], $tls['verify_host']),
                'ca_file' => trim((string)($srv['tls']['ca_file'] ?? $tls['ca_file'])),
            ];
        }

        $serverHttp = $http;
        if (isset($srv['http']) && is_array($srv['http'])) {
            $serverHttp = [
                'connect_timeout' => cm_int_value($srv['http']['connect_timeout'] ?? $http['connect_timeout'], $http['connect_timeout'], 1, 300),
                'timeout' => cm_int_value($srv['http']['timeout'] ?? $http['timeout'], $http['timeout'], 1, 900),
            ];
        }

        $serverGitDeploy = $gitDeploy;
        if (isset($srv['git_deploy']) && is_array($srv['git_deploy'])) {
            $serverGitDeploy = [
                'timeout' => cm_int_value($srv['git_deploy']['timeout'] ?? $gitDeploy['timeout'], $gitDeploy['timeout'], 30, 3600),
            ];
        }

        $serverGitUpload = $gitUpload;
        if (isset($srv['git_upload']) && is_array($srv['git_upload'])) {
            $serverGitUpload = [
                'timeout' => cm_int_value($srv['git_upload']['timeout'] ?? $gitUpload['timeout'], $gitUpload['timeout'], 30, 3600),
            ];
        }

        $groups = [];
        foreach ((array)($srv['groups'] ?? []) as $group) {
            $group = trim((string)$group);
            if ($group === '' || !preg_match('/^[A-Za-z0-9._-]{1,64}$/', $group)) {
                throw new RuntimeException('Ungueltige Servergruppe bei ' . $name);
            }
            $groups[strtolower($group)] = $group;
        }

        $labels = [];
        if (isset($srv['labels']) && !is_array($srv['labels'])) {
            throw new RuntimeException('labels muss ein Objekt sein bei ' . $name);
        }
        foreach ((array)($srv['labels'] ?? []) as $labelKey => $labelValue) {
            $labelKey = trim((string)$labelKey);
            $labelValue = trim((string)$labelValue);
            if (!preg_match('/^[A-Za-z0-9._-]{1,64}$/', $labelKey)
                || !preg_match('/^[A-Za-z0-9._:@\/-]{1,128}$/', $labelValue)) {
                throw new RuntimeException('Ungueltiges Serverlabel bei ' . $name);
            }
            $labels[$labelKey] = $labelValue;
        }

        $out[] = [
            'name' => $name,
            'url' => $url,
            'token' => $token,
            'token_source' => $tokenSource,
            'runtime_warning' => $runtimeWarning,
            'runtime_error' => $runtimeError,
            'runtime_available' => $runtimeAvailable,
            'token_file' => $tokenFile,
            'groups' => array_values($groups),
            'labels' => $labels,
            'tls' => $serverTls,
            'http' => $serverHttp,
            'git_deploy' => $serverGitDeploy,
            'git_upload' => $serverGitUpload,
        ];
    }

    return $out;
}
