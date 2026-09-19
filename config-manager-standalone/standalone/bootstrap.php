<?php

declare(strict_types=1);

/**
 * Eigenständige Bootstrap-Datei.
 *
 * Ersetzt shared/lib/mmbb_bootstrap.php aus dem MMBB-Projekt. Stellt exakt
 * dieselben Funktionsnamen/Konstanten bereit (MMBB_UI, mmbb_has_service(),
 * mmbb_audit_write() usw.), damit public/*.php, Utils/Logger.php und
 * lib/config_manager_runtime.php unverändert bleiben. In jeder Seite muss
 * nur die eine require_once-Zeile auf diese Datei zeigen.
 */

if (session_status() === PHP_SESSION_NONE) {
    ini_set('session.use_strict_mode', '1');
    ini_set('session.use_only_cookies', '1');
    ini_set('session.cookie_httponly', '1');
    ini_set('session.cookie_secure', '1');
    ini_set('session.cookie_samesite', 'Strict');
    session_start();
}

if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

if (!headers_sent()) {
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: DENY');
    header('Referrer-Policy: same-origin');
}

require_once __DIR__ . '/env.php';
require_once __DIR__ . '/audit.php';
require_once __DIR__ . '/auth.php';

// Pfad zum eigenständigen UI-Layout (ersetzt das MMBB_UI-Verzeichnis).
if (!defined('MMBB_UI')) {
    define('MMBB_UI', __DIR__ . '/layout');
}

if (!function_exists('mmbb_css_file_to_url')) {
    /**
     * Ersatz für mmbb_css_file_to_url(): wandelt einen Dateisystempfad
     * unterhalb des public/-Verzeichnisses in eine relative URL um.
     */
    function mmbb_css_file_to_url(string $absolutePath): string
    {
        $publicRoot = realpath(__DIR__ . '/../public');
        $real = realpath($absolutePath);
        if ($publicRoot === false || $real === false || !str_starts_with($real, $publicRoot)) {
            return '';
        }
        return substr($real, strlen($publicRoot));
    }
}

// Login erzwingen (ausser auf der Login-Seite selbst).
$standaloneScript = basename((string)($_SERVER['SCRIPT_NAME'] ?? ''));
if ($standaloneScript !== 'login.php') {
    standalone_require_login();
}
