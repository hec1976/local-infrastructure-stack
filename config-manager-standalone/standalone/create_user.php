<?php

declare(strict_types=1);

/**
 * CLI-Hilfsskript: Benutzer für den eigenständigen Login anlegen/ändern.
 *
 * Aufruf:
 *   php standalone/create_user.php <benutzername> [Rolle1,Rolle2,...]
 *
 * Beispiel:
 *   php standalone/create_user.php hec AdminPortal,ConfigManager
 *
 * Fragt das Passwort interaktiv ab (nicht in der Shell-History sichtbar,
 * sofern das Terminal `stty -echo` unterstützt).
 */

if (php_sapi_name() !== 'cli') {
    fwrite(STDERR, "Dieses Skript darf nur auf der Kommandozeile ausgeführt werden.\n");
    exit(1);
}

$username = trim((string)($argv[1] ?? ''));
if ($username === '') {
    fwrite(STDERR, "Verwendung: php standalone/create_user.php <benutzername> [Rolle1,Rolle2,...]\n");
    exit(1);
}

$rolesArg = trim((string)($argv[2] ?? 'AdminPortal,ConfigManager'));
$roles = array_values(array_filter(array_map('trim', explode(',', $rolesArg)), fn($r) => $r !== ''));

$envPassword = getenv('CM_NEW_PASSWORD');
if ($envPassword !== false && $envPassword !== '') {
    // Nicht-interaktiver Modus, z.B. aus einem Setup-Skript heraus.
    $password = $envPassword;
} else {
    fwrite(STDOUT, "Passwort für '{$username}': ");
    if (stripos(PHP_OS, 'WIN') === false) {
        system('stty -echo');
    }
    $password = trim((string)fgets(STDIN));
    if (stripos(PHP_OS, 'WIN') === false) {
        system('stty echo');
    }
    fwrite(STDOUT, "\n");
}

$allowWeakBootstrap = getenv('CM_BOOTSTRAP_ALLOW_WEAK') === '1' && $username === 'admin';
if (strlen($password) < 12 && !$allowWeakBootstrap) {
    fwrite(STDERR, "Passwort muss mindestens 12 Zeichen lang sein.\n");
    exit(1);
}

$usersPath = __DIR__ . '/data/users.json';
$users = [];
if (is_file($usersPath)) {
    $decoded = json_decode((string)file_get_contents($usersPath), true);
    if (is_array($decoded)) {
        $users = $decoded;
    }
}

$users[$username] = [
    'password_hash' => password_hash($password, PASSWORD_BCRYPT),
    'roles' => $roles,
    'must_change_password' => getenv('CM_FORCE_PASSWORD_CHANGE') === '1',
];

$dir = dirname($usersPath);
if (!is_dir($dir)) {
    mkdir($dir, 0770, true);
}

file_put_contents(
    $usersPath,
    json_encode($users, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)
);
chmod($usersPath, 0640);

fwrite(STDOUT, "Benutzer '{$username}' gespeichert (Rollen: " . implode(', ', $roles) . ").\n");
