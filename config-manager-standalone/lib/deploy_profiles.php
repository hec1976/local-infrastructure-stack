<?php
declare(strict_types=1);

function dp_profiles_file(): string
{
    return __DIR__ . '/../standalone/data/deploy_profiles.json';
}

function dp_backup_dir(): string
{
    return __DIR__ . '/../standalone/data/deploy_profiles_backups';
}

function dp_default_document(): array
{
    return ['schema_version' => 2, 'profiles' => []];
}

function dp_validate_document(array $doc): array
{
    $schema = (int)($doc['schema_version'] ?? 0);
    if (!in_array($schema, [1, 2], true)) {
        throw new InvalidArgumentException('Deploy-Profile: schema_version muss 1 oder 2 sein.');
    }
    if (!isset($doc['profiles']) || !is_array($doc['profiles'])) {
        throw new InvalidArgumentException('Deploy-Profile: profiles muss ein Objekt sein.');
    }
    foreach ($doc['profiles'] as $id => $profile) {
        $id = (string)$id;
        if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $id)) {
            throw new InvalidArgumentException('Ungültige Profil-ID: ' . $id);
        }
        if (!is_array($profile)) {
            throw new InvalidArgumentException("Profil $id muss ein Objekt sein.");
        }
    }
    return $doc;
}

function dp_decode_content(string $content): array
{
    if ($content === '') throw new InvalidArgumentException('Deploy-Profile dürfen nicht leer sein.');
    if (strlen($content) > 1024 * 1024) throw new LengthException('Deploy-Profile sind zu gross (Maximum 1 MiB).');
    $doc = json_decode($content, true);
    if (!is_array($doc)) throw new InvalidArgumentException('Deploy-Profile enthalten kein gültiges JSON.');
    return dp_validate_document($doc);
}

function dp_encode(array $doc): string
{
    $json = json_encode($doc, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if (!is_string($json)) throw new RuntimeException('Deploy-Profile konnten nicht kodiert werden.');
    return $json . "\n";
}

function dp_load(): array
{
    $file = dp_profiles_file();
    if (!is_file($file)) return dp_default_document();
    if (is_link($file)) throw new RuntimeException('deploy_profiles.json darf kein Symlink sein.');
    $raw = file_get_contents($file);
    if (!is_string($raw)) throw new RuntimeException('deploy_profiles.json konnte nicht gelesen werden.');
    return dp_decode_content($raw);
}

function dp_content(): string
{
    return dp_encode(dp_load());
}

function dp_inventory_profiles(?array $doc = null): array
{
    $doc ??= dp_load();
    $out = [];
    foreach ((array)$doc['profiles'] as $id => $profile) {
        if (!is_array($profile)) continue;
        $profile['id'] = (string)$id;
        $out[] = $profile;
    }
    usort($out, static fn(array $a, array $b): int => strcmp((string)$a['id'], (string)$b['id']));
    return $out;
}

function dp_atomic_write(string $content, bool $backupCurrent = true): array
{
    $doc = dp_decode_content($content);
    $file = dp_profiles_file();
    $dir = dirname($file);
    if (!is_dir($dir) && !@mkdir($dir, 0770, true) && !is_dir($dir)) {
        throw new RuntimeException('Deploy-Profil-Verzeichnis konnte nicht erstellt werden.');
    }
    if (!is_writable($dir)) throw new RuntimeException('Deploy-Profil-Verzeichnis ist nicht schreibbar.');
    if (is_link($file)) throw new RuntimeException('deploy_profiles.json darf kein Symlink sein.');

    $backup = '';
    if ($backupCurrent && is_file($file)) {
        $backupDir = dp_backup_dir();
        if (!is_dir($backupDir) && !@mkdir($backupDir, 0770, true) && !is_dir($backupDir)) {
            throw new RuntimeException('Deploy-Profil-Backup-Verzeichnis konnte nicht erstellt werden.');
        }
        $backup = 'deploy_profiles.json.bak.' . date('Ymd_His') . '_' . sprintf('%03d', (int)(microtime(true) * 1000) % 1000);
        if (!@copy($file, $backupDir . '/' . $backup)) {
            throw new RuntimeException('Deploy-Profil-Backup konnte nicht erstellt werden.');
        }
        @chmod($backupDir . '/' . $backup, 0640);
    }

    $normalized = dp_encode($doc);
    $tmp = tempnam($dir, '.deploy-profiles.');
    if (!is_string($tmp) || $tmp === '') throw new RuntimeException('Temporäre Deploy-Profil-Datei konnte nicht angelegt werden.');
    try {
        if (file_put_contents($tmp, $normalized, LOCK_EX) === false) throw new RuntimeException('Deploy-Profile konnten nicht geschrieben werden.');
        @chmod($tmp, 0640);
        if (!@rename($tmp, $file)) throw new RuntimeException('Deploy-Profile konnten nicht atomar aktiviert werden.');
    } finally {
        if (is_file($tmp)) @unlink($tmp);
    }

    return [
        'content' => $normalized,
        'sha256' => hash('sha256', $normalized),
        'profiles' => count((array)$doc['profiles']),
        'backup' => $backup,
    ];
}

function dp_backups(): array
{
    $dir = dp_backup_dir();
    if (!is_dir($dir)) return [];
    $items = [];
    foreach (scandir($dir) ?: [] as $name) {
        if (preg_match('/^deploy_profiles\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $name)) $items[] = $name;
    }
    rsort($items, SORT_STRING);
    return array_slice($items, 0, 50);
}

function dp_backup_get(string $filename): array
{
    if (!preg_match('/^deploy_profiles\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
        throw new InvalidArgumentException('Ungültiger Deploy-Profil-Backupname.');
    }
    $path = dp_backup_dir() . '/' . $filename;
    if (!is_file($path) || is_link($path)) throw new RuntimeException('Deploy-Profil-Backup nicht gefunden.');
    $content = file_get_contents($path);
    if (!is_string($content)) throw new RuntimeException('Deploy-Profil-Backup konnte nicht gelesen werden.');
    $doc = dp_decode_content($content);
    return ['filename' => $filename, 'content' => $content, 'summary' => ['profiles' => count((array)$doc['profiles'])]];
}

function dp_restore(string $filename): array
{
    $backup = dp_backup_get($filename);
    return dp_atomic_write((string)$backup['content'], true);
}
