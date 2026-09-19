<?php
declare(strict_types=1);

require_once __DIR__ . '/../standalone/bootstrap.php';

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

if (!isset($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

// defensiv
$csrf_token = $_SESSION['csrf_token'] ?? null;

require_once __DIR__ . '/../autoloader.php';
require_once __DIR__ . '/../Repository/ConfigManagerRepository.php';
require_once __DIR__ . '/../Service/ConfigManagerService.php';
require_once __DIR__ . '/../Controller/ConfigManagerController.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;
use ConfigManager\Controller\ConfigManagerController;

/* =========================================================
 * Helpers
 * ========================================================= */

function h(mixed $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function is_list_array(array $a): bool
{
    return array_keys($a) === range(0, count($a) - 1);
}

function html_id_slug(mixed $s): string
{
    $s = (string)$s;
    $s = preg_replace('/[^A-Za-z0-9_\-:\.]/', '_', $s) ?? '';
    if ($s === '' || ctype_digit($s[0])) {
        $s = 'id_' . $s;
    }
    return $s;
}

function action_label(string $cmd): string
{
    $labels = [
        'status' => 'Status',
        'reload' => 'Reload',
        'restart' => 'Restart',
        'start' => 'Start',
        'stop' => 'Stop',
        'journal' => 'Log',
    ];

    $key = strtolower(trim($cmd));
    return $labels[$key] ?? ucfirst($cmd);
}

function action_icon(string $cmd): string
{
    $key = strtolower(trim($cmd));
    return match ($key) {
        'status' => 'bi bi-activity',
        'reload' => 'bi bi-arrow-clockwise',
        'restart' => 'bi bi-arrow-repeat',
        'start' => 'bi bi-play-fill',
        'stop' => 'bi bi-stop-fill',
        'journal' => 'bi bi-journal-text',
        default => 'bi bi-terminal',
    };
}

function action_is_risky(string $cmd): bool
{
    return in_array(strtolower(trim($cmd)), ['restart', 'stop'], true);
}

function action_is_unsupported(string $cmd): bool
{
    return in_array(strtolower(trim($cmd)), ['stop_start'], true);
}

function config_is_service(array $config): bool
{
    return strtolower((string)($config['category'] ?? '')) === 'service'
        || trim((string)($config['service'] ?? '')) !== '';
}

function is_ajax_request(): bool
{
    return strtolower($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') === 'xmlhttprequest';
}

/**
 * Stellt sicher, dass Daten möglichst robust als UTF-8 ausgegeben werden.
 * Repariert nur defensiv und versucht mehrere Quellencodings.
 */
function ensure_utf8(mixed $data): mixed
{
    if (is_array($data)) {
        foreach ($data as $key => $value) {
            $data[$key] = ensure_utf8($value);
        }
        return $data;
    }

    if (is_string($data) && !mb_check_encoding($data, 'UTF-8')) {
        $converted = @mb_convert_encoding($data, 'UTF-8', 'UTF-8, Windows-1252, ISO-8859-1');
        return is_string($converted) ? $converted : '';
    }

    return $data;
}

/**
 * Einheitlicher JSON-Output
 */
function json_out(array $payload, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('Pragma: no-cache');
    header('Expires: 0');
    header('X-Content-Type-Options: nosniff');

    $payload = ensure_utf8($payload);

    $json = json_encode(
        $payload,
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE
    );

    if ($json === false) {
        http_response_code(500);
        echo '{"ok":false,"error":"JSON-Encoding fehlgeschlagen"}';
        exit;
    }

    echo $json;
    exit;
}

function prettyPrintJson(mixed $data): string
{
    if (is_array($data) || is_object($data)) {
        $json = json_encode(
            $data,
            JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE
        );
        return h($json === false ? 'JSON-Encoding fehlgeschlagen' : $json);
    }

    if (is_string($data)) {
        $json = json_decode($data, true);
        if (json_last_error() === JSON_ERROR_NONE && is_array($json)) {
            $pretty = json_encode(
                $json,
                JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE
            );
            return h($pretty === false ? $data : $pretty);
        }
        return h($data);
    }

    $json = json_encode(
        $data,
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE
    );

    return h($json === false ? 'null' : $json);
}


function decode_agent_response(mixed $resp): mixed
{
    if (is_string($resp)) {
        $trim = ltrim($resp);
        if ($trim !== '' && ($trim[0] === '{' || $trim[0] === '[')) {
            $decoded = json_decode($resp, true);
            if (json_last_error() === JSON_ERROR_NONE) {
                return $decoded;
            }
        }
    }

    return $resp;
}

/* =========================================================
 * Flash / State
 * ========================================================= */

$message = $_SESSION['successMessage'] ?? '';
$error   = $_SESSION['errorMessage'] ?? '';
$messageDetails = $_SESSION['successDetails'] ?? '';
$errorDetails   = $_SESSION['errorDetails'] ?? '';
unset(
    $_SESSION['successMessage'],
    $_SESSION['errorMessage'],
    $_SESSION['successDetails'],
    $_SESSION['errorDetails']
);

/* =========================================================
 * Serverliste laden
 * ========================================================= */

try {
    $serverlist = cm_load_config_manager_servers(__DIR__ . '/../config/config.php');
} catch (Throwable $e) {
    http_response_code(500);
    exit('Config-Manager-Konfiguration konnte nicht geladen werden. ' . h($e->getMessage()));
}

$server_idx = isset($_GET['server_idx']) ? (int)$_GET['server_idx'] : 0;
if (!array_key_exists($server_idx, $serverlist)) {
    $server_idx = 0;
}
$server = $serverlist[$server_idx];

// Filter aus GET
$selectedCategory = $_GET['category'] ?? '';
$serviceOnlyParam = isset($_GET['service_only']) ? (int)$_GET['service_only'] : 0;
$searchParam      = $_GET['q'] ?? '';

// Eigener Einstiegspunkt. Nicht relativ mit index.php arbeiten, sonst bricht es bei Alias/Rewrites
// wie /mgmt/config-manager/ statt /mgmt/config-manager/public/index.php.
$selfUrl = (string)($_SERVER['SCRIPT_NAME'] ?? 'index.php');
if ($selfUrl === '' || str_contains($selfUrl, "\0")) {
    $selfUrl = 'index.php';
}

/* =========================================================
 * OOP Bootstrap
 * ========================================================= */

$serverOffline = false;
$serverErrorMessage = '';

$repo = new ConfigManagerRepository($server);
$service = new ConfigManagerService($repo);
$controller = new ConfigManagerController($service);

/* =========================================================
 * Metadaten einmalig laden
 * ========================================================= */

$configs = [];
$all_backups = [];

try {
    $pageData = $controller->index($serverlist, $server_idx, $csrf_token);

    if (!is_array($pageData)) {
        throw new \RuntimeException('Ungültige Antwort vom Controller.');
    }

    $configs     = $pageData['configs'] ?? [];
    $all_backups = $pageData['all_backups'] ?? [];
    $serverlist  = $pageData['serverlist'] ?? $serverlist;
    $server_idx  = $pageData['server_idx'] ?? $server_idx;
    $csrf_token  = $pageData['csrf_token'] ?? $csrf_token;
} catch (\Throwable $e) {
    $serverOffline = true;
    $serverErrorMessage = $e->getMessage();

    $configs = [];
    $all_backups = [];

    if ($error === '') {
        $error = 'Der ausgewählte Server ist aktuell nicht verfügbar. Die Oberfläche bleibt geladen, der Server wurde als offline markiert.';
        $errorDetails = $serverErrorMessage;
    }
}

// erlaubte Config-IDs als Whitelist
$allowedConfigIds = array_values(array_filter(
    array_map(static fn($c) => (string)($c['id'] ?? ''), $configs),
    static fn($id) => $id !== ''
));

// actions → commands normalisieren. Das muss vor $displayConfigs passieren,
// damit die Tabellenansicht und die Aktionsbuttons dieselben normalisierten
// Metadaten verwenden wie die Command-Whitelist.
foreach ($configs as &$__c) {
    if (isset($__c['actions']) && is_array($__c['actions'])) {
        $__c['commands'] = is_list_array($__c['actions'])
            ? array_values(array_filter($__c['actions'], static fn($x) => !action_is_unsupported((string)$x)))
            : array_values(array_filter(array_keys($__c['actions']), static fn($x) => !action_is_unsupported((string)$x)));
    } else {
        if (isset($__c['commands']) && is_string($__c['commands'])) {
            $__c['commands'] = array_values(array_filter(array_map('trim', explode(',', $__c['commands'])), static fn($x) => !action_is_unsupported((string)$x)));
        } elseif (!isset($__c['commands']) || !is_array($__c['commands'])) {
            $__c['commands'] = [];
        }
    }
    if (isset($__c['commands']) && is_array($__c['commands'])) {
        $__c['commands'] = array_values(array_filter($__c['commands'], static fn($x) => !action_is_unsupported((string)$x)));
    }
}
unset($__c);

$displayConfigs = array_values(array_filter($configs, static function (array $config) use ($serviceOnlyParam): bool {
    if ($serviceOnlyParam === 1) {
        return config_is_service($config);
    }
    if ($serviceOnlyParam === 2) {
        return !config_is_service($config);
    }
    return true;
}));

// erlaubte Commands pro Config einmalig vorbereiten
$allowedCommandsById = [];
foreach ($configs as $c) {
    $id = (string)($c['id'] ?? '');
    if ($id === '') {
        continue;
    }

    if (isset($c['actions']) && is_array($c['actions'])) {
        $allowedCommandsById[$id] = is_list_array($c['actions'])
            ? array_values(array_filter(array_map('strtolower', array_values($c['actions'])), static fn($x) => !action_is_unsupported((string)$x)))
            : array_values(array_filter(array_map('strtolower', array_keys($c['actions'])), static fn($x) => !action_is_unsupported((string)$x)));
    } elseif (isset($c['commands']) && is_array($c['commands'])) {
        $allowedCommandsById[$id] = array_values(array_filter(array_map('strtolower', $c['commands']), static fn($x) => !action_is_unsupported((string)$x)));
    } else {
        $allowedCommandsById[$id] = [];
    }
}

/* =========================================================
 * POST Handling
 * ========================================================= */

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $currentCategory = $_POST['category'] ?? '';
    $catParam = ($currentCategory !== '') ? '&category=' . urlencode($currentCategory) : '';
    $svcParam = isset($_POST['service_only']) ? '&service_only=' . (int)$_POST['service_only'] : '';
    $qParam   = isset($_POST['q']) ? '&q=' . urlencode((string)$_POST['q']) : '';

    try {
        $sessionCsrf = $_SESSION['csrf_token'] ?? '';
        $postedCsrf  = (string)($_POST['csrf_token'] ?? '');

        if ($sessionCsrf === '' || $postedCsrf === '' || !hash_equals($sessionCsrf, $postedCsrf)) {
            throw new \Exception('CSRF-Token ungültig.');
        }

        $action = (string)($_POST['action'] ?? '');
        $config_name = (string)($_POST['config_name'] ?? '');

        // Hartes Whitelisting für alle Aktionen mit Config-ID
        if (in_array($action, ['save_config', 'restore_backup', 'config_action'], true)) {
            if ($config_name === '' || !in_array($config_name, $allowedConfigIds, true)) {
                throw new \Exception('Unbekannte Config-ID.');
            }
        }

        if ($action === 'save_config' && $config_name !== '') {
            $new_content = (string)($_POST['new_content'] ?? '');
            $old_snapshot = array_key_exists('old_content_snapshot', $_POST) ? (string)$_POST['old_content_snapshot'] : null;
            $old_md5 = isset($_POST['old_content_md5']) ? (string)$_POST['old_content_md5'] : null;
            $result = $controller->saveConfig($config_name, $new_content, $old_snapshot, $old_md5);

            if (($result['http_code'] ?? 500) !== 200) {
                throw new \Exception((string)($result['response'] ?? 'Speichern fehlgeschlagen'));
            }

            $responsePayload = json_decode((string)($result['response'] ?? ''), true);
            if (is_array($responsePayload) && !empty($responsePayload['noop'])) {
                $_SESSION['successMessage'] = (string)($responsePayload['message'] ?? 'Keine Änderung erkannt. Speichern übersprungen.');
            } else {
                $_SESSION['successMessage'] = 'Erfolgreich gespeichert!';
            }
            $_SESSION['successDetails'] = $result['response'] ?? '';
            header("Location: " . $selfUrl . "?server_idx=$server_idx{$catParam}{$svcParam}{$qParam}", true, 303);
            exit;
        }

        if ($action === 'restore_backup' && $config_name !== '') {
            $filename = basename((string)($_POST['filename'] ?? ''));
            if ($filename === '') {
                throw new \Exception('Kein Backup-File übergeben!');
            }

            $valid = $controller->getSingleBackups($config_name) ?? [];
            if (!in_array($filename, $valid, true)) {
                throw new \Exception('Ungültiges Backup-File.');
            }

            $result = $controller->restoreBackup($config_name, $filename);
            if (($result['http_code'] ?? 500) !== 200) {
                throw new \Exception((string)($result['response'] ?? 'Restore fehlgeschlagen'));
            }

            $_SESSION['successMessage'] = 'Backup erfolgreich wiederhergestellt!';
            $_SESSION['successDetails'] = $result['response'] ?? '';
            header("Location: " . $selfUrl . "?server_idx=$server_idx{$catParam}{$svcParam}{$qParam}", true, 303);
            exit;
        }

        if ($action === 'config_action' && $config_name !== '') {
            $cmd = strtolower(trim((string)($_POST['cmd'] ?? '')));
            if ($cmd === '') {
                throw new \Exception('Kein Kommando übergeben!');
            }

            $allowed = $allowedCommandsById[$config_name] ?? [];
            if ($allowed === [] || !in_array($cmd, $allowed, true)) {
                throw new \Exception('Ungültiges Kommando.');
            }

            $result = ($cmd === 'status')
                ? $controller->getServiceStatus($config_name)
                : $controller->callAction($config_name, $cmd);
            if (($result['http_code'] ?? 500) !== 200) {
                throw new \Exception((string)($result['response'] ?? 'Aktion fehlgeschlagen'));
            }

            if (is_ajax_request()) {
                json_out([
                    'ok' => true,
                    'config_name' => $config_name,
                    'cmd' => $cmd,
                    'http_code' => (int)($result['http_code'] ?? 200),
                    'response' => decode_agent_response($result['response'] ?? ''),
                ]);
            }

            $_SESSION['successMessage'] = "Aktion ausgeführt: $cmd";
            $_SESSION['successDetails'] = $result['response'] ?? '';
            header("Location: " . $selfUrl . "?server_idx=$server_idx{$catParam}{$svcParam}{$qParam}", true, 303);
            exit;
        }

        throw new \Exception('Ungültige Aktion oder fehlende Parameter.');
    } catch (\Exception $e) {
        $debug = filter_var($_ENV['APP_DEBUG'] ?? getenv('APP_DEBUG'), FILTER_VALIDATE_BOOL);
        $remoteAddr = $_SERVER['REMOTE_ADDR'] ?? '';
        $isLocal = in_array($remoteAddr, ['127.0.0.1', '::1'], true);
        $details = ($debug && $isLocal)
            ? ('Code: ' . $e->getCode() . "\n" . $e->getTraceAsString())
            : '';

        if (is_ajax_request()) {
            json_out([
                'ok' => false,
                'error' => $e->getMessage(),
                'details' => $details,
            ], 200);
        }

        $_SESSION['errorMessage'] = $e->getMessage();
        $_SESSION['errorDetails'] = $details;

        header("Location: " . $selfUrl . "?server_idx=$server_idx{$catParam}{$svcParam}{$qParam}", true, 303);
        exit;
    }
}

/* =========================================================
 * GET Sonderfälle / AJAX
 * ========================================================= */

$editConfigContent = '';
$editConfigId = '';

if (
    $_SERVER['REQUEST_METHOD'] === 'GET'
    && ($_GET['action'] ?? '') === 'edit'
    && isset($_GET['config_name'])
) {
    $editConfigId = (string)$_GET['config_name'];
    if (!in_array($editConfigId, $allowedConfigIds, true)) {
        http_response_code(404);
        exit('Config nicht gefunden');
    }

    $editConfigContent = (string)$controller->getConfigContent($editConfigId);
}

// Backup-Inhalt
if (
    $_SERVER['REQUEST_METHOD'] === 'GET'
    && ($_GET['action'] ?? '') === 'view_backup_content'
    && isset($_GET['config_name'], $_GET['filename'])
) {
    if (!is_ajax_request() || (($_GET['partial'] ?? '') !== '1')) {
        json_out(['ok' => false, 'error' => 'Ungültiger Request'], 400);
    }

    $viewBackupConfig   = (string)$_GET['config_name'];
    $viewBackupFilename = basename((string)$_GET['filename']);

    if (!in_array($viewBackupConfig, $allowedConfigIds, true)) {
        json_out(['ok' => false, 'error' => 'Unbekannte Config-ID'], 404);
    }

    if ($viewBackupFilename === '') {
        json_out(['ok' => false, 'error' => 'Kein Backup-File übergeben'], 400);
    }

    $valid = $controller->getSingleBackups($viewBackupConfig) ?? [];
    if (!in_array($viewBackupFilename, $valid, true)) {
        json_out(['ok' => false, 'error' => 'Backup nicht gefunden'], 404);
    }

    $viewBackupContent = $controller->viewBackupContent($viewBackupConfig, $viewBackupFilename);

    json_out([
        'ok'       => true,
        'filename' => $viewBackupFilename,
        'content'  => $viewBackupContent,
    ]);
}

// Live-Content
if (
    $_SERVER['REQUEST_METHOD'] === 'GET'
    && ($_GET['action'] ?? '') === 'view_live_content'
    && isset($_GET['config_name'])
) {
    if (!is_ajax_request() || (($_GET['partial'] ?? '') !== '1')) {
        json_out(['ok' => false, 'error' => 'Ungültiger Request'], 400);
    }

    $cfg = (string)$_GET['config_name'];
    if (!in_array($cfg, $allowedConfigIds, true)) {
        json_out(['ok' => false, 'error' => 'Unbekannte Config-ID'], 404);
    }

    $liveContent = $controller->getConfigContent($cfg);

    json_out([
        'ok'          => true,
        'config_name' => $cfg,
        'content'     => $liveContent,
    ]);
}

// Einzel-Status
if (
    $_SERVER['REQUEST_METHOD'] === 'GET'
    && ($_GET['action'] ?? '') === 'get_status'
    && isset($_GET['config_name'])
) {
    if (!is_ajax_request()) {
        json_out(['ok' => false, 'error' => 'Ungültiger Request'], 400);
    }

    $cfgId = (string)$_GET['config_name'];
    if (!in_array($cfgId, $allowedConfigIds, true)) {
        json_out(['ok' => false, 'error' => 'Unbekannte Config-ID'], 404);
    }

    $result = $controller->getServiceStatus($cfgId);

    if (!is_array($result) || ($result['http_code'] ?? 500) !== 200) {
        $err = is_array($result) ? ($result['response'] ?? 'Status fehlgeschlagen') : 'Status fehlgeschlagen';
        json_out(['ok' => false, 'error' => $err], 502);
    }

    $resp = $result['response'] ?? '';
    if (is_string($resp)) {
        $trim = ltrim($resp);
        if ($trim !== '' && ($trim[0] === '{' || $trim[0] === '[')) {
            $decoded = json_decode($resp, true);
            if (json_last_error() === JSON_ERROR_NONE) {
                $resp = $decoded;
            }
        }
    }

    json_out(['ok' => true, 'response' => $resp]);
}

// Bulk-Status
if (
    $_SERVER['REQUEST_METHOD'] === 'GET'
    && ($_GET['action'] ?? '') === 'get_status_bulk'
    && isset($_GET['config_names'])
) {
    if (!is_ajax_request()) {
        json_out(['ok' => false, 'error' => 'Ungültiger Request'], 400);
    }

    $ids = [];
    if (is_array($_GET['config_names'])) {
        foreach ($_GET['config_names'] as $v) {
            foreach (explode(',', (string)$v) as $p) {
                $p = trim((string)$p);
                if ($p !== '') {
                    $ids[] = $p;
                }
            }
        }
    } else {
        foreach (explode(',', (string)$_GET['config_names']) as $p) {
            $p = trim((string)$p);
            if ($p !== '') {
                $ids[] = $p;
            }
        }
    }

    $ids = array_values(array_unique(array_map('strval', $ids)));
    $ids = array_slice($ids, 0, 200);

    $allowedSet = array_map('strval', $allowedConfigIds);
    $unknown    = array_values(array_diff($ids, $allowedSet));
    $ids        = array_values(array_intersect($ids, $allowedSet));

    if ($ids === [] && $unknown === []) {
        json_out(['ok' => false, 'error' => 'Keine gültigen IDs übergeben.'], 400);
    }

    if (session_status() === PHP_SESSION_ACTIVE) {
        session_write_close();
    }

    $USE_APCU = function_exists('apcu_fetch');
    $TTL = 15;
    $forceNoCache = isset($_GET['no_cache']) && $_GET['no_cache'] === '1';

    $out = [];

    foreach ($ids as $cfgId) {
        $cacheKey = "cm_status:{$server_idx}:{$cfgId}";
        $hit = false;

        if ($USE_APCU && !$forceNoCache) {
            $cached = apcu_fetch($cacheKey, $hit);
            if ($hit) {
                $out[$cfgId] = ['ok' => true, 'response' => $cached, 'cached' => true];
                continue;
            }
        }

        $result = $controller->getServiceStatus($cfgId);

        if (is_array($result) && ($result['http_code'] ?? 500) === 200) {
            $resp = $result['response'] ?? '';

            if (is_string($resp)) {
                $trim = ltrim($resp);
                if ($trim !== '' && ($trim[0] === '{' || $trim[0] === '[')) {
                    $decoded = json_decode($resp, true);
                    if (json_last_error() === JSON_ERROR_NONE) {
                        $resp = $decoded;
                    }
                }
            }

            $out[$cfgId] = ['ok' => true, 'response' => $resp];
            if ($USE_APCU && !$forceNoCache) {
                apcu_store($cacheKey, $resp, $TTL);
            }
        } else {
            $errorMsg = (is_array($result) && isset($result['response']))
                ? (string)$result['response']
                : 'Status fehlgeschlagen';
            $out[$cfgId] = ['ok' => false, 'error' => $errorMsg];
        }
    }

    foreach ($unknown as $bad) {
        $out[$bad] = ['ok' => false, 'error' => 'Unbekannte Config-ID'];
    }

    json_out(['ok' => true, 'data' => $out]);
}

?>
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <title>Services &amp; Configs – Config Manager</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
 <?php require MMBB_UI . '/includes/css.php'; ?>
  <link rel="stylesheet" href="assets/css/index.css?v=3.10.15">
<script>
    window.CM_INDEX_URL = <?= json_encode($selfUrl, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;
  </script>
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3">
    <?php require MMBB_UI . '/module_header.php'; ?>

  <!-- Alerts -->
  <?php if ($message): ?>
    <div class="alert alert-success alert-dismissible fade show d-flex align-items-center" id="successMessage" role="alert">
      <i class="bi bi-check-circle-fill me-2"></i>
      <div><?= h($message) ?>
        <?php if ($messageDetails): ?>
          <button class="btn btn-sm btn-link p-0 ms-2 mmbb-btn" type="button" data-bs-toggle="collapse" data-bs-target="#successDetails">Details</button>
          <div class="collapse mt-2" id="successDetails">
            <pre class="small bg-light border rounded p-2"><?= prettyPrintJson($messageDetails) ?></pre>
          </div>
        <?php endif; ?>
      </div>
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    </div>
  <?php endif; ?>

  <?php if ($error): ?>
    <div class="alert alert-danger alert-dismissible fade show d-flex align-items-center" id="errorMessage" role="alert">
      <i class="bi bi-x-circle-fill me-2"></i>
      <div><?= h($error) ?>
        <?php if ($errorDetails): ?>
          <button class="btn btn-sm btn-link p-0 ms-2 mmbb-btn" type="button" data-bs-toggle="collapse" data-bs-target="#errorDetails">Details</button>
          <div class="collapse mt-2" id="errorDetails">
            <pre class="small bg-light border rounded p-2"><?= prettyPrintJson($errorDetails) ?></pre>
          </div>
        <?php endif; ?>
      </div>
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    </div>
  <?php endif; ?>

  <!-- Server / Filter -->
  <div class="card shadow-sm mb-3">
    <div class="card-header mmbb-card-header">
      <div class="d-flex flex-wrap align-items-center gap-2">
        <div class="d-flex align-items-center me-auto gap-2">
          <i class="bi bi-hdd-network"></i>
          <span>Server &amp; Filter</span>
          <?php
            $activeServerLabel = $server['name'] ?? ($server['host'] ?? ("Server #{$server_idx}"));
            $activeServerTitle = [];
            if (!empty($server['host'])) {
                $activeServerTitle[] = "Host: {$server['host']}";
            }
            if (!empty($server['user'])) {
                $activeServerTitle[] = "User: {$server['user']}";
            }
            if ($serverOffline && $serverErrorMessage !== '') {
                $activeServerTitle[] = "Fehler: {$serverErrorMessage}";
            }
            $activeServerTitle = implode(' · ', $activeServerTitle);
          ?>
          <span class="badge rounded-pill <?= $serverOffline ? 'text-bg-danger' : 'text-bg-success' ?> ms-2" title="<?= h($activeServerTitle) ?>">
            <?= h($activeServerLabel) ?><?= $serverOffline ? ' (offline)' : '' ?>
          </span>
        </div>
      </div>
    </div>

    <div class="card-body">
      <?php if ($serverOffline): ?>
        <div class="alert alert-warning py-2 mb-3">
          <i class="bi bi-wifi-off me-2"></i>
          Server aktuell nicht erreichbar. Die Seite bleibt geladen, aber Konfigurationen und Status konnten nicht abgefragt werden.
        </div>
      <?php endif; ?>

      <!-- Service- und Config-Status -->
      <div class="status-summary-bar d-flex flex-wrap align-items-center gap-2 mb-3">
        <span class="fw-semibold"><i class="bi bi-activity me-1"></i>Service- und Config-Status</span>
        <span class="badge rounded-pill bg-success" id="ss-ok">OK: 0</span>
        <span class="badge rounded-pill bg-warning text-dark" id="ss-warn">Warnung: 0</span>
        <span class="badge rounded-pill bg-danger" id="ss-err">Fehler: 0</span>
        <span class="badge rounded-pill bg-secondary" id="ss-unk">Unbekannt: 0</span>

        <div class="ms-auto d-flex gap-2">
          <button class="btn btn-sm btn-outline-secondary mmbb-btn mmbb-btn-secondary" id="ss-refresh">
            <i class="bi bi-arrow-clockwise"></i> Aktualisieren
          </button>
          <button class="btn btn-sm btn-outline-primary mmbb-btn" data-bs-toggle="offcanvas" data-bs-target="#statusDetailsCanvas" aria-controls="statusDetailsCanvas">
            <i class="bi bi-list-ul"></i> Details
          </button>
        </div>
      </div>

      <form method="get" class="d-flex align-items-end gap-3 flex-wrap flex-md-nowrap">
        <!-- Server -->
        <div class="d-flex flex-column mmbb-filter-field mmbb-filter-field-sm">
          <label for="server_idx" class="form-label mb-1 fw-semibold">Server</label>
          <select name="server_idx" id="server_idx" class="form-select" onchange="this.form.submit()">
            <?php foreach ($serverlist as $i => $srv): ?>
              <option value="<?= (int)$i ?>"<?= $i == $server_idx ? ' selected' : '' ?>>
                <?= h($srv['name'] ?? ($srv['host'] ?? "Server #$i")) ?>
              </option>
            <?php endforeach; ?>
          </select>
        </div>

        <!-- Ansicht -->
        <div class="d-flex flex-column mmbb-filter-field mmbb-filter-field-sm">
          <label for="serviceOnlyFilter" class="form-label mb-1 fw-semibold">Ansicht</label>
          <select name="service_only" id="serviceOnlyFilter" class="form-select" onchange="this.form.submit()">
            <option value="0"<?= $serviceOnlyParam === 0 ? ' selected' : '' ?>>Alle</option>
            <option value="1"<?= $serviceOnlyParam === 1 ? ' selected' : '' ?>>Services</option>
            <option value="2"<?= $serviceOnlyParam === 2 ? ' selected' : '' ?>>Configs</option>
          </select>
        </div>

        <!-- Kategorie -->
        <div class="d-flex flex-column mmbb-filter-field mmbb-filter-field-sm">
          <label for="categoryFilter" class="form-label mb-1 fw-semibold">Kategorie</label>
          <select name="category" id="categoryFilter" class="form-select" onchange="this.form.submit()">
            <option value="">Alle Kategorien</option>
            <?php
              $categories = array_unique(array_filter(array_map(fn($c) => $c['category'] ?? '', $configs)));
              sort($categories);
              foreach ($categories as $cat):
            ?>
              <option value="<?= h($cat) ?>"<?= ($selectedCategory === $cat ? ' selected' : '') ?>>
                <?= h($cat) ?>
              </option>
            <?php endforeach; ?>
          </select>
        </div>

        <!-- Suche -->
        <div class="d-flex flex-column mmbb-filter-field mmbb-filter-field-search">
          <label for="globalSearch" class="form-label mb-1 fw-semibold">Suche</label>
          <div class="input-group">
            <span class="input-group-text"><i class="bi bi-search"></i></span>
            <input type="text" class="form-control" id="globalSearch" name="q"
                   placeholder="Suche (ID, Name, Kategorie)…"
                   value="<?= h($searchParam) ?>">
            <button class="btn btn-sm btn-outline-secondary mmbb-btn mmbb-btn-secondary mmbb-action-reset" type="button" id="btnClearSearch">Zurücksetzen</button>
          </div>
        </div>
      </form>
    </div>
  </div>

  <!-- Tabelle -->
  <div class="card shadow-sm">
    <div class="card-body">
      <table id="ordersTable" class="table table-sm table-hover w-100">
        <thead class="table-light">
          <tr>
            <th class="col-id">ID</th>
            <th>Name</th>
            <th>Kategorie</th>
            <th>Service</th>
            <th class="col-status">Status</th>
            <th class="col-actions">Aktionen</th>
          </tr>
        </thead>
        <tbody>
        <?php foreach ($displayConfigs as $config): ?>
          <?php
            $configId = (string)($config['id'] ?? '');
            $hasCommands = !empty($config['commands']);
            $isServiceConfig = config_is_service($config);
            $hasStatus = $hasCommands && in_array('status', array_map('strtolower', $config['commands']), true);
            $visibleCommands = [];
            if ($hasCommands) {
                foreach ($config['commands'] as $__cmd) {
                    $__cmdString = (string)$__cmd;
                    $__cmdLower = strtolower($__cmdString);
                    if (action_is_unsupported($__cmdString)) {
                        continue;
                    }
                    // Status hat in der Tabelle bereits eine eigene Spalte mit Refresh.
                    // In der Service-Aktionsliste waere das nur doppelter Laerm.
                    if ($isServiceConfig && $__cmdLower === 'status') {
                        continue;
                    }
                    $visibleCommands[] = $__cmdString;
                }
            }
            $cid_html = html_id_slug($configId);
          ?>
          <tr data-config-id="<?= h($configId) ?>" data-has-status="<?= $hasStatus ? 1 : 0 ?>">
            <td><span class="text-secondary">#</span> <?= h($configId) ?></td>
            <td><?= h($config['filename'] ?? '') ?></td>
            <td><span class="badge text-bg-light border category-badge"><?= h($config['category'] ?? '-') ?></span></td>
            <td><?php $serviceName = trim((string)($config['service'] ?? '')); ?><?php if ($serviceName !== ''): ?><span class="service-name"><i class="bi bi-gear-wide-connected me-1 text-secondary"></i><code><?= h($serviceName) ?></code></span><?php else: ?><span class="text-muted">—</span><?php endif; ?></td>
            <td class="status-cell">
              <?php if ($hasStatus): ?>
                <span class="status-badge placeholder">—</span>
                <button type="button" class="btn btn-link btn-sm p-0 ms-2 btn-refresh-status mmbb-btn" title="Status aktualisieren">
                  <i class="bi bi-arrow-clockwise"></i>
                </button>
              <?php else: ?>
                <span class="text-muted">-</span>
              <?php endif; ?>
            </td>
            <td class="text-center table-actions">
              <!-- Bearbeiten -->
              <a href="<?= h($selfUrl) ?>?action=edit&config_name=<?= urlencode($configId) ?>&server_idx=<?= (int)$server_idx ?>&category=<?= urlencode($selectedCategory) ?>&service_only=<?= (int)$serviceOnlyParam ?>&q=<?= urlencode($searchParam) ?>"
                 class="btn btn-outline-success btn-sm mmbb-btn mmbb-btn-success row-action-btn" title="Konfiguration bearbeiten">
                <i class="bi bi-pencil-square"></i><span>Bearbeiten</span>
              </a>

              <!-- Aktionen -->
              <?php if (!empty($visibleCommands)): ?>
              <?php
                $actionButtonText = 'Aktionen';
                $actionButtonIcon = $isServiceConfig ? 'bi bi-hdd-network' : 'bi bi-terminal';
              ?>
              <div class="btn-group dropstart ms-1">
                <button
                  class="btn btn-outline-secondary btn-sm dropdown-toggle action-menu-btn mmbb-btn mmbb-btn-secondary"
                  data-bs-toggle="dropdown"
                  aria-expanded="false"
                  title="<?= h($actionButtonText) ?>">
                  <i class="<?= h($actionButtonIcon) ?>"></i><span><?= h($actionButtonText) ?></span>
                </button>
                <ul class="dropdown-menu">
                  <?php foreach ($visibleCommands as $cmd): ?>
                    <?php
                      if (action_is_unsupported((string)$cmd)) { continue; }
                      $cmdString = (string)$cmd;
                      $cmdLabel = action_label($cmdString);
                      $cmdRisky = action_is_risky($cmdString);
                      $cmdConfirm = 'Aktion wirklich ausführen: ' . $cmdLabel . '?';
                    ?>
                    <li>
                      <form method="post" action="<?= h($selfUrl) ?>?server_idx=<?= (int)$server_idx ?>" class="px-2 m-0 config-action-form" data-config-id="<?= h($configId) ?>" data-cmd="<?= h($cmdString) ?>" data-risky="<?= $cmdRisky ? 1 : 0 ?>">
                        <input type="hidden" name="csrf_token" value="<?= h($csrf_token) ?>">
                        <input type="hidden" name="action" value="config_action">
                        <input type="hidden" name="config_name" value="<?= h($configId) ?>">
                        <input type="hidden" name="cmd" value="<?= h($cmdString) ?>">
                        <input type="hidden" name="category" value="<?= h($selectedCategory) ?>">
                        <input type="hidden" name="service_only" value="<?= (int)$serviceOnlyParam ?>">
                        <input type="hidden" name="q" value="<?= h($searchParam) ?>">

                        <button type="submit"
                                class="dropdown-item <?= $cmdRisky ? 'text-danger' : '' ?>"
                                data-confirm-action="<?= h($cmdConfirm) ?>">
                          <i class="<?= h(action_icon($cmdString)) ?> me-2"></i><?= h($cmdLabel) ?>
                        </button>
                      </form>
                    </li>
                  <?php endforeach; ?>
                </ul>
              </div>
              <?php endif; ?>

              <!-- Restore / Backups: immer sichtbar, damit die Restore-Funktion nicht
                   von der aktuellen Backup-Liste abhaengt oder in der UI verschwindet. -->
              <?php $backups = $all_backups[$configId] ?? []; ?>
              <button type="button"
                      class="btn btn-outline-warning btn-sm mmbb-btn mmbb-btn-warning restore-row-btn ms-1"
                      data-bs-toggle="modal"
                      data-bs-target="#backupModal<?= $cid_html ?>"
                      title="Backups anzeigen und Konfiguration wiederherstellen"
                      aria-label="Restore für <?= h($config['filename'] ?? $configId) ?>">
                <i class="bi bi-clock-history"></i><span>Backups / Restore</span>
              </button>
            </td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    </div>
  </div>
</div>

<!-- Edit-Modal -->
<div class="modal fade" id="editModal" tabindex="-1" data-bs-backdrop="static" data-bs-keyboard="false">
  <div class="modal-dialog modal-xl modal-dialog-scrollable">
    <div class="modal-content">
      <form id="editForm" method="post" action="<?= h($selfUrl) ?>?server_idx=<?= (int)$server_idx ?>">
        <input type="hidden" name="csrf_token" value="<?= h($csrf_token) ?>">
        <input type="hidden" name="config_name" id="modalConfigName" value="<?= h($editConfigId) ?>">
        <input type="hidden" name="action" value="save_config">
        <input type="hidden" name="category" value="<?= h($selectedCategory) ?>">
        <input type="hidden" name="service_only" value="<?= (int)$serviceOnlyParam ?>">
        <input type="hidden" name="q" value="<?= h($searchParam) ?>">

        <div class="modal-header bg-light">
          <h6 class="modal-title" id="modalTitle">Bearbeite: <?= h($editConfigId) ?></h6>
          <button type="button" class="btn-close" data-bs-dismiss="modal" id="editCloseX"></button>
        </div>
        <div class="modal-body">
          <div id="editResult" class="mb-2"></div>
          <ul class="nav nav-tabs mb-2 mmbb-content-tabs" id="editTabNav" role="tablist">
            <li class="nav-item" role="presentation">
              <button class="nav-link active" id="editor-tab" data-bs-toggle="tab" data-bs-target="#editorPane" type="button" role="tab">Editor</button>
            </li>
            <li class="nav-item" role="presentation">
              <button class="nav-link" id="diff-tab" data-bs-toggle="tab" data-bs-target="#diffPane" type="button" role="tab">Diff</button>
            </li>
          </ul>
          <div class="tab-content" id="editTabContent">
            <div class="tab-pane fade show active" id="editorPane" role="tabpanel">
              <div id="modalEditor" style="min-height: 500px; height:30vh; width:100%;"></div>
              <textarea name="new_content" id="modalTextarea" hidden><?= h($editConfigContent) ?></textarea>
              <textarea name="old_content_snapshot" id="oldContentSnapshot" hidden><?= h($editConfigContent) ?></textarea>
              <input type="hidden" name="old_content_md5" value="<?= h(md5((string)$editConfigContent)) ?>">
            </div>
            <div class="tab-pane fade" id="diffPane" role="tabpanel">
              <div id="editDiff" class="border" style="max-height: 400px; overflow:auto;"></div>
              <button type="button" class="btn btn-sm btn-outline-secondary mt-2 mmbb-btn mmbb-btn-secondary" id="refreshDiffBtn">Diff aktualisieren</button>
            </div>
          </div>
        </div>
        <div class="modal-footer">
          <button type="button" class="btn btn-secondary btn-sm mmbb-btn mmbb-btn-secondary" data-bs-dismiss="modal" id="editCloseBtn">Schliessen</button>
          <button type="submit" class="btn btn-success btn-sm mmbb-btn mmbb-btn-success mmbb-action-save" id="saveBtn">Speichern</button>
        </div>
      </form>
    </div>
  </div>
</div>

<!-- Backup-Modal pro Config -->
<?php foreach ($configs as $config):
      $cid      = (string)($config['id'] ?? '');
      $cid_html = html_id_slug($cid);
      $backups  = $all_backups[$cid] ?? []; ?>
  <div class="modal fade backup-manager-modal" id="backupModal<?= $cid_html ?>" tabindex="-1" data-bs-backdrop="static" data-bs-keyboard="false">
    <div class="modal-dialog modal-lg modal-dialog-scrollable">
      <div class="modal-content">
        <div class="modal-header">
          <div class="backup-modal-heading">
            <span class="backup-modal-icon"><i class="bi bi-clock-history"></i></span>
            <div>
              <h6 class="modal-title">Backups &amp; Restore – <?= h($config['filename'] ?? '') ?></h6>
              <div class="backup-modal-subtitle"><?= count($backups) ?> Sicherung<?= count($backups) === 1 ? '' : 'en' ?> verfügbar</div>
            </div>
          </div>
          <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
        </div>
        <div class="modal-body">
          <div class="restoreResult"></div>
          <?php if (!empty($backups)): ?>
            <div class="backup-table-shell">
              <div class="table-responsive">
              <table class="table table-hover backup-table" id="backupTable<?= $cid_html ?>">
                <thead><tr><th>Dateiname</th><th class="backup-actions-col">Aktionen</th></tr></thead>
                <tbody>
                  <?php foreach ($backups as $file): ?>
                    <tr>
                      <td>
                        <div class="backup-file-cell">
                          <span class="backup-file-icon"><i class="bi bi-file-earmark-code"></i></span>
                          <span class="backup-file-name"><?= h($file) ?></span>
                        </div>
                      </td>
                      <td class="backup-row-actions"><div class="backup-action-group">
                        <button type="button" class="btn btn-sm btn-outline-secondary btn-view-backup mmbb-btn mmbb-btn-secondary"
                                data-config-id="<?= h($cid) ?>"
                                data-view-url="<?= h($selfUrl) ?>?action=view_backup_content&config_name=<?= urlencode($cid) ?>&filename=<?= urlencode((string)$file) ?>&server_idx=<?= (int)$server_idx ?>&partial=1"
                                data-filename="<?= h($file) ?>"
                                data-target="#viewBackupModal" title="Anzeigen">
                          <i class="bi bi-eye"></i> Anzeigen
                        </button>

                        <button type="button"
                                class="btn btn-sm btn-outline-warning btn-view-backup mmbb-btn mmbb-btn-warning"
                                data-config-id="<?= h($cid) ?>"
                                data-view-url="<?= h($selfUrl) ?>?action=view_backup_content&config_name=<?= urlencode($cid) ?>&filename=<?= urlencode((string)$file) ?>&server_idx=<?= (int)$server_idx ?>&partial=1"
                                data-filename="<?= h($file) ?>"
                                data-target="#viewBackupModal"
                                data-diff="1"
                                title="Nur Änderungen">
                          <i class="bi bi-shuffle"></i> Nur Änderungen
                        </button>

                        <form class="d-inline restoreForm" method="post" action="<?= h($selfUrl) ?>?server_idx=<?= (int)$server_idx ?>">
                          <input type="hidden" name="csrf_token" value="<?= h($csrf_token) ?>">
                          <input type="hidden" name="config_name" value="<?= h($cid) ?>">
                          <input type="hidden" name="filename" value="<?= h($file) ?>">
                          <input type="hidden" name="action" value="restore_backup">
                          <input type="hidden" name="category" value="<?= h($selectedCategory) ?>">
                          <input type="hidden" name="service_only" value="<?= (int)$serviceOnlyParam ?>">
                          <input type="hidden" name="q" value="<?= h($searchParam) ?>">
                          <button type="submit" class="btn btn-sm btn-outline-success ms-1 mmbb-btn mmbb-btn-success" title="Restore">
                            <i class="bi bi-arrow-counterclockwise"></i> Wiederherstellen
                          </button>
                        </form>
                        </div></td>
                    </tr>
                  <?php endforeach; ?>
                </tbody>
              </table>
              </div>
            </div>
          <?php else: ?>
            <div class="backup-empty-state"><i class="bi bi-archive"></i><strong>Keine Backups vorhanden</strong><span>Für diese Konfiguration wurden noch keine Sicherungen erstellt.</span></div>
          <?php endif; ?>
        </div>
        <div class="modal-footer">
          <button type="button" class="btn btn-secondary btn-sm mmbb-btn mmbb-btn-secondary" data-bs-dismiss="modal">Schliessen</button>
        </div>
      </div>
    </div>
  </div>
<?php endforeach; ?>

<!-- Backup-Inhalt-Modal -->
<div class="modal fade" id="viewBackupModal" tabindex="-1">
  <div class="modal-dialog modal-xl modal-dialog-scrollable">
    <div class="modal-content border-0 shadow-lg">
      <div class="modal-header bg-light">
        <h6 class="modal-title mb-0 flex-grow-1">
          Backup-Vorschau: <span class="fw-normal ms-1" id="viewBackupModalTitle"></span>
        </h6>
        <button type="button" class="btn-close btn-close-black" data-bs-dismiss="modal" aria-label="Schliessen"></button>
      </div>

      <div class="modal-body p-0">
        <div class="p-3">
          <div class="d-flex justify-content-end gap-2 mb-2">
            <button class="btn btn-outline-secondary btn-sm mmbb-btn mmbb-btn-secondary" id="btnShowBackupDiff">
              <i class="bi bi-shuffle"></i> Nur Änderungen
            </button>
            <button class="btn btn-outline-secondary btn-sm d-none mmbb-btn mmbb-btn-secondary" id="btnShowBoth">
              <i class="bi bi-layout-split"></i> Beide anzeigen
            </button>
          </div>

          <div id="backupLiveSplit">
            <div class="row g-3">
              <div class="col-12">
                <div class="split-title text-uppercase small text-muted mb-1">Backup-Inhalt</div>
                <pre id="viewBackupContent" class="p-3 border rounded-3"></pre>
              </div>

              <div class="col-12"><hr class="my-2"></div>

              <div class="col-12">
                <div class="split-title text-uppercase small text-muted mb-1">Live-Konfiguration</div>
                <pre id="liveConfigContent" class="p-3 border rounded-3"></pre>
              </div>
            </div>
          </div>

          <div id="backupDiffBox" class="d-none">
            <div class="split-title text-uppercase small text-muted mb-1">Änderungen (Backup → Live)</div>
            <div id="backupDiffContent" class="border rounded-3 p-2"></div>
          </div>
        </div>

        <div class="alert alert-info m-4 d-none" id="viewBackupContentEmpty">
          <i class="bi bi-info-circle me-2"></i> Kein Inhalt gefunden.
        </div>
      </div>
    </div>
  </div>
</div>

<!-- Status-Details Offcanvas -->
<div class="offcanvas offcanvas-end" tabindex="-1" id="statusDetailsCanvas" aria-labelledby="statusDetailsCanvasLabel">
  <div class="offcanvas-header">
    <h5 class="offcanvas-title" id="statusDetailsCanvasLabel"><i class="bi bi-activity me-2"></i>Status-Details</h5>
    <button type="button" class="btn-close" data-bs-dismiss="offcanvas"></button>
  </div>
  <div class="offcanvas-body">
    <div class="small text-muted mb-2">Bezieht sich auf den aktuell gefilterten Tabelleninhalt.</div>
    <div id="statusDetailsList" class="list-group list-group-flush small"></div>
  </div>
</div>

<!-- Confirm Discard -->
<div class="modal fade" id="confirmCloseEditModal" tabindex="-1" aria-hidden="true" data-bs-backdrop="static" data-bs-keyboard="false">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content border-0 shadow">
      <div class="modal-header bg-warning bg-opacity-10 border-0">
        <h6 class="modal-title">
          <i class="bi bi-exclamation-triangle-fill text-warning me-2"></i>
          Ungespeicherte Änderungen
        </h6>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Abbrechen"></button>
      </div>
      <div class="modal-body">
        <p class="mb-1">Du hast Änderungen vorgenommen, die noch nicht gespeichert sind.</p>
        <small class="text-muted">Wenn du jetzt schliesst, gehen sie verloren.</small>
      </div>
      <div class="modal-footer border-0">
        <button type="button" class="btn btn-sm btn-outline-secondary mmbb-btn mmbb-btn-secondary mmbb-action-cancel" data-bs-dismiss="modal">
          Zurück zum Editor
        </button>
        <button type="button" class="btn btn-sm btn-danger mmbb-btn mmbb-btn-danger" id="confirmDiscardBtn">
          <i class="bi bi-trash me-1"></i> Änderungen verwerfen
        </button>
      </div>
    </div>
  </div>
</div>

<?php require MMBB_UI . '/includes/js.php'; ?>

<script>
(function () {
  function initDropdown(el) {
    if (bootstrap.Dropdown.getInstance(el)) return;

    new bootstrap.Dropdown(el, {
      popperConfig: (defaultCfg) => ({
        ...defaultCfg,
        strategy: 'fixed',
        modifiers: [
          ...(defaultCfg?.modifiers || []),
          { name: 'preventOverflow', options: { boundary: 'viewport', altBoundary: true } },
          { name: 'offset', options: { offset: [0, 4] } }
        ]
      })
    });
  }

  function initAll(scope) {
    (scope || document)
      .querySelectorAll('.table-actions .dropdown-toggle')
      .forEach(initDropdown);
  }

  document.addEventListener('DOMContentLoaded', function () {
    initAll(document);
  });

  if (window.jQuery) {
    jQuery(document).on('draw.dt', '#ordersTable', function () {
      initAll(this);
    });
  }
})();
</script>

<script>
if (!window.CSS || !CSS.escape) {
  window.CSS = window.CSS || {};
  CSS.escape = function(value) {
    var string = String(value);
    var length = string.length;
    var index = -1;
    var codeUnit;
    var result = '';
    var firstCodeUnit = string.charCodeAt(0);
    while (++index < length) {
      codeUnit = string.charCodeAt(index);
      if (codeUnit == 0x0000) {
        result += '\uFFFD';
        continue;
      }
      if (
        (codeUnit >= 0x0001 && codeUnit <= 0x001F) ||
        codeUnit == 0x007F ||
        (index == 0 && codeUnit >= 0x0030 && codeUnit <= 0x0039) ||
        (index == 1 && codeUnit >= 0x0030 && codeUnit <= 0x0039 && firstCodeUnit == 0x002D)
      ) {
        result += '\\' + codeUnit.toString(16) + ' ';
        continue;
      }
      if (
        codeUnit >= 0x0080 ||
        codeUnit == 0x002D ||
        codeUnit == 0x005F ||
        (codeUnit >= 0x0030 && codeUnit <= 0x0039) ||
        (codeUnit >= 0x0041 && codeUnit <= 0x005A) ||
        (codeUnit >= 0x0061 && codeUnit <= 0x007A)
      ) {
        result += string.charAt(index);
        continue;
      }
      result += '\\' + string.charAt(index);
    }
    return result;
  };
}
</script>

<script>
document.addEventListener('DOMContentLoaded', function initEditModalAce() {
  const el = document.getElementById('modalEditor');
  if (!el) return;

  if (!window.editEditor) {
    window.editEditor = ace.edit(el);
    const editor = window.editEditor;
    editor.setTheme('ace/theme/monokai');
    editor.setOptions({
      fontSize: '12px',
      tabSize: 2,
      useSoftTabs: true,
      wrap: true,
      showPrintMargin: false,
      highlightActiveLine: true,
    });

    const currentId = <?= json_encode((string)($editConfigId ?? '')) ?>;
    const initialContent = <?= json_encode((string)($editConfigContent ?? '')) ?>;

    function guessMode(name, text){
      const n = (name || '').toLowerCase();
      if (/\.(ya?ml|yml)$/i.test(n)) return 'yaml';
      if (/\.json$/i.test(n)) return 'json';
      if (/\.(ini|conf|cnf|service)$/i.test(n)) return 'ini';
      if (/\.env(\.[\w.-]+)?$/i.test(n)) return 'properties';
      if (/\.xml$/i.test(n)) return 'xml';
      if (/\.sh$/i.test(n)) return 'sh';
      const t = (text || '').trim();
      if (t.startsWith('{') || t.startsWith('[')) return 'json';
      if (/^\s*---\s*$/.test((text || '').split(/\r?\n/)[0] || '')) return 'yaml';
      return 'text';
    }

    editor.session.setMode('ace/mode/' + guessMode(currentId, initialContent));
    editor.setValue(initialContent, -1);
    el.dataset.original = initialContent;

    document.getElementById('editor-tab')?.addEventListener('shown.bs.tab', () => editor.resize());
    document.getElementById('editModal')?.addEventListener('shown.bs.modal', () => editor.resize());
    window.addEventListener('resize', () => editor.resize());
  }

  document.getElementById('editForm')?.addEventListener('submit', function (ev) {
    const ta = document.getElementById('modalTextarea');
    const old = document.getElementById('oldContentSnapshot')?.value ?? '';
    const current = window.editEditor.getValue();
    const norm = (s) => String(s).replace(/\r\n/g, '\n').replace(/\r/g, '\n');

    if (norm(current) === norm(old)) {
      ev.preventDefault();
      const box = document.getElementById('editResult');
      if (box) {
        box.innerHTML = '<div class="alert alert-info py-2 mb-2">Keine echte Änderung erkannt. Speichern wurde übersprungen.</div>';
      }
      return;
    }

    if (ta) ta.value = current;
  });
});
</script>

<script>
document.addEventListener('DOMContentLoaded', function () {
  const editEl = document.getElementById('editModal');
  if (!editEl) return;

  const editModal = bootstrap.Modal.getOrCreateInstance(editEl, { backdrop: 'static', keyboard: false });
  const getOriginal = () => (window.editEditor?.container?.dataset?.original ?? '') + '';
  let originalText = getOriginal();
  const getCurrent  = () => (window.editEditor ? window.editEditor.getValue() : getOriginal());
  const isDirty     = () => getCurrent() !== originalText;

  editEl.addEventListener('hidePrevented.bs.modal', () => {
    editEl.classList.add('modal-static');
    setTimeout(() => editEl.classList.remove('modal-static'), 200);
  });

  function askDiscard(){
    return new Promise(resolve => {
      const cEl = document.getElementById('confirmCloseEditModal');
      const cModal = bootstrap.Modal.getOrCreateInstance(cEl, { backdrop: 'static', keyboard: false });
      const btnConfirm = cEl.querySelector('#confirmDiscardBtn');

      let settled = false;
      const cleanup = () => {
        cEl.removeEventListener('hidden.bs.modal', onHidden);
        btnConfirm?.removeEventListener('click', onClickConfirm);
      };
      const onHidden = () => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(false);
      };
      const onClickConfirm = () => {
        if (settled) return;
        settled = true;
        cleanup();
        cModal.hide();
        resolve(true);
      };

      cEl.addEventListener('hidden.bs.modal', onHidden, { once:true });
      btnConfirm?.addEventListener('click', onClickConfirm, { once:true });
      cModal.show();
    });
  }

  editEl.addEventListener('hide.bs.modal', async (ev) => {
    if (editEl.dataset.forceClose === '1') {
      delete editEl.dataset.forceClose;
      return;
    }
    if (isDirty()) {
      ev.preventDefault();
      const ok = await askDiscard();
      if (ok) {
        editEl.dataset.forceClose = '1';
        editModal.hide();
      }
    }
  });

  document.getElementById('editCloseX')?.addEventListener('click', async () => {
    if (!isDirty()) {
      editEl.dataset.forceClose = '1';
      editModal.hide();
      return;
    }
    const ok = await askDiscard();
    if (ok) {
      editEl.dataset.forceClose = '1';
      editModal.hide();
    }
  });

  document.getElementById('editCloseBtn')?.addEventListener('click', async () => {
    if (!isDirty()) {
      editEl.dataset.forceClose = '1';
      editModal.hide();
      return;
    }
    const ok = await askDiscard();
    if (ok) {
      editEl.dataset.forceClose = '1';
      editModal.hide();
    }
  });

  <?php if ($editConfigId !== '') : ?>
    editModal.show();
  <?php endif; ?>
});
</script>

<script>
const STATUS_TTL_MS = 15000;
const statusMemCache = new Map();

function statusKey(cfg){ return `status:<?= (int)$server_idx ?>:${cfg}`; }
function getCachedStatus(cfg){
  const k = statusKey(cfg);
  if (statusMemCache.has(k)) return statusMemCache.get(k);
  try{
    const raw = localStorage.getItem(k);
    if(!raw) return null;
    const obj = JSON.parse(raw);
    statusMemCache.set(k,obj);
    return obj;
  }catch(e){ return null; }
}
function setCachedStatus(cfg, value){
  const k = statusKey(cfg);
  const entry = { value, ts: Date.now() };
  statusMemCache.set(k, entry);
  try{ localStorage.setItem(k, JSON.stringify(entry)); }catch(e){}
}
function isFresh(entry){ return entry && (Date.now() - entry.ts) < STATUS_TTL_MS; }
function renderStatus(cell, label, cls){
  let badge = cell.querySelector('.status-badge');
  if (!badge) {
    badge = document.createElement('span');
    badge.className='status-badge badge';
    cell.prepend(badge);
  }
  badge.className = 'status-badge badge ' + cls;
  badge.textContent = label || 'unknown';
}
function showSpinner(cell){
  let spinner = cell.querySelector('.spinner-border');
  if (!spinner) {
    spinner = document.createElement('span');
    spinner.className='spinner-border spinner-border-sm';
    spinner.setAttribute('role','status');
    spinner.setAttribute('aria-hidden','true');
    spinner.style.marginRight='6px';
    cell.prepend(spinner);
  }
  cell.querySelector('.status-badge')?.classList.add('d-none');
  return spinner;
}
function hideSpinner(cell, spinner){
  spinner?.remove();
  cell.querySelector('.status-badge')?.classList.remove('d-none');
}
function normalizeStatus(raw){
  let txt = '';
  if (raw && typeof raw === 'object') {
    if ('status' in raw) txt = String(raw.status);
    else if ('state' in raw) txt = String(raw.state);
    else if ('running' in raw) txt = raw.running ? 'running' : 'stopped';
    else if ('ok' in raw) txt = raw.ok ? 'ok' : 'error';
    else if ('code' in raw) txt = Number(raw.code) === 0 || Number(raw.code) === 200 ? 'ok' : 'error';
    else if ('exit_code' in raw) txt = Number(raw.exit_code) === 0 ? 'ok' : 'error';
    else if ('message' in raw) txt = String(raw.message);
  } else {
    txt = String(raw || '').trim();
  }
  return (txt || 'unknown');
}
function badgeForStatus(txt){
  const t = String(txt).toLowerCase();
  if (/(running|active|ok|healthy|success|up)/.test(t)) return ['bg-success', txt];
  if (/(stopped|inactive|down|failed|error|crit|critical)/.test(t)) return ['bg-danger', txt];
  if (/(degraded|warning|warn|pending|sync|busy)/.test(t)) return ['bg-warning text-dark', txt];
  return ['bg-secondary', txt || 'unknown'];
}
async function fetchBatchStatuses(ids){
  if (!ids || !ids.length) return;
  const CHUNK = 25;

  for (let i = 0; i < ids.length; i += CHUNK) {
    const slice = ids.slice(i, i + CHUNK);
    const spinners = [];

    slice.forEach(id => {
      const tr = document.querySelector(`tr[data-config-id="${CSS.escape(id)}"]`);
      if (!tr) return;
      const cell = tr.querySelector('.status-cell');
      const cached = getCachedStatus(id);
      if (!isFresh(cached)) spinners.push([cell, showSpinner(cell)]);
    });

    try {
      const url = new URL(window.CM_INDEX_URL || window.location.pathname, window.location.origin);
      url.searchParams.set('action', 'get_status_bulk');
      url.searchParams.set('server_idx', '<?= (int)$server_idx ?>');
      url.searchParams.set('config_names', slice.join(','));
      url.searchParams.set('no_cache', '1');
      url.searchParams.set('_', String(Date.now()));

      const res = await fetch(url.toString(), {
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        },
        cache: 'no-store',
        credentials: 'same-origin'
      });

      const data = res.ok ? await res.json() : null;

      if (!data || !data.ok || !data.data) {
        slice.forEach(id => {
          const tr = document.querySelector(`tr[data-config-id="${CSS.escape(id)}"]`);
          if (tr?.querySelector('.status-cell')) {
            renderStatus(tr.querySelector('.status-cell'), 'error', 'bg-danger');
          }
        });
      } else {
        Object.entries(data.data).forEach(([id, item]) => {
          const tr = document.querySelector(`tr[data-config-id="${CSS.escape(id)}"]`);
          const cell = tr?.querySelector('.status-cell');
          if (!cell) return;

          if (item.ok) {
            const raw = item.response;
            setCachedStatus(id, raw);
            const norm = normalizeStatus(raw);
            const [cls, label] = badgeForStatus(norm);
            renderStatus(cell, label, cls);
            tr.dataset.statusLoaded = '1';
          } else {
            renderStatus(cell, 'error', 'bg-danger');
          }
        });
      }
    } catch (err) {
      console.error('Batch-Status-Fehler', err);
      slice.forEach(id => {
        const tr = document.querySelector(`tr[data-config-id="${CSS.escape(id)}"]`);
        if (tr?.querySelector('.status-cell')) {
          renderStatus(tr.querySelector('.status-cell'), 'error', 'bg-danger');
        }
      });
    } finally {
      spinners.forEach(([cell, sp]) => hideSpinner(cell, sp));
    }
  }
}
</script>

<script>
document.addEventListener('submit', async function(e) {
  const form = e.target.closest('form.config-action-form');
  if (!form) return;

  e.preventDefault();

  const cfg = form.dataset.configId || form.querySelector('input[name="config_name"]')?.value || '';
  const cmd = (form.dataset.cmd || form.querySelector('input[name="cmd"]')?.value || '').toLowerCase();
  const submitter = e.submitter || form.querySelector('button[type="submit"]');
  const confirmMsg = submitter?.dataset?.confirmAction || ('Aktion wirklich ausführen: ' + cmd + '?');

  if ((form.dataset.risky === '1' || ['restart', 'stop'].includes(cmd)) && !confirm(confirmMsg)) {
    return;
  }

  const tr = form.closest('tr') || document.querySelector(`tr[data-config-id="${CSS.escape(cfg)}"]`);
  const cell = tr?.querySelector('.status-cell');
  const oldHtml = submitter ? submitter.innerHTML : '';
  const oldDisabled = submitter ? submitter.disabled : false;

  if (submitter) {
    submitter.disabled = true;
    submitter.innerHTML = '<span class="spinner-border spinner-border-sm" aria-hidden="true"></span>';
  }
  if (cell) {
    renderStatus(cell, cmd + ' …', 'bg-secondary');
  }

  try {
    const fd = new FormData(form);
    // Nicht form.action verwenden: input[name="action"] kann in Browsern
    // die native Form-Action Property überschreiben. Dann wird daraus
    // [object HTMLInputElement] und der Request landet auf einer 404 URL.
    const targetUrl = form.getAttribute('action') || (window.CM_INDEX_URL || window.location.pathname);
    const res = await fetch(targetUrl, {
      method: 'POST',
      body: fd,
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin',
      cache: 'no-store'
    });

    const raw = await res.text();
    let data = null;
    try { data = raw ? JSON.parse(raw) : null; } catch (_) { data = null; }
    if (!data) {
      const preview = raw ? (': ' + raw.substring(0, 180).replace(/\s+/g, ' ')) : '';
      throw new Error('Keine gültige JSON Antwort. HTTP ' + res.status + ' bei ' + (res.url || 'unbekannter URL') + preview);
    }
    if (!data.ok) throw new Error(data.error || 'Aktion fehlgeschlagen.');

    const k = statusKey(cfg);
    try { localStorage.removeItem(k); } catch(_) {}
    if (typeof statusMemCache?.delete === 'function') statusMemCache.delete(k);

    if (cmd === 'journal') {
      const payload = data.response || {};
      const text = String(payload.stdout || payload.log || payload.message || 'Keine Journal-Ausgabe.');
      // Reuse exactly one larger log window instead of opening a new window for
      // every journal request. This keeps repeated service checks manageable.
      const logWindowName = 'tekoConfigManagerServiceLog';
      const w = window.open('', logWindowName, 'width=1440,height=880,resizable=yes,scrollbars=yes');
      if (w) {
        try { w.opener = null; } catch (_) {}
        const title = 'Service Log' + (cfg ? ' · ' + cfg : '');
        w.document.open();
        w.document.write('<!doctype html><html><head><meta charset="utf-8"><title></title><style>html,body{margin:0;height:100%;background:#0f172a;color:#e5e7eb;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace}header{position:sticky;top:0;display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:12px 16px;background:#111827;border-bottom:1px solid #334155;font-family:system-ui,sans-serif}header strong{font-size:14px}header span{font-size:12px;color:#94a3b8}pre{box-sizing:border-box;margin:0;min-height:calc(100% - 49px);padding:16px 20px;white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px;line-height:1.48}</style></head><body><header><strong id="title"></strong><span>Dieses Fenster wird für weitere Log-Aufrufe wiederverwendet.</span></header><pre id="log"></pre></body></html>');
        w.document.title = title;
        w.document.getElementById('title').textContent = title;
        w.document.getElementById('log').textContent = text;
        w.document.close();
        w.focus();
      } else {
        alert(text);
      }
      if (tr?.dataset?.hasStatus == '1' && typeof fetchBatchStatuses === 'function') {
        window.setTimeout(() => fetchBatchStatuses([cfg]), 150);
      }
    } else if (cmd === 'status') {
      const norm = normalizeStatus(data.response || data);
      const [cls, label] = badgeForStatus(norm);
      if (cell) renderStatus(cell, label, cls);
      setCachedStatus(cfg, data.response || data);
    } else if (tr?.dataset?.hasStatus == '1' && typeof fetchBatchStatuses === 'function') {
      if (cell) renderStatus(cell, cmd + ' ok', 'bg-success');
      window.setTimeout(() => fetchBatchStatuses([cfg]), 700);
    } else if (cell) {
      renderStatus(cell, 'ok', 'bg-success');
    }
  } catch (err) {
    if (cell) renderStatus(cell, 'error', 'bg-danger');
    alert(err?.message || err || 'Aktion fehlgeschlagen.');
  } finally {
    if (submitter) {
      submitter.disabled = oldDisabled;
      submitter.innerHTML = oldHtml;
    }
  }
});
</script>

<script>
document.addEventListener('DOMContentLoaded', function() {
  const LS_CAT_KEY = 'ui.category';
  const LS_Q_KEY   = 'ui.q';

  function getUrlParam(name) {
    const val = new URL(window.location.href).searchParams.get(name);
    return val === null ? null : val;
  }
  function setLocal(key, val) { try { localStorage.setItem(key, val ?? ''); } catch(_) {} }
  function getLocal(key) { try { return localStorage.getItem(key) || ''; } catch(_) { return ''; } }

  const $cat     = $('#categoryFilter');
  const $search  = $('#globalSearch');
  const $clear   = $('#btnClearSearch');

  var table = $('#ordersTable').DataTable({
    paging: true,
    pagingType: "first_last_numbers",
    searching: true,
    lengthChange: true,
    info: true,
    order: [[2, 'asc'], [1, 'asc']],
    dom: 't<"d-flex justify-content-between align-items-center mt-2"lip>',
    pageLength: 15,
    lengthMenu: [[10, 15, 25, 50], [10, 15, 25, 50]],
    drawCallback: function () {
      var api  = this.api();
      $('#ordersTable tbody tr.group-row').remove();
      var rows = api.rows({ page: 'current', order: 'applied', search: 'applied' }).nodes();
      var last = null;

      // Gruppierung aus der tatsächlich dargestellten Zeile lesen. Dadurch bleiben
      // Kategorie-Header auch nach Sortierung/Suche exakt an der richtigen Stelle.
      $(rows).each(function () {
        var cat = ($(this).children('td').eq(2).text() || '-').trim();
        if (last !== cat) {
          var safe = $('<div>').text(cat).html();
          $(this).before('<tr class="group-row"><td colspan="6"><i class="bi bi-folder2 me-1"></i>' + safe + '</td></tr>');
          last = cat;
        }
      });

      const needFetch = [];
      $(rows).each(function(){
        const tr = this;
        if (tr.dataset && tr.dataset.hasStatus == '1') {
          const cfg  = tr.dataset.configId;
          const cell = tr.querySelector('.status-cell');
          const cached = getCachedStatus(cfg);
          if (isFresh(cached)) {
            const [cls, label] = badgeForStatus(normalizeStatus(cached.value));
            renderStatus(cell, label, cls);
            tr.dataset.statusLoaded = '1';
          } else {
            needFetch.push(cfg);
          }
        }
      });
      if (needFetch.length) fetchBatchStatuses(needFetch);
    }
  });

  function applyCategory(val){
    if (val) {
      table.column(2).search('^' + val.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$', true, false).draw();
    } else {
      table.column(2).search('').draw();
    }
  }

  (function initFiltersOnLoad(){
    const urlCat = getUrlParam('category');
    const lsCat  = getLocal(LS_CAT_KEY);
    const domCat = $cat.val() || '';
    const initialCat = (urlCat !== null) ? urlCat : (lsCat || domCat);
    if (initialCat !== undefined && initialCat !== null && $cat.val() !== initialCat) {
      $cat.val(initialCat);
    }
    if ($cat.val()) applyCategory($cat.val());

    const urlQ  = getUrlParam('q');
    const lsQ   = getLocal(LS_Q_KEY);
    const domQ  = $search.val() || '';
    const initialQ = (urlQ !== null) ? urlQ : (lsQ || domQ);
    if (typeof initialQ === 'string') {
      if ($search.val() !== initialQ) $search.val(initialQ);
      if (initialQ) table.search(initialQ).draw();
    }
  })();

  $cat.on('change', function(){
    const v = this.value || '';
    setLocal(LS_CAT_KEY, v);
    applyCategory(v);
  });

  $search.on('input', function(){
    const v = this.value || '';
    setLocal(LS_Q_KEY, v);
    table.search(v).draw();
  });

  $clear.on('click', function(){
    $search.val('');
    setLocal(LS_Q_KEY, '');
    table.search('').draw();
  });

  document.addEventListener('click', function(e){
    const btn = e.target.closest('.btn-refresh-status');
    if (!btn) return;
    const tr = btn.closest('tr');
    if (tr && tr.dataset && tr.dataset.configId) {
      const k = `status:<?= (int)$server_idx ?>:${tr.dataset.configId}`;
      localStorage.removeItem(k);
      statusMemCache.delete(k);
      fetchBatchStatuses([tr.dataset.configId]);
    }
  });

  const serverSel = document.getElementById('server_idx');
  serverSel?.addEventListener('change', function () {
    try {
      Object.keys(localStorage).forEach(k => {
        if (k.startsWith('status:')) localStorage.removeItem(k);
      });
      if (typeof statusMemCache?.clear === 'function') statusMemCache.clear();
    } catch (_) {}
  }, { capture: true });
});
</script>

<script>
function escapeHtmlDiff(unsafe){
  return unsafe
    ? unsafe
        .replace(/&/g,"&amp;")
        .replace(/</g,"&lt;")
        .replace(/>/g,"&gt;")
        .replace(/"/g,"&quot;")
        .replace(/'/g,"&#039;")
    : "";
}

function computeDiff(original, changed) {
  const norm = s => (s || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  let orig = norm(original).split("\n");
  let edit = norm(changed).split("\n");

  const LIMIT = 2000;
  const MAX_CELLS = 5e6;
  let truncated = false;

  if (orig.length > LIMIT) { orig = orig.slice(0, LIMIT); truncated = true; }
  if (edit.length > LIMIT) { edit = edit.slice(0, LIMIT); truncated = true; }

  const n = orig.length, m = edit.length;
  let ops = [];

  if ((n + 1) * (m + 1) <= MAX_CELLS) {
    const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
    for (let i = n - 1; i >= 0; i--) {
      const oi = orig[i];
      for (let j = m - 1; j >= 0; j--) {
        dp[i][j] = (oi === edit[j]) ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
      }
    }
    let i = 0, j = 0;
    while (i < n && j < m) {
      if (orig[i] === edit[j]) { ops.push(['=', orig[i], edit[j], i, j]); i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push(['-', orig[i], '', i, j]); i++; }
      else { ops.push(['+', '', edit[j], i, j]); j++; }
    }
    while (i < n) { ops.push(['-', orig[i], '', i, j]); i++; }
    while (j < m) { ops.push(['+', '', edit[j], i, j]); j++; }
  } else {
    const max = Math.max(n, m);
    for (let i = 0; i < max; i++) {
      const o = orig[i] ?? '', e = edit[i] ?? '';
      ops.push((o === e) ? ['=', o, e, i, i] : (o && e) ? ['~', o, e, i, i] : (o ? ['-', o, '', i, i] : ['+', '', e, i, i]));
    }
  }

  const rows = [];
  for (let k = 0; k < ops.length; k++) {
    const [op, o, e, i, j] = ops[k];
    if (op === '=') continue;
    if (op === '-' && k + 1 < ops.length && ops[k + 1][0] === '+') {
      const [, , e2, , j2] = ops[k + 1];
      rows.push(['~', o, e2, i, j2]);
      k++;
    } else {
      rows.push([op, o, e, i, j]);
    }
  }

  let found = rows.length > 0;
  let diffHtml = '<table class="table table-sm table-bordered"><thead><tr><th>Alt</th><th>Neu</th></tr></thead><tbody>';

  for (const [op, o, e, i, j] of rows) {
    const lnOld = `<span class="text-muted me-2">${(i + 1) || ''}</span>`;
    const lnNew = `<span class="text-muted me-2">${(j + 1) || ''}</span>`;

    if (op === '-') {
      diffHtml += `<tr>
        <td style="background:#ffd4d4">${lnOld}${escapeHtmlDiff(o)}</td>
        <td></td>
      </tr>`;
    } else if (op === '+') {
      diffHtml += `<tr>
        <td></td>
        <td style="background:#d4ffd4">${lnNew}${escapeHtmlDiff(e)}</td>
      </tr>`;
    } else {
      diffHtml += `<tr>
        <td style="background:#ffd4d4">${lnOld}${escapeHtmlDiff(o)}</td>
        <td style="background:#d4ffd4">${lnNew}${escapeHtmlDiff(e)}</td>
      </tr>`;
    }
  }

  if (truncated) {
    diffHtml += `<tr><td colspan="2" class="text-muted">… grosse Datei gekürzt (max. ${LIMIT} Zeilen pro Seite) …</td></tr>`;
  }

  diffHtml += '</tbody></table>';
  return found ? diffHtml : '<div class="text-muted">Keine Änderungen.</div>';
}

document.getElementById('editor-tab')?.addEventListener('shown.bs.tab', function () {
  if (window.editEditor && window.editEditor.resize) {
    window.editEditor.resize();
    window.editEditor.focus();
  }
});
document.getElementById('diff-tab')?.addEventListener('shown.bs.tab', function () {
  if (!window.editEditor) return;
  const original = window.editEditor.container.dataset.original || '';
  const changed  = window.editEditor.getValue();
  $('#editDiff').html(computeDiff(original, changed));
});
$('#refreshDiffBtn').on('click', function() {
  if (!window.editEditor) return;
  const original = window.editEditor.container.dataset.original || '';
  const changed  = window.editEditor.getValue();
  $('#editDiff').html(computeDiff(original, changed));
});

document.addEventListener('click', async function (e) {
  const btn = e.target.closest('.btn-view-backup');
  if (!btn) return;
  e.preventDefault();

  const url = btn.getAttribute('data-view-url');
  const cfgId = btn.getAttribute('data-config-id') || '';
  const target = document.querySelector(btn.getAttribute('data-target') || '#viewBackupModal');
  const fallbackFilename = btn.getAttribute('data-filename') || '';
  const wantDiff = btn.dataset.diff === '1';

  try {
    const res = await fetch(url, { headers: { 'X-Requested-With':'XMLHttpRequest', 'Accept':'application/json' }, cache:'no-store' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const data = await res.json();

    const filename = (data && data.filename) || fallbackFilename;
    const content  = (data && data.content)  || '';

    const preBackup = target.querySelector('#viewBackupContent');
    const preLive   = target.querySelector('#liveConfigContent');
    const info      = target.querySelector('#viewBackupContentEmpty');
    const title     = target.querySelector('#viewBackupModalTitle');

    title.textContent = filename;
    preBackup.textContent = content;

    if (!preBackup.textContent.trim()) {
      preBackup.parentElement.classList.add('d-none');
      info.classList.remove('d-none');
    } else {
      preBackup.parentElement.classList.remove('d-none');
      info.classList.add('d-none');
    }

    if (preLive) {
      preLive.textContent = 'Lade Live-Konfiguration …';
      if (cfgId) {
        const liveUrl = new URL(window.CM_INDEX_URL || window.location.pathname, window.location.origin);
        liveUrl.searchParams.set('action', 'view_live_content');
        liveUrl.searchParams.set('config_name', cfgId);
        liveUrl.searchParams.set('server_idx', '<?= (int)$server_idx ?>');
        liveUrl.searchParams.set('partial', '1');

        try {
          const liveRes  = await fetch(liveUrl.toString(), { headers: { 'X-Requested-With':'XMLHttpRequest', 'Accept':'application/json' }, cache:'no-store' });
          const liveData = liveRes.ok ? await liveRes.json() : null;
          preLive.textContent = (liveData && liveData.content) ? liveData.content : '(Keine Live-Konfiguration gefunden)';
        } catch(_) {
          preLive.textContent = '(Konnte Live-Konfiguration nicht laden)';
        }
      } else {
        preLive.textContent = '(Keine Config-ID übergeben)';
      }
    }

    target.querySelector('#backupDiffBox')?.classList.add('d-none');
    target.querySelector('#backupLiveSplit')?.classList.remove('d-none');
    target.querySelector('#btnShowBackupDiff')?.classList.remove('d-none');
    target.querySelector('#btnShowBoth')?.classList.add('d-none');

    const diffHolder = target.querySelector('#backupDiffContent');
    if (diffHolder) diffHolder.innerHTML = '';

    if (wantDiff) {
      const backupText = target.querySelector('#viewBackupContent')?.textContent || '';
      const liveText   = target.querySelector('#liveConfigContent')?.textContent || '';
      const diffHtml   = computeDiff(backupText, liveText);
      if (diffHolder) diffHolder.innerHTML = diffHtml;

      target.querySelector('#backupLiveSplit')?.classList.add('d-none');
      target.querySelector('#backupDiffBox')?.classList.remove('d-none');
      target.querySelector('#btnShowBackupDiff')?.classList.add('d-none');
      target.querySelector('#btnShowBoth')?.classList.remove('d-none');
    }

    bootstrap.Modal.getOrCreateInstance(target).show();

  } catch (err) {
    console.error('Backup konnte nicht geladen werden:', err);
    alert('Backup konnte nicht geladen werden.');
  }
});

document.addEventListener('click', function(e){
  const btnDiff = e.target.closest('#btnShowBackupDiff');
  const btnBoth = e.target.closest('#btnShowBoth');
  const modal = document.getElementById('viewBackupModal');
  if (!modal) return;

  if (btnDiff) {
    const backupText = modal.querySelector('#viewBackupContent')?.textContent || '';
    const liveText   = modal.querySelector('#liveConfigContent')?.textContent || '';
    const diffHtml   = computeDiff(backupText, liveText);
    modal.querySelector('#backupDiffContent').innerHTML = diffHtml;
    modal.querySelector('#backupLiveSplit')?.classList.add('d-none');
    modal.querySelector('#backupDiffBox')?.classList.remove('d-none');
    modal.querySelector('#btnShowBackupDiff')?.classList.add('d-none');
    modal.querySelector('#btnShowBoth')?.classList.remove('d-none');
  }

  if (btnBoth) {
    modal.querySelector('#backupDiffBox')?.classList.add('d-none');
    modal.querySelector('#backupLiveSplit')?.classList.remove('d-none');
    modal.querySelector('#btnShowBoth')?.classList.add('d-none');
    modal.querySelector('#btnShowBackupDiff')?.classList.remove('d-none');
  }
});

document.addEventListener('DOMContentLoaded', function(){
  const editModalEl = document.getElementById('editModal');
  editModalEl?.addEventListener('hidden.bs.modal', function () {
    const url = new URL(window.location);
    url.searchParams.delete('action');
    url.searchParams.delete('config_name');
    window.history.replaceState({}, '', url);
  });
  const backupModalEl = document.getElementById('viewBackupModal');
  backupModalEl?.addEventListener('hidden.bs.modal', function () {
    const url = new URL(window.location);
    url.searchParams.delete('action');
    url.searchParams.delete('config_name');
    url.searchParams.delete('filename');
    window.history.replaceState({}, '', url);
  });
});

$(document).on('shown.bs.modal', '[id^="backupModal"]', function () {
  const $table = $(this).find('table[id^="backupTable"]');
  if ($table.length && !$.fn.DataTable.isDataTable($table)) {
    $table.DataTable({
      paging: true,
      pagingType: "first_last_numbers",
      searching: true,
      lengthChange: false,
      info: false,
      order: [[0,'desc']],
      pageLength: 10,
      dom: "<'backup-dt-toolbar'f>t<'backup-dt-footer'p>",
      language: {
        search: '',
        searchPlaceholder: 'Backups durchsuchen …',
        paginate: { first: 'Erste', last: 'Letzte' },
        zeroRecords: 'Keine passenden Backups gefunden'
      }
    });
    const $search = $(this).find('.dataTables_filter input');
    $search.attr('aria-label', 'Backups durchsuchen');
  }
});
</script>

<script>
(function(){
  function esc(s){ return String(s ?? '')
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#039;'); }

  function getFilteredRows(){
    const dt = $('#ordersTable').DataTable();
    return dt.rows({search:'applied'}).nodes().toArray();
  }
  function getFilteredIds(){
    return getFilteredRows().map(tr => tr.dataset.configId).filter(Boolean);
  }

  function summarize(){
    const rows = getFilteredRows();
    let ok=0,warn=0,err=0,unk=0;
    const details = [];

    rows.forEach(tr=>{
      const id = tr.dataset.configId;
      const nameCell = tr.children[1];
      const filename = nameCell ? nameCell.textContent.trim() : '';

      const cached = getCachedStatus(id);
      let label='unknown', cls='bg-secondary', note='';
      if (isFresh(cached)) {
        const norm = normalizeStatus(cached.value);
        const res = badgeForStatus(norm);
        cls = res[0] || 'bg-secondary';
        label = res[1] || 'unknown';
        const raw = cached.value;
        if (raw && typeof raw === 'object') {
          note = String(raw.message || raw.detail || raw.info || raw.note || '');
        }
        const l = label.toLowerCase();
        if (/(running|active|ok|healthy|success|up)/.test(l)) ok++;
        else if (/(degraded|warning|warn|pending|sync|busy)/.test(l)) warn++;
        else if (/(stopped|inactive|down|failed|error|crit|critical)/.test(l)) err++;
        else unk++;
      } else {
        unk++;
      }
      details.push({ id, filename, label, cls, note });
    });

    document.getElementById('ss-ok').textContent   = 'OK: ' + ok;
    document.getElementById('ss-warn').textContent = 'Warnung: ' + warn;
    document.getElementById('ss-err').textContent  = 'Fehler: ' + err;
    document.getElementById('ss-unk').textContent  = 'Unbekannt: ' + unk;

    const list = document.getElementById('statusDetailsList');
    if (!list) return;
    list.innerHTML = '';
    if (!details.length) {
      list.innerHTML = '<div class="text-muted">Keine Einträge.</div>';
      return;
    }
    const orderRank = s => /danger/.test(s)?0:/warning/.test(s)?1:/success/.test(s)?2:3;
    details.sort((a,b)=> orderRank(a.cls) - orderRank(b.cls) || a.filename.localeCompare(b.filename));

    details.forEach(d=>{
      const item = document.createElement('div');
      item.className = 'list-group-item d-flex justify-content-between align-items-start';
      item.innerHTML = `
        <div class="ms-2 me-auto">
          <div class="fw-semibold">${esc(d.filename)} <small class="text-muted">(${esc(d.id)})</small></div>
          ${d.note ? `<div class="text-muted">${esc(d.note)}</div>` : ''}
        </div>
        <span class="badge ${d.cls} rounded-pill">${esc(d.label)}</span>
      `;
      list.appendChild(item);
    });
  }

  document.getElementById('ss-refresh')?.addEventListener('click', function(){
    const ids = getFilteredIds();
    if (!ids.length) { summarize(); return; }
    ids.forEach(id=>{
      const k = statusKey(id);
      try { localStorage.removeItem(k); } catch(_) {}
      if (typeof statusMemCache?.delete === 'function') statusMemCache.delete(k);
    });
    if (typeof fetchBatchStatuses === 'function') {
      fetchBatchStatuses(ids).then(()=> summarize());
    } else {
      summarize();
    }
  });

  $(document).on('draw.dt', '#ordersTable', function(){ summarize(); });

  document.addEventListener('DOMContentLoaded', function(){
    setTimeout(summarize, 0);
  });

  if (typeof window.fetchBatchStatuses === 'function' && !window.__wrappedFetchBatch) {
    const orig = window.fetchBatchStatuses;
    window.fetchBatchStatuses = async function(ids){
      try { return await orig(ids); }
      finally { summarize(); }
    };
    window.__wrappedFetchBatch = true;
  }
})();
</script>

</body>
</html>
