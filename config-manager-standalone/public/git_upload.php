<?php
declare(strict_types=1);

// Config Manager Portal 3.10.1 - Git Repository Upload - unified auth runtime

require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../autoloader.php';
require_once __DIR__ . '/../Repository/ConfigManagerRepository.php';
require_once __DIR__ . '/../Service/ConfigManagerService.php';
require_once __DIR__ . '/../Controller/ConfigManagerController.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;
use ConfigManager\Controller\ConfigManagerController;

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}
if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}
$csrfToken = (string)$_SESSION['csrf_token'];

if (!headers_sent()) {
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('Pragma: no-cache');
    header('Expires: 0');
}

function gu_h(mixed $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function gu_json_out(array $payload, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('X-Content-Type-Options: nosniff');
    $json = json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    echo $json === false ? '{"ok":false,"error":"JSON-Encoding fehlgeschlagen"}' : $json;
    exit;
}

function gu_actor(): string
{
    foreach (['user_id', 'username', 'user', 'login'] as $key) {
        $value = trim((string)($_SESSION[$key] ?? ''));
        if ($value !== '') {
            return substr(preg_replace('/[\x00-\x1f\x7f]/', '?', $value) ?? 'portal-user', 0, 128);
        }
    }
    return 'portal-user';
}

function gu_controller(array $server): ConfigManagerController
{
    return new ConfigManagerController(new ConfigManagerService(new ConfigManagerRepository($server)));
}

function gu_server_index(array $servers, mixed $value): int
{
    $idx = filter_var($value, FILTER_VALIDATE_INT);
    if ($idx === false || !array_key_exists((int)$idx, $servers)) {
        throw new InvalidArgumentException('Ungültiger Serverindex.');
    }
    return (int)$idx;
}

function gu_csrf(): void
{
    $provided = (string)($_SERVER['HTTP_X_CSRF_TOKEN'] ?? $_POST['csrf_token'] ?? '');
    $expected = (string)($_SESSION['csrf_token'] ?? '');
    if ($expected === '' || $provided === '' || !hash_equals($expected, $provided)) {
        throw new RuntimeException('CSRF-Prüfung fehlgeschlagen.', 403);
    }
}

function gu_json_body(): array
{
    $raw = file_get_contents('php://input');
    if (!is_string($raw) || $raw === '') {
        throw new InvalidArgumentException('Leerer JSON-Body.');
    }
    if (strlen($raw) > 1024 * 1024) {
        throw new LengthException('JSON-Body ist zu gross.');
    }
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        throw new InvalidArgumentException('Ungültiger JSON-Body.');
    }
    return $data;
}

function gu_uploaded_files(string $field = 'files'): array
{
    if (!isset($_FILES[$field]) || !is_array($_FILES[$field])) {
        return [];
    }
    $f = $_FILES[$field];
    $names = is_array($f['name'] ?? null) ? $f['name'] : [$f['name'] ?? ''];
    $tmpNames = is_array($f['tmp_name'] ?? null) ? $f['tmp_name'] : [$f['tmp_name'] ?? ''];
    $types = is_array($f['type'] ?? null) ? $f['type'] : [$f['type'] ?? 'application/octet-stream'];
    $errors = is_array($f['error'] ?? null) ? $f['error'] : [$f['error'] ?? UPLOAD_ERR_NO_FILE];
    $sizes = is_array($f['size'] ?? null) ? $f['size'] : [$f['size'] ?? 0];
    $out = [];
    foreach ($names as $i => $name) {
        $error = (int)($errors[$i] ?? UPLOAD_ERR_NO_FILE);
        if ($error !== UPLOAD_ERR_OK) {
            $messages = [
                UPLOAD_ERR_INI_SIZE => 'Datei überschreitet upload_max_filesize.',
                UPLOAD_ERR_FORM_SIZE => 'Datei überschreitet die Formulargrenze.',
                UPLOAD_ERR_PARTIAL => 'Datei wurde nur teilweise übertragen.',
                UPLOAD_ERR_NO_FILE => 'Keine Datei empfangen.',
                UPLOAD_ERR_NO_TMP_DIR => 'PHP-Uploadverzeichnis fehlt.',
                UPLOAD_ERR_CANT_WRITE => 'PHP konnte die Upload-Datei nicht speichern.',
                UPLOAD_ERR_EXTENSION => 'Eine PHP-Erweiterung hat den Upload gestoppt.',
            ];
            throw new RuntimeException(($messages[$error] ?? ('Upload-Fehler ' . $error)) . ' Datei: ' . (string)$name, 413);
        }
        $tmp = (string)($tmpNames[$i] ?? '');
        if ($tmp === '' || !is_uploaded_file($tmp)) {
            throw new RuntimeException('Temporäre Upload-Datei ist ungültig: ' . (string)$name, 400);
        }
        $out[] = [
            'name' => basename((string)$name),
            'tmp_name' => $tmp,
            'type' => (string)($types[$i] ?? 'application/octet-stream'),
            'size' => (int)($sizes[$i] ?? 0),
        ];
    }
    return $out;
}


function gu_local_stage_base(): string
{
    $base = __DIR__ . '/../standalone/data/git-upload-staging';
    if (!is_dir($base) && !mkdir($base, 0700, true) && !is_dir($base)) {
        throw new RuntimeException('Lokales Upload-Staging konnte nicht angelegt werden.', 500);
    }
    @chmod($base, 0700);
    return $base;
}

function gu_local_stage_remove(string $dir): void
{
    $base = realpath(gu_local_stage_base());
    $real = realpath($dir);
    if ($base === false || $real === false || !str_starts_with($real . '/', rtrim($base, '/') . '/')) {
        return;
    }
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($real, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($it as $entry) {
        if ($entry->isLink() || $entry->isFile()) {
            @unlink($entry->getPathname());
        } elseif ($entry->isDir()) {
            @rmdir($entry->getPathname());
        }
    }
    @rmdir($real);
}

function gu_local_stage_cleanup(int $maxAge = 3600): void
{
    $base = gu_local_stage_base();
    $now = time();
    foreach (glob($base . '/*') ?: [] as $entry) {
        if (!is_dir($entry) || is_link($entry)) {
            continue;
        }
        $mtime = @filemtime($entry);
        if ($mtime !== false && ($now - $mtime) > $maxAge) {
            gu_local_stage_remove($entry);
        }
    }
}

function gu_local_stage_id(mixed $value): string
{
    $id = strtolower(trim((string)$value));
    if (!preg_match('/^[0-9a-f]{32}$/', $id)) {
        throw new InvalidArgumentException('Ungültige lokale Upload-ID.');
    }
    return $id;
}

/**
 * Read the local staging id redundantly from a dedicated request header and
 * the normal request body. Multipart parsers may drop regular POST fields
 * when limits/extensions interfere with a request; the header keeps the
 * staging control channel independent from file parsing. If both transports
 * are present they must agree.
 */
function gu_local_stage_request_id(?array $jsonPayload = null): string
{
    $candidates = [];
    $header = trim((string)($_SERVER['HTTP_X_TEKO_UPLOAD_ID'] ?? ''));
    if ($header !== '') {
        $candidates['header'] = $header;
    }
    if (array_key_exists('upload_id', $_POST) && trim((string)$_POST['upload_id']) !== '') {
        $candidates['post'] = (string)$_POST['upload_id'];
    }
    if (is_array($jsonPayload) && array_key_exists('upload_id', $jsonPayload) && trim((string)$jsonPayload['upload_id']) !== '') {
        $candidates['json'] = (string)$jsonPayload['upload_id'];
    }
    if ($candidates === []) {
        throw new InvalidArgumentException('Lokale Upload-ID fehlt im Request.');
    }

    $ids = [];
    foreach ($candidates as $source => $value) {
        $ids[$source] = gu_local_stage_id($value);
    }
    $unique = array_values(array_unique(array_values($ids)));
    if (count($unique) !== 1) {
        throw new InvalidArgumentException('Lokale Upload-ID ist zwischen Request-Header und Body widersprüchlich.');
    }
    return $unique[0];
}

function gu_local_stage_chunk_index(?array $jsonPayload = null): int
{
    $candidates = [];
    $header = trim((string)($_SERVER['HTTP_X_TEKO_CHUNK_INDEX'] ?? ''));
    if ($header !== '') {
        $candidates['header'] = $header;
    }
    if (array_key_exists('chunk_index', $_POST) && trim((string)$_POST['chunk_index']) !== '') {
        $candidates['post'] = (string)$_POST['chunk_index'];
    }
    if (is_array($jsonPayload) && array_key_exists('chunk_index', $jsonPayload) && trim((string)$jsonPayload['chunk_index']) !== '') {
        $candidates['json'] = (string)$jsonPayload['chunk_index'];
    }
    if ($candidates === []) {
        throw new InvalidArgumentException('Upload-Chunk-Nummer fehlt im Request.');
    }

    $indexes = [];
    foreach ($candidates as $source => $value) {
        if (!preg_match('/^\d{1,7}$/', trim((string)$value))) {
            throw new InvalidArgumentException('Ungültige Upload-Chunk-Nummer.');
        }
        $indexes[$source] = (int)$value;
    }
    $unique = array_values(array_unique(array_values($indexes)));
    if (count($unique) !== 1) {
        throw new InvalidArgumentException('Upload-Chunk-Nummer ist zwischen Request-Header und Body widersprüchlich.');
    }
    return $unique[0];
}

function gu_local_stage_chunk_token(): string
{
    $token = strtolower(trim((string)($_SERVER['HTTP_X_TEKO_CHUNK_TOKEN'] ?? '')));
    if (!preg_match('/^[0-9a-f]{32}$/', $token)) {
        throw new InvalidArgumentException('Upload-Chunk-Token fehlt oder ist ungültig.');
    }
    return $token;
}

function gu_local_stage_file_index(): int
{
    $raw = trim((string)($_SERVER['HTTP_X_TEKO_FILE_INDEX'] ?? ''));
    if (!preg_match('/^\d{1,6}$/', $raw)) {
        throw new InvalidArgumentException('Upload-Datei-Index fehlt oder ist ungültig.');
    }
    return (int)$raw;
}

function gu_local_stage_dir(string $id): string
{
    return gu_local_stage_base() . '/' . gu_local_stage_id($id);
}

function gu_local_stage_manifest_path(string $id): string
{
    return gu_local_stage_dir($id) . '/manifest.json';
}

function gu_local_stage_session_hash(): string
{
    return hash('sha256', session_id());
}

function gu_local_stage_write(string $id, array $manifest): void
{
    $path = gu_local_stage_manifest_path($id);
    $json = json_encode($manifest, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE | JSON_PRETTY_PRINT);
    if (!is_string($json)) {
        throw new RuntimeException('Upload-Manifest konnte nicht serialisiert werden.', 500);
    }
    $tmp = $path . '.tmp.' . bin2hex(random_bytes(4));
    if (file_put_contents($tmp, $json, LOCK_EX) === false) {
        throw new RuntimeException('Upload-Manifest konnte nicht geschrieben werden.', 500);
    }
    @chmod($tmp, 0600);
    if (!rename($tmp, $path)) {
        @unlink($tmp);
        throw new RuntimeException('Upload-Manifest konnte nicht atomar gespeichert werden.', 500);
    }
    @chmod($path, 0600);
}

function gu_local_stage_load(string $id): array
{
    $path = gu_local_stage_manifest_path($id);
    if (!is_file($path) || is_link($path)) {
        throw new RuntimeException('Lokales Upload-Staging wurde nicht gefunden oder ist abgelaufen.', 404);
    }
    $raw = file_get_contents($path);
    $data = is_string($raw) ? json_decode($raw, true) : null;
    if (!is_array($data)) {
        throw new RuntimeException('Lokales Upload-Manifest ist beschädigt.', 500);
    }
    if (!hash_equals((string)($data['session_hash'] ?? ''), gu_local_stage_session_hash())) {
        throw new RuntimeException('Lokales Upload-Staging gehört nicht zu dieser Sitzung.', 403);
    }
    return $data;
}

function gu_local_stage_relpath(mixed $value): string
{
    $path = str_replace('\\', '/', trim((string)$value));
    if ($path === '' || strlen($path) > 2048 || str_contains($path, "\0") || str_starts_with($path, '/') || preg_match('/^[A-Za-z]:\//', $path)) {
        throw new InvalidArgumentException('Ungültiger relativer Dateipfad im Verzeichnis-Upload.');
    }
    $parts = explode('/', $path);
    foreach ($parts as $part) {
        if ($part === '' || $part === '.' || $part === '..') {
            throw new InvalidArgumentException('Ungültiger relativer Dateipfad im Verzeichnis-Upload.');
        }
    }
    return implode('/', $parts);
}

$configFile = __DIR__ . '/../config/config.php';
try {
    $servers = cm_load_config_manager_servers($configFile);
} catch (Throwable $e) {
    http_response_code(500);
    exit('Config-Manager-Konfiguration konnte nicht geladen werden: ' . gu_h($e->getMessage()));
}

$portalConfig = require $configFile;
$requiredService = trim((string)($portalConfig['git_upload']['required_service'] ?? ''));
$requiredService = $requiredService !== '' ? $requiredService : 'ConfigManager';
if (function_exists('mmbb_has_service') && !mmbb_has_service($requiredService)) {
    if (isset($_GET['api']) || $_SERVER['REQUEST_METHOD'] === 'POST') {
        gu_json_out(['ok' => false, 'error' => 'Keine Berechtigung für Git Repository Upload.'], 403);
    }
    http_response_code(403);
    exit('Keine Berechtigung für Git Repository Upload.');
}

$api = trim((string)($_GET['api'] ?? ''));
if ($api !== '') {
    try {
        if ($api === 'info') {
            $idx = gu_server_index($servers, $_GET['server_idx'] ?? 0);
            $info = gu_controller($servers[$idx])->getGitUploadInfo();
            gu_json_out(['ok' => true, 'server_idx' => $idx, 'server_name' => $servers[$idx]['name'], 'info' => $info]);
        }
        if ($api === 'create_repository') {
            gu_csrf();
            $payload = gu_json_body();
            $idx = gu_server_index($servers, $payload['server_idx'] ?? 0);
            unset($payload['server_idx']);
            $result = gu_controller($servers[$idx])->createGitUploadRepository($payload, gu_actor());
            gu_json_out($result, 201);
        }
        if ($api === 'repositories') {
            $idx = gu_server_index($servers, $_GET['server_idx'] ?? 0);
            $refresh = !empty($_GET['refresh']);
            $repos = gu_controller($servers[$idx])->getGitUploadRepositories($refresh);
            gu_json_out(['ok' => true, 'repositories' => $repos]);
        }
        if ($api === 'branches') {
            $idx = gu_server_index($servers, $_GET['server_idx'] ?? 0);
            $owner = trim((string)($_GET['owner'] ?? ''));
            $repo = trim((string)($_GET['repository'] ?? ''));
            $data = gu_controller($servers[$idx])->getGitUploadBranches($owner, $repo);
            gu_json_out(['ok' => true] + $data);
        }
        if ($api === 'local_stage_begin') {
            gu_csrf();
            gu_local_stage_cleanup();
            $payload = gu_json_body();
            $idx = gu_server_index($servers, $payload['server_idx'] ?? 0);
            $expected = filter_var($payload['expected_count'] ?? null, FILTER_VALIDATE_INT);
            $totalBytes = filter_var($payload['total_bytes'] ?? null, FILTER_VALIDATE_INT);
            if ($expected === false || $expected < 1) {
                throw new InvalidArgumentException('Dateianzahl für Verzeichnis-Upload ist ungültig.');
            }
            if ($totalBytes === false || $totalBytes < 0) {
                throw new InvalidArgumentException('Gesamtgrösse für Verzeichnis-Upload ist ungültig.');
            }
            $info = gu_controller($servers[$idx])->getGitUploadInfo();
            $maxFiles = (int)($info['max_files'] ?? 0);
            $maxBytes = (int)($info['max_upload_bytes'] ?? 0);
            if ($maxFiles > 0 && $expected > $maxFiles) {
                throw new LengthException("Zu viele Dateien. Agent-Maximum: $maxFiles.");
            }
            if ($maxBytes > 0 && $totalBytes > $maxBytes) {
                throw new LengthException('Upload zu gross. Agent-Gesamtlimit wurde überschritten.');
            }
            $id = bin2hex(random_bytes(16));
            $dir = gu_local_stage_dir($id);
            if (!mkdir($dir . '/files', 0700, true) && !is_dir($dir . '/files')) {
                throw new RuntimeException('Lokales Upload-Staging konnte nicht initialisiert werden.', 500);
            }
            @chmod($dir, 0700);
            @chmod($dir . '/files', 0700);
            $manifest = [
                'schema_version' => 1,
                'id' => $id,
                'created_at' => time(),
                'session_hash' => gu_local_stage_session_hash(),
                'server_idx' => $idx,
                'actor' => gu_actor(),
                'expected_count' => $expected,
                'expected_bytes' => $totalBytes,
                'received_bytes' => 0,
                'next_chunk' => 0,
                'files' => [],
            ];
            gu_local_stage_write($id, $manifest);
            gu_json_out(['ok' => true, 'upload_id' => $id, 'expected_count' => $expected]);
        }
        if ($api === 'local_stage_chunk_prepare') {
            gu_csrf();
            $payload = gu_json_body();
            $id = gu_local_stage_request_id($payload);
            $manifest = gu_local_stage_load($id);
            $chunkIndex = gu_local_stage_chunk_index($payload);
            $expectedChunk = (int)($manifest['next_chunk'] ?? 0);
            if ($chunkIndex !== $expectedChunk) {
                throw new InvalidArgumentException(sprintf(
                    'Upload-Chunk ist nicht in der erwarteten Reihenfolge: erwartet %d, erhalten %d.',
                    $expectedChunk,
                    $chunkIndex
                ));
            }
            $planned = $payload['files'] ?? null;
            if (!is_array($planned) || count($planned) < 1 || count($planned) > 20) {
                throw new InvalidArgumentException('Upload-Chunk-Plan muss 1 bis 20 Dateien enthalten.');
            }
            $records = is_array($manifest['files'] ?? null) ? $manifest['files'] : [];
            $expectedTotal = (int)($manifest['expected_count'] ?? 0);
            if (count($records) + count($planned) > $expectedTotal) {
                throw new LengthException('Verzeichnis-Upload enthält mehr Dateien als angekündigt.');
            }
            $seen = [];
            foreach ($records as $record) {
                $seen[(string)($record['relative_path'] ?? '')] = true;
            }
            $plan = [];
            foreach ($planned as $item) {
                if (!is_array($item)) {
                    throw new InvalidArgumentException('Ungültiger Eintrag im Upload-Chunk-Plan.');
                }
                $relative = gu_local_stage_relpath($item['relative_path'] ?? '');
                if (isset($seen[$relative])) {
                    throw new InvalidArgumentException('Doppelter Dateipfad im Verzeichnis-Upload: ' . $relative);
                }
                $size = filter_var($item['size'] ?? null, FILTER_VALIDATE_INT);
                if ($size === false || $size < 0) {
                    throw new InvalidArgumentException('Ungültige Dateigrösse im Upload-Chunk-Plan.');
                }
                $name = basename(trim((string)($item['name'] ?? basename($relative))));
                if ($name === '' || strlen($name) > 255 || str_contains($name, "\0")) {
                    throw new InvalidArgumentException('Ungültiger Dateiname im Upload-Chunk-Plan.');
                }
                $plan[] = [
                    'relative_path' => $relative,
                    'name' => $name,
                    'size' => (int)$size,
                ];
                $seen[$relative] = true;
            }
            $token = bin2hex(random_bytes(16));
            $plannedBytes = array_sum(array_map(static fn(array $item): int => (int)$item['size'], $plan));
            $receivedBytes = (int)($manifest['received_bytes'] ?? 0);
            $expectedBytes = (int)($manifest['expected_bytes'] ?? 0);
            if ($receivedBytes + $plannedBytes > $expectedBytes) {
                throw new LengthException('Upload-Chunk ist grösser als die angekündigte Gesamtgrösse.');
            }
            $manifest['pending_chunk'] = [
                'index' => $chunkIndex,
                'token_hash' => hash('sha256', $token),
                'prepared_at' => time(),
                'next_file' => 0,
                'files' => $plan,
            ];
            gu_local_stage_write($id, $manifest);
            gu_json_out([
                'ok' => true,
                'upload_id' => $id,
                'chunk_index' => $chunkIndex,
                'chunk_token' => $token,
                'expected_files' => count($plan),
            ]);
        }
        if ($api === 'local_stage_file') {
            gu_csrf();
            $id = gu_local_stage_request_id();
            $manifest = gu_local_stage_load($id);
            $chunkIndex = gu_local_stage_chunk_index();
            $expectedChunk = (int)($manifest['next_chunk'] ?? 0);
            if ($chunkIndex !== $expectedChunk) {
                throw new InvalidArgumentException(sprintf(
                    'Upload-Chunk ist nicht in der erwarteten Reihenfolge: erwartet %d, erhalten %d.',
                    $expectedChunk,
                    $chunkIndex
                ));
            }
            $pending = $manifest['pending_chunk'] ?? null;
            if (!is_array($pending) || (int)($pending['index'] ?? -1) !== $chunkIndex) {
                throw new InvalidArgumentException('Upload-Chunk wurde nicht vorbereitet oder ist abgelaufen.');
            }
            if ((int)($pending['prepared_at'] ?? 0) < time() - 900) {
                throw new RuntimeException('Vorbereiteter Upload-Chunk ist abgelaufen. Bitte Upload erneut starten.', 409);
            }
            $token = gu_local_stage_chunk_token();
            if (!hash_equals((string)($pending['token_hash'] ?? ''), hash('sha256', $token))) {
                throw new RuntimeException('Upload-Chunk-Token ist ungültig.', 403);
            }
            $fileIndex = gu_local_stage_file_index();
            $expectedFileIndex = (int)($pending['next_file'] ?? 0);
            if ($fileIndex !== $expectedFileIndex) {
                throw new InvalidArgumentException(sprintf(
                    'Upload-Datei ist nicht in der erwarteten Reihenfolge: erwartet %d, erhalten %d.',
                    $expectedFileIndex,
                    $fileIndex
                ));
            }
            $plan = is_array($pending['files'] ?? null) ? $pending['files'] : [];
            $plannedFile = $plan[$fileIndex] ?? null;
            if (!is_array($plannedFile)) {
                throw new InvalidArgumentException('Upload-Datei ist nicht Bestandteil des vorbereiteten Chunks.');
            }

            $expectedSize = (int)($plannedFile['size'] ?? -1);
            if ($expectedSize < 0) {
                throw new RuntimeException('Vorbereitete Dateigrösse fehlt.', 500);
            }
            $contentLength = trim((string)($_SERVER['CONTENT_LENGTH'] ?? ''));
            if ($contentLength !== '' && ctype_digit($contentLength) && (int)$contentLength !== $expectedSize) {
                throw new LengthException(sprintf(
                    'Upload-Dateigrösse stimmt nicht: erwartet %d Byte, Request enthält %d Byte.',
                    $expectedSize,
                    (int)$contentLength
                ));
            }

            $records = is_array($manifest['files'] ?? null) ? $manifest['files'] : [];
            $expectedTotal = (int)($manifest['expected_count'] ?? 0);
            if (count($records) + 1 > $expectedTotal) {
                throw new LengthException('Verzeichnis-Upload enthält mehr Dateien als angekündigt.');
            }
            $dir = gu_local_stage_dir($id);
            $recordIndex = count($records);
            $dest = sprintf('%s/files/%06d.bin', $dir, $recordIndex);
            $part = $dest . '.part';
            $input = fopen('php://input', 'rb');
            if ($input === false) {
                throw new RuntimeException('Upload-Datenstrom konnte nicht geöffnet werden.', 500);
            }
            $output = @fopen($part, 'xb');
            if ($output === false) {
                fclose($input);
                throw new RuntimeException('Lokales Upload-Staging konnte Datei nicht anlegen.', 500);
            }
            $copied = 0;
            try {
                $limit = $expectedSize < PHP_INT_MAX ? $expectedSize + 1 : $expectedSize;
                $result = stream_copy_to_stream($input, $output, $limit);
                if ($result === false) {
                    throw new RuntimeException('Upload-Datenstrom konnte nicht gespeichert werden.', 500);
                }
                $copied = (int)$result;
            } finally {
                fclose($input);
                fclose($output);
            }
            if ($copied !== $expectedSize) {
                @unlink($part);
                throw new LengthException(sprintf(
                    'Upload-Datei unvollständig: erwartet %d Byte, empfangen %d Byte.',
                    $expectedSize,
                    $copied
                ));
            }
            if (!@rename($part, $dest)) {
                @unlink($part);
                throw new RuntimeException('Upload-Datei konnte nicht ins lokale Staging übernommen werden.', 500);
            }
            @chmod($dest, 0600);

            $receivedBytes = (int)($manifest['received_bytes'] ?? 0) + $copied;
            if ($receivedBytes > (int)($manifest['expected_bytes'] ?? PHP_INT_MAX)) {
                @unlink($dest);
                throw new LengthException('Verzeichnis-Upload ist grösser als angekündigt.');
            }
            $relative = gu_local_stage_relpath($plannedFile['relative_path'] ?? '');
            $records[] = [
                'index' => $recordIndex,
                'name' => basename((string)($plannedFile['name'] ?? ('upload-' . $recordIndex))),
                'type' => trim((string)($_SERVER['CONTENT_TYPE'] ?? 'application/octet-stream')) ?: 'application/octet-stream',
                'size' => $copied,
                'relative_path' => $relative,
            ];
            $manifest['files'] = $records;
            $manifest['received_bytes'] = $receivedBytes;
            $pending['next_file'] = $fileIndex + 1;
            $chunkComplete = $pending['next_file'] >= count($plan);
            if ($chunkComplete) {
                $manifest['next_chunk'] = $chunkIndex + 1;
                unset($manifest['pending_chunk']);
            } else {
                $manifest['pending_chunk'] = $pending;
            }
            gu_local_stage_write($id, $manifest);
            gu_json_out([
                'ok' => true,
                'upload_id' => $id,
                'chunk_index' => $chunkIndex,
                'file_index' => $fileIndex,
                'chunk_complete' => $chunkComplete,
                'next_file' => $chunkComplete ? null : $fileIndex + 1,
                'next_chunk' => (int)($manifest['next_chunk'] ?? $chunkIndex),
                'received_count' => count($records),
                'expected_count' => $expectedTotal,
                'received_bytes' => $receivedBytes,
            ]);
        }
        if ($api === 'local_stage_finalize') {
            gu_csrf();
            $payload = gu_json_body();
            $id = gu_local_stage_request_id($payload);
            $manifest = gu_local_stage_load($id);
            $idx = gu_server_index($servers, $manifest['server_idx'] ?? -1);
            $records = is_array($manifest['files'] ?? null) ? $manifest['files'] : [];
            $expected = (int)($manifest['expected_count'] ?? 0);
            if ($expected < 1 || count($records) !== $expected) {
                throw new LengthException(sprintf('Lokales Upload-Staging ist unvollständig: %d von %d Dateien vorhanden.', count($records), $expected));
            }
            $files = [];
            $paths = [];
            $dir = gu_local_stage_dir($id);
            foreach ($records as $record) {
                $index = (int)($record['index'] ?? -1);
                $tmp = sprintf('%s/files/%06d.bin', $dir, $index);
                if ($index < 0 || !is_file($tmp) || is_link($tmp)) {
                    throw new RuntimeException('Lokales Upload-Staging enthält eine fehlende Datei.', 500);
                }
                $actualSize = filesize($tmp);
                if ($actualSize === false || (int)$actualSize !== (int)($record['size'] ?? -1)) {
                    throw new RuntimeException('Lokales Upload-Staging enthält eine inkonsistente Datei.', 500);
                }
                $files[] = [
                    'name' => (string)($record['name'] ?? basename($tmp)),
                    'tmp_name' => $tmp,
                    'type' => (string)($record['type'] ?? 'application/octet-stream'),
                    'size' => (int)$actualSize,
                ];
                $paths[] = gu_local_stage_relpath($record['relative_path'] ?? '');
            }
            $stripTop = filter_var($payload['strip_top_level'] ?? true, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE);
            $result = gu_controller($servers[$idx])->stageGitUpload($files, 'directory', $paths, $stripTop !== false, (string)($manifest['actor'] ?? gu_actor()), true);
            gu_local_stage_remove($dir);
            gu_json_out($result);
        }
        if ($api === 'local_stage_abort') {
            gu_csrf();
            $payload = gu_json_body();
            $id = gu_local_stage_request_id($payload);
            gu_local_stage_load($id);
            gu_local_stage_remove(gu_local_stage_dir($id));
            gu_json_out(['ok' => true]);
        }
        if ($api === 'stage') {
            gu_csrf();
            $idx = gu_server_index($servers, $_POST['server_idx'] ?? 0);
            $uploadType = strtolower(trim((string)($_POST['upload_type'] ?? 'directory')));
            if (!in_array($uploadType, ['directory', 'zip'], true)) {
                throw new InvalidArgumentException('Upload-Art muss directory oder zip sein.');
            }
            $files = gu_uploaded_files('files');
            $expected = filter_var($_POST['expected_count'] ?? count($files), FILTER_VALIDATE_INT);
            if ($expected === false || $expected < 1 || $expected !== count($files)) {
                $received = count($files);
                $contentLength = (int)($_SERVER['CONTENT_LENGTH'] ?? 0);
                $diag = sprintf(
                    'PHP hat nur %d von %s ausgewählten Dateien empfangen. Aktive Limits: max_file_uploads=%s, post_max_size=%s, upload_max_filesize=%s, SAPI=%s, Request=%s.',
                    $received,
                    $expected === false ? '?' : (string)$expected,
                    (string)ini_get('max_file_uploads'),
                    (string)ini_get('post_max_size'),
                    (string)ini_get('upload_max_filesize'),
                    PHP_SAPI,
                    $contentLength > 0 ? number_format($contentLength / 1024, 1, '.', "'") . ' KiB' : 'unbekannt'
                );
                throw new LengthException($diag);
            }
            $relativePaths = json_decode((string)($_POST['relative_paths'] ?? '[]'), true);
            if (!is_array($relativePaths) || count($relativePaths) !== count($files)) {
                throw new InvalidArgumentException('Relative Dateipfade fehlen oder sind unvollständig.');
            }
            $stripTop = filter_var($_POST['strip_top_level'] ?? true, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE);
            $result = gu_controller($servers[$idx])->stageGitUpload($files, $uploadType, array_values($relativePaths), $stripTop !== false, gu_actor());
            gu_json_out($result);
        }
        if ($api === 'preview') {
            gu_csrf();
            $payload = gu_json_body();
            $idx = gu_server_index($servers, $payload['server_idx'] ?? 0);
            unset($payload['server_idx']);
            $result = gu_controller($servers[$idx])->previewGitUpload($payload);
            gu_json_out($result);
        }
        if ($api === 'push') {
            gu_csrf();
            $payload = gu_json_body();
            $idx = gu_server_index($servers, $payload['server_idx'] ?? 0);
            unset($payload['server_idx']);
            $result = gu_controller($servers[$idx])->pushGitUpload($payload, gu_actor());
            gu_json_out($result);
        }
        if ($api === 'discard') {
            gu_csrf();
            $payload = gu_json_body();
            $idx = gu_server_index($servers, $payload['server_idx'] ?? 0);
            $stageId = (string)($payload['stage_id'] ?? '');
            $result = gu_controller($servers[$idx])->discardGitUploadStage($stageId);
            gu_json_out($result);
        }
        gu_json_out(['ok' => false, 'error' => 'Unbekannte API-Aktion.'], 404);
    } catch (LengthException $e) {
        gu_json_out(['ok' => false, 'error' => $e->getMessage()], 413);
    } catch (InvalidArgumentException $e) {
        gu_json_out(['ok' => false, 'error' => $e->getMessage()], 400);
    } catch (RuntimeException $e) {
        $code = $e->getCode();
        gu_json_out(['ok' => false, 'error' => $e->getMessage()], $code >= 400 && $code <= 599 ? $code : 500);
    } catch (Throwable $e) {
        $code = (int)$e->getCode();
        gu_json_out(['ok' => false, 'error' => $e->getMessage()], $code >= 400 && $code <= 599 ? $code : 500);
    }
}

$selfUrl = (string)($_SERVER['SCRIPT_NAME'] ?? 'git_upload.php');
if ($selfUrl === '' || str_contains($selfUrl, "\0")) {
    $selfUrl = 'git_upload.php';
}
$serverOptions = array_map(static fn(array $server, int $idx): array => ['idx' => $idx, 'name' => (string)$server['name']], $servers, array_keys($servers));
$phpLimits = [
    'upload_max_filesize' => (string)ini_get('upload_max_filesize'),
    'post_max_size' => (string)ini_get('post_max_size'),
    'max_file_uploads' => (int)ini_get('max_file_uploads'),
    'max_input_vars' => (int)ini_get('max_input_vars'),
    'max_execution_time' => (int)ini_get('max_execution_time'),
    'sapi' => PHP_SAPI,
];
?>
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Git Repository Upload</title>
    <?php require MMBB_UI . '/includes/css.php'; ?>
    <link rel="stylesheet" href="assets/css/configuration_workspace.css">
    <link rel="stylesheet" href="assets/css/git_upload.css">
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3 git-upload-page">
    <?php require MMBB_UI . '/module_header.php'; ?>

    <noscript><div class="alert alert-danger">Git Repository Upload benötigt JavaScript.</div></noscript>

    <div id="gitUploadMessage" class="alert d-none" role="alert"></div>

    <section class="card shadow-sm mb-3">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-git me-1"></i> Ziel und Quelle</span>
            <div class="d-flex flex-wrap gap-2">
                <button class="btn btn-outline-primary btn-sm" type="button" id="gitUploadCreateRepoToggle" title="Neues Repository direkt in Forgejo erstellen">
                    <i class="bi bi-plus-circle me-1"></i> Neues Repository
                </button>
                <button type="button" class="btn btn-outline-secondary btn-sm" id="gitUploadReload">
                    <i class="bi bi-arrow-clockwise me-1"></i> Repositorys neu laden
                </button>
            </div>
        </div>
        <div class="card-body">
            <div class="git-upload-workgroup">
                <div class="git-upload-workgroup-title">
                    <span class="git-upload-step">1</span>
                    <div><strong>Ziel</strong><small>Agent, Repository und Branch</small></div>
                </div>
                <div class="row g-3">
                    <div class="col-12 col-md-4">
                        <label class="form-label fw-semibold" for="gitUploadServer">Config Agent</label>
                        <select class="form-select form-select-sm" id="gitUploadServer">
                            <?php foreach ($serverOptions as $option): ?>
                                <option value="<?= (int)$option['idx'] ?>"><?= gu_h($option['name']) ?></option>
                            <?php endforeach; ?>
                        </select>
                    </div>
                    <div class="col-12 col-md-4">
                        <label class="form-label fw-semibold" for="gitUploadRepository">Forgejo-Repository</label>
                        <select class="form-select form-select-sm" id="gitUploadRepository" disabled>
                            <option value="">Repositorys werden geladen …</option>
                        </select>
                    </div>
                    <div class="col-12 col-md-4">
                        <label class="form-label fw-semibold" for="gitUploadBranch">Branch</label>
                        <select class="form-select form-select-sm" id="gitUploadBranch" disabled>
                            <option value="">Zuerst Repository auswählen …</option>
                        </select>
                        <input class="form-control form-control-sm mt-2 d-none" id="gitUploadNewBranch" maxlength="128" spellcheck="false" autocomplete="off" placeholder="Neuer Branch, z. B. upload/postfix-1.0.2">
                    </div>
                </div>
            </div>

            <div class="git-upload-workgroup mt-3">
                <div class="git-upload-workgroup-title">
                    <span class="git-upload-step">2</span>
                    <div><strong>Inhalt & Commit</strong><small>Dateien auswählen und Übernahme festlegen</small></div>
                </div>
                <div class="row g-3">
                    <div class="col-12 col-lg-6">
                        <label class="form-label fw-semibold">Upload-Art</label>
                        <div class="git-upload-type-switch" role="group" aria-label="Upload-Art">
                            <input class="btn-check" type="radio" name="gitUploadType" id="gitUploadTypeDirectory" value="directory" checked>
                            <label class="btn btn-outline-primary btn-sm" for="gitUploadTypeDirectory"><i class="bi bi-folder2-open me-1"></i>Verzeichnis</label>
                            <input class="btn-check" type="radio" name="gitUploadType" id="gitUploadTypeZip" value="zip">
                            <label class="btn btn-outline-primary btn-sm" for="gitUploadTypeZip"><i class="bi bi-file-earmark-zip me-1"></i>ZIP</label>
                        </div>
                        <div class="mt-2" id="gitUploadDirectoryWrap">
                            <input class="form-control form-control-sm" type="file" id="gitUploadDirectory" webkitdirectory directory multiple>
                        </div>
                        <div class="mt-2 d-none" id="gitUploadZipWrap">
                            <input class="form-control form-control-sm" type="file" id="gitUploadZip" accept=".zip,application/zip">
                        </div>
                        <div class="form-text" id="gitUploadSelectionInfo">Noch kein Verzeichnis ausgewählt.</div>
                    </div>

                    <div class="col-12 col-lg-6">
                        <label class="form-label fw-semibold" for="gitUploadCommitMessage">Commit-Nachricht</label>
                        <textarea class="form-control form-control-sm" id="gitUploadCommitMessage" rows="3" maxlength="4096" placeholder="Beispiel: Update postfix_attachment auf Version 1.0.2"></textarea>
                        <div class="row g-2 mt-1">
                            <div class="col-12 col-md-7">
                                <label class="form-label small mb-1" for="gitUploadMode">Übernahmemodus</label>
                                <select class="form-select form-select-sm" id="gitUploadMode">
                                    <option value="update" selected>Aktualisieren – nichts löschen</option>
                                    <option value="mirror">Spiegeln – fehlende Repository-Dateien löschen</option>
                                </select>
                            </div>
                            <div class="col-12 col-md-5 d-flex align-items-end">
                                <div class="form-check mb-1">
                                    <input class="form-check-input" type="checkbox" id="gitUploadStripTop" checked>
                                    <label class="form-check-label" for="gitUploadStripTop">Obersten Ordner entfernen</label>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <div class="card bg-body-tertiary border mt-3 d-none" id="gitUploadCreateRepoPanel">
                <div class="card-body py-3">
                    <div class="d-flex justify-content-between align-items-center mb-2"><strong><i class="bi bi-git me-1"></i> Neues Forgejo-Repository</strong><button type="button" class="btn-close" id="gitUploadCreateRepoClose" aria-label="Schliessen"></button></div>
                    <div class="row g-2">
                        <div class="col-12 col-md-3"><label class="form-label small mb-1" for="gitUploadCreateOwner">Organisation</label><input class="form-control form-control-sm" id="gitUploadCreateOwner" value="teko" maxlength="128" autocomplete="off"></div>
                        <div class="col-12 col-md-3"><label class="form-label small mb-1" for="gitUploadCreateName">Repository-Name</label><input class="form-control form-control-sm" id="gitUploadCreateName" maxlength="128" placeholder="z. B. postfix-agent" autocomplete="off"></div>
                        <div class="col-12 col-md-4"><label class="form-label small mb-1" for="gitUploadCreateDescription">Beschreibung</label><input class="form-control form-control-sm" id="gitUploadCreateDescription" maxlength="1024" placeholder="Optionale Beschreibung"></div>
                        <div class="col-12 col-md-2"><label class="form-label small mb-1" for="gitUploadCreateDefaultBranch">Default-Branch</label><input class="form-control form-control-sm" id="gitUploadCreateDefaultBranch" value="main" maxlength="128" autocomplete="off"></div>
                    </div>
                    <div class="d-flex flex-wrap align-items-center justify-content-between gap-2 mt-3">
                        <div class="form-check"><input class="form-check-input" type="checkbox" id="gitUploadCreatePrivate" checked><label class="form-check-label" for="gitUploadCreatePrivate">Privates Repository</label></div>
                        <button type="button" class="btn btn-primary btn-sm" id="gitUploadCreateRepo"><i class="bi bi-plus-circle me-1"></i> Repository erstellen und auswählen</button>
                    </div>
                    <div class="form-text">Das Repository wird leer erstellt. Der erste Upload erzeugt den ersten Commit und den gewählten Branch.</div>
                </div>
            </div>

            <div class="git-upload-runtime mt-3">
                <div class="git-upload-runtime-main">
                    <span class="git-upload-runtime-chip"><i class="bi bi-hdd-network"></i><span>Agent</span><strong id="gitUploadAgentState">wird geprüft</strong></span>
                    <span class="git-upload-runtime-chip"><i class="bi bi-git"></i><span>Forgejo</span><strong id="gitUploadForgejoState">–</strong></span>
                    <details class="git-upload-runtime-details">
                        <summary><i class="bi bi-info-circle"></i> Technische Details</summary>
                        <div class="git-upload-runtime-detail-grid">
                            <div><span>Agent-Limit</span><strong id="gitUploadAgentLimit">–</strong></div>
                            <div><span>PHP Request</span><strong><?= gu_h($phpLimits['post_max_size']) ?></strong></div>
                            <div><span>PHP pro Datei</span><strong><?= gu_h($phpLimits['upload_max_filesize']) ?></strong></div>
                            <div><span>PHP Dateien</span><strong><?= (int)$phpLimits['max_file_uploads'] ?></strong></div>
                            <div><span>PHP SAPI</span><strong><?= gu_h($phpLimits['sapi']) ?></strong></div>
                            <div><span>Verzeichnis-Upload</span><strong>Binärstream je Datei</strong></div>
                        </div>
                    </details>
                </div>
            </div>

            <div class="d-flex flex-wrap gap-2 mt-3">
                <button type="button" class="btn btn-primary btn-sm" id="gitUploadPreview" disabled>
                    <i class="bi bi-search me-1"></i> Hochladen und prüfen
                </button>
                <button type="button" class="btn btn-success btn-sm" id="gitUploadPush" disabled>
                    <i class="bi bi-cloud-arrow-up me-1"></i> Commit und Push
                </button>
                <button type="button" class="btn btn-outline-danger btn-sm" id="gitUploadDiscard" disabled>
                    <i class="bi bi-trash me-1"></i> Upload verwerfen
                </button>
            </div>

            <div class="progress mt-3 d-none" id="gitUploadProgressWrap" role="progressbar" aria-label="Upload-Fortschritt" aria-valuemin="0" aria-valuemax="100">
                <div class="progress-bar" id="gitUploadProgress" style="width:0%">0%</div>
            </div>
        </div>
    </section>

    <section class="card shadow-sm mb-3">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-list-check me-1"></i> Änderungsvorschau</span>
            <span class="small text-body-secondary" id="gitUploadPreviewSummary">Noch keine Vorschau</span>
        </div>
        <div class="card-body p-0">
            <div id="gitUploadPreviewEmpty" class="text-center text-body-secondary p-5">
                <i class="bi bi-folder-check display-6 d-block mb-2"></i>
                Verzeichnis oder ZIP auswählen und „Hochladen und prüfen“ starten.
            </div>
            <div id="gitUploadWarnings" class="p-3 d-none"></div>
            <div class="table-responsive d-none" id="gitUploadChangesWrap">
                <table class="table table-sm align-middle mb-0 git-upload-changes">
                    <thead><tr><th>Status</th><th>Datei</th><th>Vorheriger Pfad</th></tr></thead>
                    <tbody id="gitUploadChangesBody"></tbody>
                </table>
            </div>
        </div>
    </section>

    <section class="card shadow-sm">
        <div class="card-header mmbb-card-header"><i class="bi bi-terminal me-1"></i> Ergebnis</div>
        <div class="card-body">
            <pre class="git-upload-result mb-0" id="gitUploadResult">Noch kein Commit ausgeführt.</pre>
        </div>
    </section>
</div>

<script>
window.GIT_UPLOAD_PAGE = <?= json_encode([
    'endpoint' => $selfUrl,
    'csrfToken' => $csrfToken,
    'servers' => $serverOptions,
    'phpLimits' => $phpLimits,
    'directoryChunkFiles' => 10,
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;
</script>
<?php require MMBB_UI . '/includes/js.php'; ?>
<script src="assets/js/git_upload.js?v=3.0.22"></script>
</body>
</html>
