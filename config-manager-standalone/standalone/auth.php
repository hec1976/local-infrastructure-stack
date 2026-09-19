<?php

declare(strict_types=1);

/**
 * Eigenständiger Login als Ersatz für die (nicht mitgelieferte)
 * Authentifizierung aus shared/lib/mmbb_bootstrap.php.
 *
 * Benutzer liegen in standalone/data/users.json:
 *   {
 *     "hec": {
 *       "password_hash": "$2y$...",
 *       "roles": ["AdminPortal", "ConfigManager"]
 *     }
 *   }
 *
 * Passwort-Hashes anlegen/ändern mit:
 *   php standalone/create_user.php <benutzername>
 */

if (!function_exists('standalone_users_path')) {
    function standalone_users_path(): string
    {
        return __DIR__ . '/data/users.json';
    }
}

if (!function_exists('standalone_users_load')) {
    /**
     * @return array<string,array{password_hash:string,roles:array<int,string>}>
     */
    function standalone_users_load(): array
    {
        $path = standalone_users_path();
        if (!is_file($path) || !is_readable($path)) {
            return [];
        }
        $raw = file_get_contents($path);
        if ($raw === false) {
            return [];
        }
        $decoded = json_decode($raw, true);
        return is_array($decoded) ? $decoded : [];
    }
}

if (!function_exists('standalone_auth_attempt')) {
    /**
     * Prüft Benutzername/Passwort. Bei Erfolg wird die Session gesetzt und
     * ein Audit-Eintrag geschrieben, sonst false zurückgegeben.
     */
    function standalone_auth_attempt(string $username, string $password): bool
    {
        $users = standalone_users_load();
        $username = trim($username);

        if ($username === '' || !isset($users[$username])) {
            // Timing-Angriffe erschweren: trotzdem einen Hash-Vergleich ausführen.
            password_verify($password, '$2y$10$invalidinvalidinvalidinvalidinvalidinvalidinvali');
            return false;
        }

        $entry = $users[$username];
        $hash = (string)($entry['password_hash'] ?? '');
        if ($hash === '' || !password_verify($password, $hash)) {
            return false;
        }

        session_regenerate_id(true);
        $_SESSION['standalone_user'] = $username;
        $_SESSION['standalone_roles'] = array_values(array_map('strval', $entry['roles'] ?? []));
        $_SESSION['standalone_login_ts'] = time();
        $_SESSION['standalone_must_change_password'] = !empty($entry['must_change_password']);

        return true;
    }
}

if (!function_exists('standalone_auth_logout')) {
    function standalone_auth_logout(): void
    {
        $_SESSION = [];
        if (session_status() === PHP_SESSION_ACTIVE) {
            session_destroy();
        }
    }
}

if (!function_exists('standalone_require_login')) {
    /**
     * An den Anfang jeder geschützten Seite stellen (macht die Bootstrap-Datei
     * bereits automatisch). Leitet nicht angemeldete Nutzer auf login.php um.
     */
    function standalone_require_login(): void
    {
        if (!empty($_SESSION['standalone_user'])) {
            $script = basename((string)($_SERVER['SCRIPT_NAME'] ?? ''));
            if (!empty($_SESSION['standalone_must_change_password']) && $script !== 'password_change.php' && $script !== 'login.php') {
                header('Location: password_change.php?required=1');
                exit;
            }
            return;
        }

        $target = $_SERVER['REQUEST_URI'] ?? '/';
        $loginUrl = 'login.php';
        if (basename(parse_url($target, PHP_URL_PATH) ?? '') !== 'login.php') {
            $loginUrl .= '?redirect=' . urlencode($target);
        }
        header('Location: ' . $loginUrl);
        exit;
    }
}

if (!function_exists('mmbb_has_service')) {
    /**
     * Ersatz für mmbb_has_service(): prüft, ob der angemeldete Benutzer die
     * angegebene Rolle besitzt. Rolle '*' gibt vollen Zugriff.
     */
    function mmbb_has_service(string $service): bool
    {
        $roles = $_SESSION['standalone_roles'] ?? [];
        if (!is_array($roles)) {
            return false;
        }
        return in_array('*', $roles, true) || in_array($service, $roles, true);
    }
}
