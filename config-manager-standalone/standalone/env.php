<?php

declare(strict_types=1);

/**
 * Eigenständiger Ersatz für die MMBB-Laufzeitumgebung.
 *
 * Ersetzt MMBB_ENV_PHP + secret_env() + cfg() aus dem MMBB-Projekt durch
 * eine simple lokale .env-Datei. Wird nur von config/config.php benutzt.
 *
 * Format der .env-Datei (eine Zeile pro Wert, KEY=WERT, '#' = Kommentar):
 *
 *   CONFIG_MANAGER_API_TOKEN=xxxxxxxx
 *   CONFIG_MANAGER_TLS_VERIFY=true
 *   CONFIG_MANAGER_SERVERS_0_NAME=mail01-a
 *   CONFIG_MANAGER_SERVERS_0_URL=https://mail01-a:5010
 */

if (!function_exists('standalone_env_path')) {
    function standalone_env_path(): string
    {
        $path = getenv('CONFIG_MANAGER_ENV_FILE');
        if ($path !== false && $path !== '') {
            return $path;
        }

        // Standardablage ausserhalb des Web-Roots.
        return __DIR__ . '/data/config-manager.env';
    }
}

if (!function_exists('standalone_env_load')) {
    /**
     * @return array<string,string>
     */
    function standalone_env_load(): array
    {
        static $values = null;
        if ($values !== null) {
            return $values;
        }

        $values = [];
        $path = standalone_env_path();

        if (is_file($path) && is_readable($path)) {
            $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
            foreach ($lines as $line) {
                $line = trim($line);
                if ($line === '' || str_starts_with($line, '#')) {
                    continue;
                }
                $pos = strpos($line, '=');
                if ($pos === false) {
                    continue;
                }
                $key = trim(substr($line, 0, $pos));
                $val = trim(substr($line, $pos + 1));
                // Anführungszeichen um den Wert entfernen, falls vorhanden.
                if (strlen($val) >= 2 && $val[0] === '"' && substr($val, -1) === '"') {
                    $val = substr($val, 1, -1);
                }
                if ($key !== '') {
                    $values[$key] = $val;
                }
            }
        }

        return $values;
    }
}

if (!function_exists('cfg')) {
    /**
     * Ersatz für die MMBB-Funktion cfg(): liest einen Konfigurationswert.
     */
    function cfg(string $key, ?string $default = null): ?string
    {
        $values = standalone_env_load();
        if (array_key_exists($key, $values)) {
            return $values[$key];
        }

        $envValue = getenv($key);
        if ($envValue !== false) {
            return $envValue;
        }

        return $default;
    }
}

if (!function_exists('secret_env')) {
    /**
     * Ersatz für die MMBB-Funktion secret_env(): identisch zu cfg(), aber
     * eigener Name für Werte, die als Geheimnis gelten (API-Token etc.).
     */
    function secret_env(string $key, ?string $default = null): ?string
    {
        return cfg($key, $default);
    }
}
