<?php

declare(strict_types=1);

/**
 * Eigenständiges Audit-Log auf SQLite-Basis.
 *
 * Ersetzt shared/lib/core/audit.php aus dem MMBB-Projekt 1:1 in der
 * Funktionssignatur, damit Utils/Logger.php und public/auditlog.php
 * unverändert bleiben können.
 */

require_once __DIR__ . '/env.php';

if (!function_exists('standalone_audit_db_path')) {
    function standalone_audit_db_path(): string
    {
        $path = cfg('LOG_DB_PATH');
        if ($path !== null && $path !== '') {
            return $path;
        }
        return __DIR__ . '/data/audit_log.sqlite';
    }
}

if (!function_exists('mmbb_audit_load_env')) {
    /**
     * Ersatz für mmbb_audit_load_env(): stellt sicher, dass der Audit-DB-Pfad
     * beschreibbar ist. Gibt bei Erfolg true zurück.
     */
    function mmbb_audit_load_env(): bool
    {
        $path = standalone_audit_db_path();
        $dir = dirname($path);
        if (!is_dir($dir)) {
            @mkdir($dir, 0770, true);
        }
        return is_dir($dir) && is_writable($dir);
    }
}

if (!function_exists('log_db')) {
    /**
     * Ersatz für log_db(): liefert eine PDO-Verbindung zur lokalen
     * Audit-SQLite-Datenbank.
     */
    function log_db(): PDO
    {
        static $pdo = null;
        if ($pdo instanceof PDO) {
            return $pdo;
        }

        $path = standalone_audit_db_path();
        $pdo = new PDO('sqlite:' . $path);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
        $pdo->exec('PRAGMA journal_mode = WAL');
        $pdo->exec('PRAGMA foreign_keys = ON');

        return $pdo;
    }
}

if (!function_exists('ensure_log_schema')) {
    /**
     * Ersatz für ensure_log_schema(): legt die audit_log-Tabelle an, falls
     * sie noch nicht existiert. Spalten entsprechen 1:1 dem, was
     * public/auditlog.php erwartet (module, user, action, identity, ts, ...).
     */
    function ensure_log_schema(): void
    {
        $pdo = log_db();
        $pdo->exec(
            'CREATE TABLE IF NOT EXISTS audit_log (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                ts       TEXT NOT NULL,
                module   TEXT NOT NULL,
                user     TEXT NOT NULL,
                action   TEXT NOT NULL,
                identity TEXT NOT NULL,
                function TEXT NOT NULL,
                result   TEXT NOT NULL,
                payload  TEXT NOT NULL
            )'
        );
        // Schema-Migration fuer aeltere Standalone-Installationen. Die GUI
        // erwartet IP/URI und data_json; bestehende Datenbanken werden ohne
        // Drop/Recreate kompatibel erweitert.
        $columns = [];
        foreach ($pdo->query('PRAGMA table_info(audit_log)') ?: [] as $row) {
            if (is_array($row) && isset($row['name'])) {
                $columns[(string)$row['name']] = true;
            }
        }
        foreach ([
            'ip' => "TEXT NOT NULL DEFAULT ''",
            'uri' => "TEXT NOT NULL DEFAULT ''",
            'data_json' => "TEXT NOT NULL DEFAULT ''",
        ] as $column => $definition) {
            if (!isset($columns[$column])) {
                $pdo->exec('ALTER TABLE audit_log ADD COLUMN ' . $column . ' ' . $definition);
            }
        }

        $pdo->exec('CREATE INDEX IF NOT EXISTS idx_audit_log_module ON audit_log (module)');
        $pdo->exec('CREATE INDEX IF NOT EXISTS idx_audit_log_ts ON audit_log (ts)');
        $pdo->exec('CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log (action)');
        $pdo->exec('CREATE INDEX IF NOT EXISTS idx_audit_log_result ON audit_log (result)');
    }
}

if (!function_exists('mmbb_audit_module_key')) {
    /**
     * Ersatz für mmbb_audit_module_key(): fester Modul-Schlüssel für dieses
     * eigenständige Portal.
     */
    function mmbb_audit_module_key(): string
    {
        return 'config-manager-standalone';
    }
}

if (!function_exists('mmbb_audit_current_user')) {
    /**
     * Ersatz für mmbb_audit_current_user(): liest den angemeldeten Benutzer
     * aus der Session (siehe standalone/auth.php).
     */
    function mmbb_audit_current_user(): string
    {
        // session_write_close() wird vor langen Multi-Server-Deployments
        // bewusst verwendet. $_SESSION bleibt fuer den laufenden Request
        // lesbar, auch wenn die Session nicht mehr gesperrt ist.
        $user = is_array($_SESSION ?? null) ? ($_SESSION['standalone_user'] ?? null) : null;
        return is_string($user) && $user !== '' ? $user : 'anonymous';
    }
}

if (!function_exists('mmbb_audit_write')) {
    /**
     * Ersatz für mmbb_audit_write(): schreibt einen Audit-Eintrag in die
     * lokale SQLite-Datenbank. Signatur ist identisch zum MMBB-Original,
     * damit Utils/Logger.php unverändert bleibt.
     *
     * @param mixed $payload wird als JSON gespeichert
     */
    function mmbb_audit_write(
        string $action,
        string $identity,
        $payload,
        string $function,
        string $result
    ): bool {
        try {
            ensure_log_schema();
            $pdo = log_db();
            $payloadJson = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?: '{}';
            $ip = trim((string)($_SERVER['REMOTE_ADDR'] ?? ''));
            if (strlen($ip) > 64) $ip = substr($ip, 0, 64);
            // Keine Query-Strings ins Audit uebernehmen: dort koennen Token oder
            // andere sensitive Parameter stehen. Der Script-Pfad reicht fuer
            // die technische Nachvollziehbarkeit.
            $uri = trim((string)(parse_url((string)($_SERVER['REQUEST_URI'] ?? ''), PHP_URL_PATH) ?? ''));
            if (strlen($uri) > 512) $uri = substr($uri, 0, 512);

            $st = $pdo->prepare(
                'INSERT INTO audit_log (ts, module, user, action, identity, function, result, payload, ip, uri, data_json)
                 VALUES (:ts, :module, :user, :action, :identity, :function, :result, :payload, :ip, :uri, :data_json)'
            );
            $st->execute([
                'ts'       => gmdate('Y-m-d\TH:i:s\Z'),
                'module'   => mmbb_audit_module_key(),
                'user'     => mmbb_audit_current_user(),
                'action'   => $action,
                'identity' => $identity,
                'function' => $function,
                'result'   => $result,
                'payload'  => $payloadJson,
                'ip'       => $ip,
                'uri'      => $uri,
                'data_json'=> $payloadJson,
            ]);
            return true;
        } catch (Throwable $e) {
            error_log('mmbb_audit_write (standalone) fehlgeschlagen: ' . $e->getMessage());
            return false;
        }
    }
}
