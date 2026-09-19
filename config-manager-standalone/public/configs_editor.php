<?php
declare(strict_types=1);

// public/configs_editor.php
// Config Manager Portal 3.10.5 - Arbeitsbereich mit Abstand und Master-Scroll
// Eintragsliste links, genau ein Editor rechts; JSON-Ansicht bleibt erhalten



require_once __DIR__ . '/../standalone/bootstrap.php';

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}
$csrf_token = (string)$_SESSION['csrf_token'];

$err = '';
$msg = '';
$readOnlyMode = false;

/* --------------------------------------------------------
 * Helpers
 * -------------------------------------------------------- */
function h($s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function is_list_array_strict(array $a): bool
{
    return $a === array_values($a);
}

function commands_to_tokens($v): array
{
    if (is_array($v)) {
        $out = [];
        foreach ($v as $s) {
            $s = trim((string)$s);
            if ($s !== '') {
                $out[] = $s;
            }
        }
        return $out;
    }

    if (is_string($v)) {
        $parts = explode(',', $v);
        $out = [];
        foreach ($parts as $p) {
            $p = trim($p);
            if ($p !== '') {
                $out[] = $p;
            }
        }
        return $out;
    }

    return [];
}

function json_scalar_to_str($v): string
{
    if (is_string($v)) {
        return (string)json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
    if (is_int($v) || is_float($v)) {
        return (string)$v;
    }
    if (is_bool($v)) {
        return $v ? 'true' : 'false';
    }
    if ($v === null) {
        return 'null';
    }
    return (string)json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

function json_encode_pretty_inline($data, string $indent = '  ', int $maxLine = 120, int $level = 0): string
{
    if (is_array($data)) {
        $isList = is_list_array_strict($data);

        if ($isList) {
            $allScalar = true;
            $parts = [];

            foreach ($data as $v) {
                if (is_array($v)) {
                    $allScalar = false;
                    break;
                }
                $parts[] = json_scalar_to_str($v);
            }

            if ($allScalar) {
                $inline = '[' . implode(', ', $parts) . ']';
                if (strlen($inline) <= $maxLine) {
                    return $inline;
                }
            }

            $buf = "[\n";
            foreach ($data as $v) {
                $buf .= str_repeat($indent, $level + 1)
                    . json_encode_pretty_inline($v, $indent, $maxLine, $level + 1)
                    . ",\n";
            }
            if (substr($buf, -2) === ",\n") {
                $buf = substr($buf, 0, -2) . "\n";
            }

            return $buf . str_repeat($indent, $level) . ']';
        }

        $buf = "{\n";
        foreach ($data as $k => $v) {
            $buf .= str_repeat($indent, $level + 1)
                . json_encode((string)$k, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)
                . ': '
                . json_encode_pretty_inline($v, $indent, $maxLine, $level + 1)
                . ",\n";
        }
        if (substr($buf, -2) === ",\n") {
            $buf = substr($buf, 0, -2) . "\n";
        }

        return $buf . str_repeat($indent, $level) . '}';
    }

    return json_scalar_to_str($data);
}

function append_error(string &$err, string $text): void
{
    $err = $err !== '' ? ($err . ' | ' . $text) : $text;
}

function cm_json_out(array $payload, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('Pragma: no-cache');
    header('Expires: 0');
    header('X-Content-Type-Options: nosniff');

    $json = json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    if ($json === false) {
        http_response_code(500);
        echo '{"ok":false,"error":"JSON Encoding fehlgeschlagen"}';
        exit;
    }

    echo $json;
    exit;
}

function cm_decode_agent_payload($payload)
{
    if (is_string($payload)) {
        $trim = trim($payload);
        if ($trim !== '' && ($trim[0] === '{' || $trim[0] === '[')) {
            $decoded = json_decode($trim, true);
            if (json_last_error() === JSON_ERROR_NONE) {
                return $decoded;
            }
        }
    }

    return $payload;
}

function cm_action_is_risky(string $cmd): bool
{
    return in_array(strtolower($cmd), ['restart', 'stop'], true);
}

function cm_action_is_unsupported(string $cmd): bool
{
    return in_array(strtolower(trim($cmd)), ['stop_start'], true);
}

function validate_config_id(string $id): void
{
    if (!preg_match('/^[A-Za-z0-9._-]+$/', $id)) {
        throw new InvalidArgumentException('Ungültige ID "' . $id . '". Erlaubt sind A Z a z 0 9 . _ -');
    }
}

function validate_simple_string_field(string $fieldName, $value, string $id, int $maxLen = 255): void
{
    if (!is_string($value)) {
        throw new InvalidArgumentException('Feld "' . $fieldName . '" bei ID "' . $id . '" muss ein String sein.');
    }

    if (mb_strlen($value, 'UTF-8') > $maxLen) {
        throw new InvalidArgumentException('Feld "' . $fieldName . '" bei ID "' . $id . '" ist zu lang.');
    }

    if (preg_match('/[\x00-\x08\x0B\x0C\x0E-\x1F]/', $value)) {
        throw new InvalidArgumentException('Feld "' . $fieldName . '" bei ID "' . $id . '" enthält unzulaessige Steuerzeichen.');
    }
}

function validate_mode_field(?string $mode, string $id): void
{
    if ($mode === null || $mode === '') {
        return;
    }

    if (!preg_match('/^[0-7]{3,4}$/', $mode)) {
        throw new InvalidArgumentException('Ungültiger mode bei ID "' . $id . '". Erlaubt sind 3 oder 4 oktale Stellen.');
    }
}

function validate_actions_field(array $actions, string $id): void
{
    foreach ($actions as $token => $args) {
        $token = trim((string)$token);

        if ($token === '') {
            throw new InvalidArgumentException('Leerer Action Token bei ID "' . $id . '" ist nicht erlaubt.');
        }

        if (cm_action_is_unsupported($token)) {
            continue;
        }

        if (!preg_match('/^[A-Za-z0-9._:-]+$/', $token)) {
            throw new InvalidArgumentException('Ungültiger Action Token "' . $token . '" bei ID "' . $id . '".');
        }

        if (!is_array($args)) {
            throw new InvalidArgumentException('Action Args für "' . $token . '" bei ID "' . $id . '" muessen eine Liste sein.');
        }

        foreach ($args as $idx => $arg) {
            if (!is_string($arg)) {
                throw new InvalidArgumentException('Action Arg #' . $idx . ' für "' . $token . '" bei ID "' . $id . '" muss String sein.');
            }

            if (mb_strlen($arg, 'UTF-8') > 1000) {
                throw new InvalidArgumentException('Action Arg für "' . $token . '" bei ID "' . $id . '" ist zu lang.');
            }

            if (preg_match('/[\x00-\x08\x0B\x0C\x0E-\x1F]/', $arg)) {
                throw new InvalidArgumentException('Action Arg für "' . $token . '" bei ID "' . $id . '" enthält unzulaessige Steuerzeichen.');
            }
        }
    }
}

/**
 * Normalisierung der Konfigurationen
 * Zielschema: path, category, service, user, group, mode, actions
 * actions ist eine Map token => [args...]
 */
function normalize_configs_actions(array $cfg): array
{
    $allowedOut = ['path', 'category', 'service', 'user', 'group', 'mode', 'actions'];

    foreach ($cfg as $id => &$entry) {
        if (!is_array($entry)) {
            unset($cfg[$id]);
            continue;
        }

        $src = $entry;
        $e = [];

        foreach (['path', 'category', 'service', 'user', 'group', 'mode'] as $k) {
            if (array_key_exists($k, $src)) {
                $v = trim((string)$src[$k]);
                if ($v !== '') {
                    $e[$k] = $v;
                }
            }
        }

        $actions = [];

        if (isset($src['actions']) && is_array($src['actions'])) {
            if (is_list_array_strict($src['actions'])) {
                foreach ($src['actions'] as $tok) {
                    $tok = trim((string)$tok);
                    if ($tok !== '' && !cm_action_is_unsupported($tok)) {
                        $actions[$tok] = [];
                    }
                }
            } else {
                foreach ($src['actions'] as $tok => $args) {
                    $tok = trim((string)$tok);
                    if ($tok === '' || cm_action_is_unsupported($tok)) {
                        continue;
                    }

                    $arr = [];
                    if (is_array($args)) {
                        foreach ($args as $a) {
                            $a = trim((string)$a);
                            if ($a !== '') {
                                $arr[] = $a;
                            }
                        }
                    }

                    $actions[$tok] = array_values($arr);
                }
            }
        } else {
            $tokens = isset($src['commands']) ? commands_to_tokens($src['commands']) : [];
            $cmdArgs = (isset($src['command_args']) && is_array($src['command_args'])) ? $src['command_args'] : [];

            foreach ($tokens as $t) {
                $arr = [];
                if (isset($cmdArgs[$t]) && is_array($cmdArgs[$t])) {
                    foreach ($cmdArgs[$t] as $a) {
                        $a = trim((string)$a);
                        if ($a !== '') {
                            $arr[] = $a;
                        }
                    }
                }
                if (!cm_action_is_unsupported((string)$t)) {
                    $actions[$t] = $arr;
                }
            }
        }

        $e['actions'] = [];
        foreach ($actions as $tok => $arr) {
            $tok = trim((string)$tok);
            if ($tok === '' || cm_action_is_unsupported($tok)) {
                continue;
            }
            $e['actions'][$tok] = is_array($arr) ? array_values($arr) : [];
        }

        $entry = array_intersect_key($e, array_flip($allowedOut));
    }
    unset($entry);

    return $cfg;
}

function validate_normalized_configs(array $cfg): void
{
    foreach ($cfg as $id => $entry) {
        if (!is_string($id)) {
            throw new InvalidArgumentException('Konfig ID muss String sein.');
        }

        validate_config_id($id);

        if (!is_array($entry)) {
            throw new InvalidArgumentException('Eintrag "' . $id . '" muss ein Objekt sein.');
        }

        foreach (['path', 'category', 'service', 'user', 'group'] as $field) {
            if (isset($entry[$field])) {
                validate_simple_string_field($field, $entry[$field], $id, 512);
            }
        }

        validate_mode_field($entry['mode'] ?? null, $id);

        if (!isset($entry['actions']) || !is_array($entry['actions'])) {
            throw new InvalidArgumentException('actions bei ID "' . $id . '" muss vorhanden und eine Map sein.');
        }

        validate_actions_field($entry['actions'], $id);
    }
}

require_once __DIR__ . '/../lib/config_manager_runtime.php';
require_once __DIR__ . '/../lib/desired_state.php';

function cm_load_desired_state_document_for_refs(string $configFile): array
{
    $cfg = require $configFile;
    if (!is_array($cfg)) return ['schema_version'=>1,'policies'=>[]];
    $file = trim((string)($cfg['desired_state']['file'] ?? ''));
    if ($file === '') $file = __DIR__ . '/../standalone/data/desired_state.json';
    if (!is_file($file) || is_link($file)) return ['schema_version'=>1,'policies'=>[]];
    $raw = file_get_contents($file);
    $doc = is_string($raw) ? json_decode($raw, true) : null;
    if (!is_array($doc)) {
        throw new RuntimeException('Desired-State-Datei ist ungueltig; Referenzschutz kann nicht sicher geprüft werden.');
    }
    return ds_validate_document($doc);
}

function cm_config_dependency_refs(array $doc, array $serverlist, string $serverName, string $configId): array
{
    $refs = [];
    $currentServer = null;
    foreach ($serverlist as $srv) {
        if (strcasecmp((string)($srv['name'] ?? ''), $serverName) === 0) { $currentServer = $srv; break; }
    }
    foreach ((array)($doc['policies'] ?? []) as $policyId => $policy) {
        if (!is_array($policy)) continue;
        $source = is_array($policy['source'] ?? null) ? $policy['source'] : [];
        if (($source['type'] ?? '') !== 'config_manager') continue;
        if (strcasecmp((string)($source['reference_server'] ?? ''), $serverName) === 0
            && (string)($source['source_config'] ?? '') === $configId) {
            $refs[] = ['policy'=>(string)$policyId,'role'=>'Quelle'];
        }
        $targetId = (string)($source['target_config'] ?? ($source['source_config'] ?? ''));
        if ($targetId === $configId && is_array($currentServer) && ds_server_matches($currentServer, $policy)) {
            $refs[] = ['policy'=>(string)$policyId,'role'=>'Ziel'];
        }
    }
    return $refs;
}

function cm_assert_config_ids_not_referenced(array $oldConfigs, array $newConfigs, array $doc, array $serverlist, string $serverName): void
{
    $removed = array_values(array_diff(array_keys($oldConfigs), array_keys($newConfigs)));
    $blocked = [];
    foreach ($removed as $id) {
        $refs = cm_config_dependency_refs($doc, $serverlist, $serverName, (string)$id);
        if ($refs === []) continue;
        $uses = implode(', ', array_map(static fn($r) => $r['policy'] . ' (' . $r['role'] . ')', $refs));
        $blocked[] = $id . ' → ' . $uses;
    }
    if ($blocked !== []) {
        throw new RuntimeException(
            "Config-ID kann nicht gelöscht oder umbenannt werden, solange Desired-State-Policies darauf verweisen. " .
            "Zuerst Referenzen ändern oder Policy entfernen: " . implode('; ', $blocked)
        );
    }
}

/* --------------------------------------------------------
 * Serverliste laden
 * -------------------------------------------------------- */
$serverlist_file = __DIR__ . '/../config/config.php';

try {
    $serverlist = cm_load_config_manager_servers($serverlist_file);
} catch (Throwable $e) {
    http_response_code(500);
    die('<div style="margin:2rem;font:14px/1.4 system-ui">Config-Manager-Konfiguration konnte nicht geladen werden. ' . h($e->getMessage()) . '</div>');
}

$defaultKey = array_key_first($serverlist);
$server_idx = isset($_GET['server_idx']) ? (string)$_GET['server_idx'] : (string)$defaultKey;

if (!array_key_exists($server_idx, $serverlist)) {
    $server_idx = (string)$defaultKey;
}

$server = $serverlist[$server_idx];
$serverLabel = is_array($server) ? (string)($server['name'] ?? ($server['host'] ?? ('Server ' . $server_idx))) : ('Server ' . $server_idx);

/* --------------------------------------------------------
 * Autoloader / Controller Init
 * -------------------------------------------------------- */
$controller = null;

try {
    $autoloadFile = __DIR__ . '/../autoloader.php';
    if (is_file($autoloadFile)) {
        require_once $autoloadFile;
    }

    require_once __DIR__ . '/../Repository/ConfigManagerRepository.php';
    require_once __DIR__ . '/../Service/ConfigManagerService.php';
    require_once __DIR__ . '/../Controller/ConfigManagerController.php';

    if (
        class_exists('\ConfigManager\Repository\ConfigManagerRepository')
        && class_exists('\ConfigManager\Service\ConfigManagerService')
        && class_exists('\ConfigManager\Controller\ConfigManagerController')
    ) {
        $repoClass = '\ConfigManager\Repository\ConfigManagerRepository';
        $svcClass = '\ConfigManager\Service\ConfigManagerService';
        $ctlClass = '\ConfigManager\Controller\ConfigManagerController';

        $repo = new $repoClass($server);
        $service = new $svcClass($repo);
        $controller = new $ctlClass($service);
    } else {
        throw new RuntimeException('Erforderliche Klassen für ConfigManager wurden nicht gefunden.');
    }
} catch (Throwable $e) {
    error_log('configs_editor init failed: ' . $e->getMessage());

    $readOnlyMode = true;
    $controller = new class {
        public function getRawConfigs()
        {
            return [];
        }

        public function saveRawConfigs($json)
        {
            throw new RuntimeException('Speichern ist im Read Only Modus deaktiviert.');
        }
    };

    append_error($err, 'Initialisierung nicht vollstaendig. Read Only Modus aktiv. Speichern deaktiviert.');
}

/* --------------------------------------------------------
 * Backup-API fuer managed_configs.json
 * -------------------------------------------------------- */
$cfgApiAction = trim((string)($_GET['api'] ?? ''));
if ($cfgApiAction !== '') {
    try {
        if ($readOnlyMode) {
            throw new RuntimeException('Backup-Funktionen sind im Read Only Modus nicht verfügbar.');
        }

        if ($cfgApiAction === 'managed_get') {
            $raw = $controller->getRawConfigs();
            if (is_string($raw)) {
                $decoded = json_decode($raw, true);
                if (json_last_error() === JSON_ERROR_NONE && is_array($decoded)) {
                    $raw = $decoded;
                }
            }
            if (!is_array($raw)) {
                throw new RuntimeException('managed_configs.json lieferte kein JSON-Objekt.');
            }
            $normalized = normalize_configs_actions($raw);
            validate_normalized_configs($normalized);
            cm_json_out([
                'ok' => true,
                'server_idx' => $server_idx,
                'server_name' => $serverLabel,
                'config' => $normalized,
                'content' => json_encode_pretty_inline($normalized),
                'summary' => ['entries' => count($normalized)],
            ]);
        }

        if ($cfgApiAction === 'managed_backups') {
            cm_json_out([
                'ok' => true,
                'server_idx' => $server_idx,
                'server_name' => $serverLabel ?? ('Server ' . $server_idx),
                'backups' => $controller->getManagedConfigsBackups(),
            ]);
        }

        if ($cfgApiAction === 'managed_backup_get') {
            $filename = trim((string)($_GET['filename'] ?? ''));
            if (!preg_match('/^managed_configs\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
                throw new InvalidArgumentException('Ungültiger Managed-Configs-Backupname.');
            }
            cm_json_out([
                'ok' => true,
                'server_idx' => $server_idx,
                'backup' => $controller->getManagedConfigsBackup($filename),
            ]);
        }

        cm_json_out(['ok' => false, 'error' => 'Unbekannte Backup-API-Aktion.'], 404);
    } catch (Throwable $e) {
        cm_json_out(['ok' => false, 'error' => $e->getMessage()], 502);
    }
}

/* --------------------------------------------------------
 * POST verarbeiten
 * -------------------------------------------------------- */
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $ajaxAction = isset($_POST['ajax_action']) ? (string)$_POST['ajax_action'] : '';

    try {
        if ($readOnlyMode) {
            throw new RuntimeException('Aktion ist aktuell nicht möglich, weil die Seite im Read Only Modus laeuft.');
        }

        $postedToken = isset($_POST['csrf_token']) ? (string)$_POST['csrf_token'] : '';
        if ($postedToken === '' || !hash_equals($csrf_token, $postedToken)) {
            throw new RuntimeException('CSRF Token ungültig.');
        }

        if ($ajaxAction === 'restore_managed_backup') {
            $filename = trim((string)($_POST['filename'] ?? ''));
            if (!preg_match('/^managed_configs\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
                throw new RuntimeException('Ungültiger Managed-Configs-Backupname.');
            }
            $result = $controller->restoreManagedConfigs($filename);
            cm_json_out([
                'ok' => true,
                'restored' => $filename,
                'result' => $result,
                'audit_error' => (string)($result['audit_error'] ?? ''),
            ]);
        }

        if (in_array($ajaxAction, ['validate_managed', 'save_managed'], true)) {
            $jsonContent = trim((string)($_POST['json_content'] ?? ''));
            if ($jsonContent === '') {
                throw new RuntimeException('managed_configs.json darf nicht leer sein.');
            }
            if (strlen($jsonContent) > 1024 * 1024) {
                throw new RuntimeException('managed_configs.json ist zu gross (Maximum 1 MiB).');
            }
            $arr = json_decode($jsonContent, true);
            if (json_last_error() !== JSON_ERROR_NONE || !is_array($arr)) {
                throw new RuntimeException('Ungültiges JSON: ' . json_last_error_msg());
            }
            foreach ($arr as $id => $_entry) {
                if (!is_string($id)) throw new RuntimeException('Ungültige ID erkannt.');
                validate_config_id($id);
            }
            $arrNorm = normalize_configs_actions($arr);
            validate_normalized_configs($arrNorm);

            $oldRaw = $controller->getRawConfigs();
            if (is_string($oldRaw)) {
                $tmp = json_decode($oldRaw, true);
                $oldRaw = is_array($tmp) ? $tmp : [];
            }
            if (!is_array($oldRaw)) $oldRaw = [];
            $oldNorm = normalize_configs_actions($oldRaw);
            $desiredRefs = cm_load_desired_state_document_for_refs($serverlist_file);
            cm_assert_config_ids_not_referenced($oldNorm, $arrNorm, $desiredRefs, $serverlist, $serverLabel);

            $serialized = json_encode_pretty_inline($arrNorm);
            if ($ajaxAction === 'validate_managed') {
                cm_json_out(['ok' => true, 'valid' => true, 'summary' => ['entries' => count($arrNorm)]]);
            }
            $result = $controller->saveRawConfigs($serialized);
            if (!is_array($result) || empty($result['ok'])) {
                throw new RuntimeException('Speichern fehlgeschlagen.');
            }
            cm_json_out([
                'ok' => true,
                'saved' => 'managed_configs.json',
                'result' => $result,
                'audit_error' => (string)($result['audit_error'] ?? ''),
                'summary' => ['entries' => count($arrNorm)],
            ]);
        }

        if ($ajaxAction === 'run_config_action') {
            $configName = trim((string)($_POST['config_name'] ?? ''));
            $cmd = strtolower(trim((string)($_POST['cmd'] ?? '')));

            if ($configName === '') {
                throw new RuntimeException('Keine Config ID übergeben.');
            }
            validate_config_id($configName);

            if ($cmd === '' || !preg_match('/^[A-Za-z0-9._:-]+$/', $cmd)) {
                throw new RuntimeException('Ungültige Aktion.');
            }

            $rawCfgForAction = $controller->getRawConfigs();
            if (is_string($rawCfgForAction)) {
                $dec = json_decode($rawCfgForAction, true);
                if (json_last_error() === JSON_ERROR_NONE && is_array($dec)) {
                    $rawCfgForAction = $dec;
                }
            }

            if (!is_array($rawCfgForAction)) {
                throw new RuntimeException('managed_configs.json konnte für die Aktionsprüfung nicht geladen werden.');
            }

            $normForAction = normalize_configs_actions($rawCfgForAction);
            validate_normalized_configs($normForAction);

            if (!isset($normForAction[$configName])) {
                throw new RuntimeException('Config ID ist in der gespeicherten managed_configs.json nicht vorhanden.');
            }

            $allowedActions = $normForAction[$configName]['actions'] ?? [];
            $allowedLower = [];
            foreach (array_keys($allowedActions) as $allowedToken) {
                $allowedLower[strtolower((string)$allowedToken)] = (string)$allowedToken;
            }

            if (!array_key_exists($cmd, $allowedLower)) {
                throw new RuntimeException('Aktion ist in der gespeicherten managed_configs.json nicht erlaubt. Neue Actions zuerst speichern.');
            }

            $realCmd = $allowedLower[$cmd];
            $result = $controller->callAction($configName, $realCmd);
            $httpCode = (int)($result['http_code'] ?? 500);
            $response = cm_decode_agent_payload($result['response'] ?? '');
            $ok = $httpCode >= 200 && $httpCode < 300;

            cm_json_out([
                'ok' => $ok,
                'config_name' => $configName,
                'cmd' => $realCmd,
                'http_code' => $httpCode,
                'risky' => cm_action_is_risky($realCmd),
                'response' => $response,
            ], 200);
        }

        if (!isset($_POST['json_content']) || !is_string($_POST['json_content']) || trim($_POST['json_content']) === '') {
            $pms = (string)ini_get('post_max_size');
            $ums = (string)ini_get('upload_max_filesize');
            throw new RuntimeException('Kein JSON empfangen. post_max_size=' . $pms . ', upload_max_filesize=' . $ums);
        }

        $jsonContent = trim((string)$_POST['json_content']);
        $arr = json_decode($jsonContent, true);

        if (json_last_error() !== JSON_ERROR_NONE) {
            throw new RuntimeException('Ungültiges JSON. ' . json_last_error_msg());
        }

        if (!is_array($arr)) {
            throw new RuntimeException('Ungültiges JSON Objekt. Erwartet wurde eine Map id => objekt.');
        }

        foreach ($arr as $id => $_dummy) {
            if (!is_string($id)) {
                throw new RuntimeException('Ungültige ID erkannt.');
            }
            validate_config_id($id);
        }

        $arrNorm = normalize_configs_actions($arr);
        validate_normalized_configs($arrNorm);

        $serialized = json_encode_pretty_inline($arrNorm);
        if ($serialized === '') {
            throw new RuntimeException('Serialisierung fehlgeschlagen.');
        }

        $res = $controller->saveRawConfigs($serialized);

        if (!is_array($res) || empty($res['ok'])) {
            $details = is_array($res)
                ? (string)json_encode($res, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)
                : '';
            throw new RuntimeException('Speichern fehlgeschlagen' . ($details !== '' ? ' ' . $details : ''));
        }

        $msg = 'Konfiguration gespeichert.';
    } catch (Throwable $e) {
        error_log('configs_editor post failed: ' . $e->getMessage());

        if ($ajaxAction === 'run_config_action') {
            cm_json_out([
                'ok' => false,
                'error' => $e->getMessage(),
            ], 200);
        }

        append_error($err, 'Save Fehler. ' . $e->getMessage());
    }
}

/* --------------------------------------------------------
 * Initialzustand
 * --------------------------------------------------------
 * Die Datei wird absichtlich nicht beim Seitenaufruf geladen. Erst der
 * ausdrueckliche Klick auf "Vom Server laden" ruft managed_get auf.
 */
$uiCfg = [];
$rawJsonPretty = '{}';

/* --------------------------------------------------------
 * Kategorien / Serveranzeige
 * -------------------------------------------------------- */
$selectedCategory = isset($_GET['category']) ? trim((string)$_GET['category']) : '';

$cats = [];
foreach ($uiCfg as $it) {
    if (is_array($it) && !empty($it['category'])) {
        $cats[] = (string)$it['category'];
    }
}
$cats = array_values(array_unique($cats));

if (!in_array('service', $cats, true)) {
    $cats[] = 'service';
}
if (!in_array('uncategorized', $cats, true)) {
    $cats[] = 'uncategorized';
}

$serverOptions = [];
foreach ($serverlist as $i => $srv) {
    $label = is_array($srv)
        ? (string)($srv['name'] ?? ($srv['host'] ?? ('Server ' . $i)))
        : ('Server ' . $i);

    $serverOptions[] = [
        'i' => (string)$i,
        'label' => $label,
    ];
}
?>
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <title>Managed Configs</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <?php require MMBB_UI . '/includes/css.php'; ?>
  <link rel="stylesheet" href="assets/css/configs_editor.css?v=3.10.6">
  <?php
  // Seitenspezifische Komponenten (Actions/Service-Control) zuerst laden.
  // Die gemeinsame Editor-Geometrie folgt danach bewusst als kanonische Darstellung.
  $__cfgActionsCss = __DIR__ . '/assets/css/configs_editor_late.css';
  if (is_file($__cfgActionsCss) && is_readable($__cfgActionsCss) && function_exists('mmbb_css_file_to_url')) {
      $__cfgActionsUrl = mmbb_css_file_to_url($__cfgActionsCss);
      $__cfgActionsMtime = @filemtime($__cfgActionsCss);
      if (is_int($__cfgActionsMtime) && $__cfgActionsMtime > 0) {
          $__cfgActionsUrl .= '?v=' . $__cfgActionsMtime;
      }
      echo '<link href="' . h($__cfgActionsUrl) . '" rel="stylesheet">' . "\n";
  }
  ?>
  <link rel="stylesheet" href="assets/css/configuration_workspace.css?v=3.10.12">
</head>
<body class="configuration-editor-page cfg-editor-page">
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3">
    <?php require MMBB_UI . '/module_header.php'; ?>

    <?php if ($readOnlyMode): ?>
    <div class="readonly-banner mb-3">
      <strong>Read Only Modus aktiv.</strong>
      Die Seite konnte nicht vollstaendig initialisiert werden. Anzeigen ist möglich, Speichern ist deaktiviert.
    </div>
  <?php endif; ?>

  <?php if ($msg): ?>
    <div class="alert alert-success alert-dismissible fade show d-flex align-items-center" role="alert" data-autohide="3000">
      <i class="bi bi-check-circle-fill me-2"></i>
      <div><?= h($msg) ?></div>
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    </div>
  <?php endif; ?>

  <?php if ($err): ?>
    <div class="alert alert-warning alert-dismissible fade show d-flex align-items-center" role="alert" data-autohide="7000">
      <i class="bi bi-exclamation-triangle-fill me-2"></i>
      <div><?= h($err) ?></div>
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    </div>
  <?php endif; ?>

  <section class="shadow-card p-3 cfg-workspace">
    <ul class="nav nav-tabs mmbb-content-tabs" role="tablist">
      <li class="nav-item" role="presentation">
        <button class="nav-link active" id="tab-form" data-bs-toggle="tab" data-bs-target="#pane-form" type="button" role="tab">Formular</button>
      </li>
      <li class="nav-item" role="presentation">
        <button class="nav-link" id="tab-json" data-bs-toggle="tab" data-bs-target="#pane-json" type="button" role="tab">JSON</button>
      </li>
      <li class="nav-item" role="presentation">
        <button class="nav-link" id="tab-backups" data-bs-toggle="tab" data-bs-target="#pane-backups" type="button" role="tab">
          Backups / Restore <span class="badge rounded-pill text-bg-light border ms-1" id="cfgBackupCount">0</span>
        </button>
      </li>
    </ul>

    <div id="cfgBackupMessage" class="alert d-none mt-3 mb-0" role="alert"></div>

    <form class="mt-3" id="cfgForm" method="post" action="configs_editor.php?server_idx=<?= urlencode((string)$server_idx) ?>">
      <input type="hidden" name="csrf_token" value="<?= h($csrf_token) ?>">
      <input type="hidden" name="json_content" id="json_content">

      <div class="tab-content">
        <div class="tab-pane fade show active" id="pane-form" role="tabpanel">
          <div class="sticky-topbar cfg-commandbar mb-3">
            <div class="cfg-commandbar-main">
              <div class="cfg-command-actions" aria-label="Bearbeitungsaktionen">
                <button type="button" class="btn btn-outline-secondary btn-sm configuration-load-button" id="btnReloadServer" title="managed_configs.json vom Zielserver laden">
                  <i class="bi bi-download me-1"></i> Vom Server laden
                </button>
                <button type="button" class="btn btn-sm btn-outline-secondary mmbb-btn mmbb-btn-secondary" id="btnRefreshServers" title="Serverliste und Seite aktualisieren">
                  <i class="bi bi-arrow-clockwise me-1"></i> Server aktualisieren
                </button>
                <button type="button" class="btn btn-sm btn-outline-primary mmbb-btn" id="btnAddEntry" disabled>
                  <i class="bi bi-plus-circle me-1"></i> Neuer Eintrag
                </button>
                <button type="button" class="btn btn-sm btn-outline-primary mmbb-btn" id="btnValidateManaged" disabled>
                  <i class="bi bi-check2-circle me-1"></i> Validieren
                </button>
                <button type="button" class="btn btn-sm btn-success mmbb-btn mmbb-btn-success mmbb-action-save" id="btnSaveManaged" disabled>
                  <i class="bi bi-save me-1"></i> Änderungen speichern
                </button>
              </div>

              <div class="cfg-server-field">
                <label for="serverSelect" class="form-label">Zielserver</label>
                <select id="serverSelect" class="form-select form-select-sm">
                  <?php foreach ($serverOptions as $opt): ?>
                    <option value="<?= h($opt['i']) ?>" <?= ($opt['i'] === (string)$server_idx) ? 'selected' : '' ?>>
                      <?= h($opt['label']) ?>
                    </option>
                  <?php endforeach; ?>
                </select>
              </div>
            </div>

            <div class="cfg-filterbar" aria-label="Einträge filtern">
              <div class="cfg-filter-field cfg-filter-search">
                <label for="filterText" class="form-label">Suche</label>
                <input id="filterText" class="form-control form-control-sm" disabled placeholder="ID, Pfad, Service, Benutzer …" autocomplete="off">
              </div>

              <div class="cfg-filter-field">
                <label for="filterCat" class="form-label">Kategorie</label>
                <select id="filterCat" class="form-select form-select-sm" disabled>
                  <option value="">Alle Kategorien</option>
                </select>
              </div>

              <div class="cfg-filter-field">
                <label for="filterType" class="form-label">Typ</label>
                <select id="filterType" class="form-select form-select-sm" disabled>
                  <option value="">Alle Typen</option>
                  <option value="config">Nur Datei</option>
                  <option value="systemd">Systemdienst</option>
                  <option value="script">Script / Programm</option>
                </select>
              </div>

              <button type="button" id="btnFilterReset" disabled class="btn btn-outline-secondary btn-sm mmbb-btn mmbb-btn-secondary mmbb-action-reset cfg-filter-reset">
                <i class="bi bi-x-circle me-1"></i> Filter löschen
              </button>
            </div>
          </div>

          <datalist id="knownCategoriesList"></datalist>

          <div class="cfg-editor-layout configuration-editor-workarea">
            <aside class="cfg-master-pane" aria-label="Konfigurationseinträge">
              <div class="cfg-master-head">
                <div>
                  <strong><i class="bi bi-list-ul"></i> Einträge</strong>
                  <small>Auswählen statt alle Formulare gleichzeitig öffnen</small>
                </div>
                <span class="badge text-bg-light border"><span id="cfgListCount">0</span></span>
              </div>
              <div id="cfgNavigator" class="cfg-master-list configuration-master-scroll" role="listbox" aria-label="Managed Configs"></div>
              <div id="cfgNavigatorEmpty" class="cfg-master-empty">
                <i class="bi bi-box-arrow-in-down"></i>
                <strong>Noch keine Konfiguration geladen</strong>
                <span>Zuerst managed_configs.json vom Zielserver laden.</span>
              </div>
            </aside>

            <section class="cfg-detail-pane" aria-label="Ausgewählten Eintrag bearbeiten">
              <div id="cfgDetailEmpty" class="cfg-detail-empty">
                <i class="bi bi-box-arrow-in-down"></i>
                <h3>Keine Datei geladen</h3>
                <p>Zielserver wählen und anschliessend „Vom Server laden“ verwenden.</p>
              </div>
              <div id="cards" class="cfg-detail-host"></div>
            </section>
          </div>

        </div>

        <div class="tab-pane fade" id="pane-json" role="tabpanel">
          <div class="d-flex flex-wrap gap-2 mb-2 mt-2">
            <button type="button" class="btn btn-outline-secondary btn-sm mmbb-btn mmbb-btn-secondary" id="btnJsonPretty">JSON huebsch formatieren</button>
            <button type="button" class="btn btn-outline-secondary btn-sm mmbb-btn mmbb-btn-secondary" id="btnJsonToForm">JSON zu Formular laden</button>
            <button type="button" class="btn btn-success btn-sm mmbb-btn mmbb-btn-success ms-auto" id="btnSaveManagedJson" disabled>
              <i class="bi bi-save me-1"></i> Änderungen speichern
            </button>
          </div>
          <div id="jsonEditor" class="configuration-json-editor" aria-label="managed_configs.json bearbeiten"></div>
        </div>

        <div class="tab-pane fade configuration-backup-pane" id="pane-backups" role="tabpanel">
          <div class="configuration-backup-layout mt-2">
            <aside class="configuration-backup-master" aria-label="Backups der managed_configs.json">
              <div class="configuration-backup-head">
                <div>
                  <strong><i class="bi bi-clock-history"></i> Backups / Restore</strong>
                  <small>Automatische Sicherungen vor Änderungen und Restore</small>
                </div>
                <span class="badge text-bg-light border" id="cfgBackupListCount">0</span>
              </div>
              <div class="configuration-backup-actions">
                <button type="button" class="btn btn-outline-secondary btn-sm" id="cfgLoadBackups" <?= $readOnlyMode ? 'disabled' : '' ?>>
                  <i class="bi bi-arrow-clockwise me-1"></i> Backups laden
                </button>
              </div>
              <div id="cfgBackupList" class="configuration-backup-list" role="listbox"></div>
              <div id="cfgBackupEmpty" class="configuration-backup-empty">
                <i class="bi bi-archive"></i>
                <strong>Noch keine Backups geladen</strong>
                <span>Backups des gewählten Zielservers laden.</span>
              </div>
            </aside>

            <section class="configuration-backup-detail" aria-label="Backup-Vorschau">
              <div class="configuration-backup-detail-head">
                <div>
                  <strong id="cfgBackupTitle">Kein Backup ausgewählt</strong>
                  <small id="cfgBackupMeta">managed_configs.json</small>
                </div>
                <button type="button" class="btn btn-outline-warning btn-sm" id="cfgRestoreBackup" disabled>
                  <i class="bi bi-arrow-counterclockwise me-1"></i> Wiederherstellen
                </button>
              </div>
              <pre id="cfgBackupPreview" class="configuration-backup-preview">Links ein Backup auswählen, um den Inhalt zu prüfen.</pre>
            </section>
          </div>
        </div>
      </div>

    </form>
  </section>
</div>

<?php require MMBB_UI . '/includes/js.php'; ?>
<script src="assets/js/configuration_json_editor.js?v=3.10.0"></script>

<script>
// =======================================================
// configs_editor.js inline
// Gehaertete Version
// =======================================================

let JSON_DIRTY = false;
const READ_ONLY_MODE = <?= $readOnlyMode ? 'true' : 'false' ?>;
let CFG_DATA = {};
let ACTIVE_CFG_ID = '';
let FILTERED_CFG_IDS = [];
let DETAIL_DIRTY = false;
let MANAGED_LOADED = false;
let MANAGED_DIRTY = false;
let MANAGED_BUSY = false;
let MANAGED_HYDRATING = false;

// -------------------- Utils --------------------
function esc(s) {
  return String(s || '').replace(/[&<>"']/g, m => ({
    '&':'&amp;',
    '<':'&lt;',
    '>':'&gt;',
    '"':'&quot;',
    "'":'&#39;'
  }[m]));
}

function parseJsonSafe(txt) {
  try {
    return JSON.parse(txt);
  } catch (e) {
    return null;
  }
}

function parseArgs(str) {
  let out = [];
  let s = String(str || '').trim();
  let cur = '';
  let quote = null;

  for (let i = 0; i < s.length; i++) {
    const ch = s[i];

    if (quote) {
      if (ch === quote) {
        quote = null;
      } else {
        cur += ch;
      }
    } else {
      if (ch === '"' || ch === "'") {
        quote = ch;
      } else if (/\s/.test(ch)) {
        if (cur) {
          out.push(cur);
          cur = '';
        }
      } else {
        cur += ch;
      }
    }
  }

  if (cur) out.push(cur);
  return out;
}

function actionsToMap(actions) {
  if (!actions) return {};

  if (Array.isArray(actions)) {
    const m = {};
    for (let i = 0; i < actions.length; i++) {
      const t = String(actions[i] || '').trim();
      if (t && !UNSUPPORTED_ACTIONS.has(t.toLowerCase())) m[t] = [];
    }
    return m;
  }

  if (typeof actions === 'object') {
    const m2 = {};
    const ks = Object.keys(actions);
    for (let j = 0; j < ks.length; j++) {
      const tok = String(ks[j] || '').trim();
      if (!tok || UNSUPPORTED_ACTIONS.has(tok.toLowerCase())) continue;
      const v = actions[tok];
      const arr = Array.isArray(v) ? v.map(a => String(a)).filter(z => z !== '') : [];
      m2[tok] = arr;
    }
    return m2;
  }

  return {};
}

function jsonScalarToStr(v) {
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (v === null) return 'null';
  return JSON.stringify(v);
}

function jsonEncodePrettyInline(data, indent, maxLine, level) {
  indent = indent || '  ';
  maxLine = maxLine || 120;
  level = level || 0;

  if (data && typeof data === 'object') {
    if (Array.isArray(data)) {
      let allScalar = true;
      let parts = [];

      for (let i = 0; i < data.length; i++) {
        const v = data[i];
        if (v && typeof v === 'object') {
          allScalar = false;
          break;
        }
        parts.push(jsonScalarToStr(v));
      }

      if (allScalar) {
        const inline = '[' + parts.join(', ') + ']';
        if (inline.length <= maxLine) return inline;
      }

      let buf = '[\n';
      for (let i = 0; i < data.length; i++) {
        buf += new Array(level + 2).join(indent) + jsonEncodePrettyInline(data[i], indent, maxLine, level + 1) + ",\n";
      }
      if (buf.slice(-2) === ",\n") buf = buf.slice(0, -2) + "\n";
      return buf + new Array(level + 1).join(indent) + ']';
    }

    let buf2 = "{\n";
    const keys = Object.keys(data);
    for (let k = 0; k < keys.length; k++) {
      const key = keys[k];
      buf2 += new Array(level + 2).join(indent) + JSON.stringify(String(key)) + ": " + jsonEncodePrettyInline(data[key], indent, maxLine, level + 1) + ",\n";
    }
    if (buf2.slice(-2) === ",\n") buf2 = buf2.slice(0, -2) + "\n";
    return buf2 + new Array(level + 1).join(indent) + '}';
  }

  return jsonScalarToStr(data);
}

function validConfigId(id) {
  return /^[A-Za-z0-9._-]+$/.test(String(id || '').trim());
}

function validMode(mode) {
  const v = String(mode || '').trim();
  return v === '' || /^[0-7]{3,4}$/.test(v);
}

function validActionToken(token) {
  return /^[A-Za-z0-9._:-]+$/.test(String(token || '').trim());
}

// -------------------- State --------------------
function saveAceState() {
  try {
    if (!window.aceEditor) return;
    const pos = window.aceEditor.getCursorPosition();
    const top = window.aceEditor.session.getScrollTop();
    localStorage.setItem('cfgEditor.acePos', JSON.stringify(pos));
    localStorage.setItem('cfgEditor.aceScroll', String(top));
  } catch (_) {}
}

function restoreAceViewport(opts) {
  opts = opts || {};
  try {
    if (!window.aceEditor) return;
    const pos = JSON.parse(localStorage.getItem('cfgEditor.acePos') || 'null');
    const top = parseInt(localStorage.getItem('cfgEditor.aceScroll') || '0', 10);
    if (Number.isFinite(top)) window.aceEditor.session.setScrollTop(top);
    if (pos && typeof pos === 'object') window.aceEditor.moveCursorToPosition(pos);
    if (opts.focus) window.aceEditor.focus();
  } catch (_) {}
}

function saveWindowScroll() {
  try {
    localStorage.setItem('cfgEditor.winScroll', String(window.scrollY || window.pageYOffset || 0));
  } catch (_) {}
}

function restoreWindowScroll() {
  try {
    const y = parseInt(localStorage.getItem('cfgEditor.winScroll') || '0', 10);
    if (Number.isFinite(y) && y >= 0) {
      window.scrollTo(0, y);
    }
  } catch (_) {}
}

function focusAceReliably(maxTries) {
  maxTries = Number.isFinite(maxTries) ? maxTries : 12;
  const startY = window.scrollY || window.pageYOffset || 0;

  function tick(i) {
    if (!window.aceEditor) return;
    const pane = document.getElementById('pane-json');
    const jsonVisible = !!(pane && pane.classList.contains('show'));

    if (jsonVisible) {
      restoreAceViewport({ focus: true });
      window.scrollTo(0, startY);
    }

    if (i < maxTries) {
      requestAnimationFrame(() => tick(i + 1));
    }
  }

  requestAnimationFrame(() => tick(0));
}

function forceReturnToJsonIfNeeded() {
  try {
    if (localStorage.getItem('cfgEditor.returnTo') === 'tab-json') {
      localStorage.removeItem('cfgEditor.returnTo');
      const btn = document.getElementById('tab-json');
      if (btn && window.bootstrap) new bootstrap.Tab(btn).show();
      focusAceReliably(12);
    }
  } catch (_) {}
}

function getSavedOpenCfgIds() {
  try {
    return JSON.parse(localStorage.getItem('cfgEditor.openCfgIds') || '[]');
  } catch (_) {
    return [];
  }
}

function setSavedOpenCfgIds(ids) {
  try {
    localStorage.setItem('cfgEditor.openCfgIds', JSON.stringify(ids || []));
  } catch (_) {}
}

function restoreOpenAccordions(ids) {
  const openIds = Array.isArray(ids) ? ids : (getSavedOpenCfgIds() || []);
  if (!openIds.length) return;

  document.querySelectorAll('.accordion-item').forEach(function(it) {
    const cfgId = it.getAttribute('data-cfg-id');
    if (openIds.includes(cfgId)) {
      const col = it.querySelector('.accordion-collapse');
      const btn = it.querySelector('.chev-rotate');
      if (col && !col.classList.contains('show')) col.classList.add('show');
      it.classList.add('is-open');
      if (btn) btn.setAttribute('aria-expanded', 'true');
    }
  });
}

function restoreUiState() {
  try {
    const savedTab = localStorage.getItem('cfgEditor.activeTab');
    if (savedTab) {
      const btn = document.getElementById(savedTab);
      if (btn && window.bootstrap) new bootstrap.Tab(btn).show();
    }
  } catch (_) {}
}

// -------------------- Data from PHP --------------------
var KNOWN_CATEGORIES = <?= json_encode(array_values($cats), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;
var SELECTED_CATEGORY = <?= json_encode($selectedCategory, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;

// -------------------- Filter + Labels --------------------
function updateFilterOptions(dataObj) {
  const set = {};
  for (let i = 0; i < KNOWN_CATEGORIES.length; i++) {
    set[KNOWN_CATEGORIES[i]] = 1;
  }

  Object.keys(dataObj || {}).forEach(function(k) {
    const c = dataObj[k];
    if (c && c.category) set[c.category] = 1;
  });

  const sel = document.getElementById('filterCat');
  if (!sel) return;

  const cur = sel.value || SELECTED_CATEGORY || '';
  const arr = Object.keys(set).filter(Boolean).sort((a, b) => a.localeCompare(b));

  sel.innerHTML = '<option value="">Alle</option>' + arr.map(c =>
    '<option value="' + esc(c) + '"' + (c === cur ? ' selected' : '') + '>' + esc(c) + '</option>'
  ).join('');
}

function cfgSearchHaystack(item) {
  const values = [
    item.getAttribute('data-cfg-id') || '',
    item.querySelector('[data-field="path"]')?.value || '',
    item.querySelector('[data-field="service"]')?.value || '',
    item.querySelector('[data-field="category"]')?.value || '',
    item.querySelector('[data-field="user"]')?.value || '',
    item.querySelector('[data-field="group"]')?.value || ''
  ];
  return values.join(' ').toLowerCase();
}

function configType(cfg) {
  const service = String(cfg?.service || '').trim();
  if (!service) return 'config';
  return serviceIsRunner(service) ? 'script' : 'systemd';
}

function configTypeLabel(type) {
  return ({config:'Datei', systemd:'Service', script:'Script'})[type] || 'Datei';
}

function configTypeIcon(type) {
  return ({config:'bi-file-earmark-text', systemd:'bi-hdd-network', script:'bi-terminal'})[type] || 'bi-file-earmark-text';
}

function syncActiveEditorToModel(options) {
  options = options || {};
  const card = document.querySelector('#cards .cfg-detail-card');
  if (!card || !ACTIVE_CFG_ID) return true;

  const oldId = String(card.getAttribute('data-original-id') || ACTIVE_CFG_ID);
  const newId = (card.querySelector('[data-field="id"]')?.value || '').trim();

  if (!newId) {
    if (options.silent) return false;
    throw new Error('Die interne ID darf nicht leer sein.');
  }
  if (newId !== oldId && Object.prototype.hasOwnProperty.call(CFG_DATA, newId)) {
    if (options.silent) return false;
    throw new Error('Die ID "' + newId + '" existiert bereits.');
  }

  const cfg = {};
  const read = name => (card.querySelector('[data-field="' + name + '"]')?.value || '').trim();
  const path = read('path');
  const category = read('category');
  const service = read('service');
  const user = read('user');
  const group = read('group');
  const mode = read('mode');

  if (path) cfg.path = path;
  if (category) cfg.category = category;
  if (service) cfg.service = service;
  if (user) cfg.user = user;
  if (group) cfg.group = group;
  if (mode) cfg.mode = mode;

  const actions = {};
  card.querySelectorAll('.actions-list .actions-row').forEach(row => {
    const tok = (row.querySelector('.token')?.value || '').trim();
    if (!tok || UNSUPPORTED_ACTIONS.has(tok.toLowerCase())) return;
    actions[tok] = parseArgs(row.querySelector('.args')?.value || '').filter(Boolean);
  });
  cfg.actions = actions;

  if (newId !== oldId) delete CFG_DATA[oldId];
  CFG_DATA[newId] = cfg;
  ACTIVE_CFG_ID = newId;
  card.setAttribute('data-original-id', newId);
  card.setAttribute('data-cfg-id', newId);
  DETAIL_DIRTY = false;
  try { localStorage.setItem('cfgEditor.selectedId', newId); } catch (_) {}
  return true;
}

function getFilteredConfigIds() {
  syncActiveEditorToModel({silent:true});
  const category = (document.getElementById('filterCat')?.value || '').trim().toLowerCase();
  const type = (document.getElementById('filterType')?.value || '').trim().toLowerCase();
  const query = (document.getElementById('filterText')?.value || '').trim().toLowerCase();

  return sortedKeysByCatThenId(CFG_DATA).filter(id => {
    const cfg = CFG_DATA[id] || {};
    const cfgCategory = String(cfg.category || '').toLowerCase();
    const cfgType = configType(cfg);
    const haystack = [id, cfg.path, cfg.service, cfg.category, cfg.user, cfg.group, Object.keys(actionsToMap(cfg.actions)).join(' ')]
      .join(' ').toLowerCase();
    return (!category || cfgCategory === category)
      && (!type || cfgType === type)
      && (!query || haystack.includes(query));
  });
}

function updateConfigSummary() {
  FILTERED_CFG_IDS = getFilteredConfigIds();
  const categories = new Set(Object.values(CFG_DATA || {}).map(cfg => String(cfg?.category || '').trim()).filter(Boolean));
  const totalEl = document.getElementById('cfgTotalCount');
  const visibleEl = document.getElementById('cfgVisibleCount');
  const categoryEl = document.getElementById('cfgCategoryCount');
  const listEl = document.getElementById('cfgListCount');
  if (totalEl) totalEl.textContent = String(Object.keys(CFG_DATA).length);
  if (visibleEl) visibleEl.textContent = String(FILTERED_CFG_IDS.length);
  if (categoryEl) categoryEl.textContent = String(categories.size);
  if (listEl) listEl.textContent = String(FILTERED_CFG_IDS.length);
}

function renderConfigNavigator() {
  const nav = document.getElementById('cfgNavigator');
  const empty = document.getElementById('cfgNavigatorEmpty');
  if (!nav) return;

  FILTERED_CFG_IDS = getFilteredConfigIds();
  const grouped = new Map();
  FILTERED_CFG_IDS.forEach(id => {
    const cat = String(CFG_DATA[id]?.category || 'Ohne Kategorie');
    if (!grouped.has(cat)) grouped.set(cat, []);
    grouped.get(cat).push(id);
  });

  let html = '';
  [...grouped.keys()].sort((a,b) => a.localeCompare(b)).forEach(category => {
    html += '<div class="cfg-master-group">'
      + '<div class="cfg-master-group-title"><span>' + esc(category) + '</span><span>' + grouped.get(category).length + '</span></div>';
    grouped.get(category).forEach(id => {
      const cfg = CFG_DATA[id] || {};
      const type = configType(cfg);
      const count = Object.keys(actionsToMap(cfg.actions)).length;
      const active = id === ACTIVE_CFG_ID;
      html += '<button type="button" class="cfg-master-row' + (active ? ' is-active' : '') + '" data-nav-cfg-id="' + esc(id) + '" role="option" aria-selected="' + (active ? 'true' : 'false') + '">'
        + '<span class="cfg-master-type"><i class="bi ' + configTypeIcon(type) + '"></i></span>'
        + '<span class="cfg-master-copy"><strong>' + esc(id) + '</strong><small title="' + esc(cfg.path || '') + '">' + esc(cfg.path || 'Kein Pfad gesetzt') + '</small></span>'
        + '<span class="cfg-master-meta"><span>' + esc(configTypeLabel(type)) + '</span><span><i class="bi bi-lightning-charge"></i> ' + count + '</span></span>'
        + '</button>';
    });
    html += '</div>';
  });
  nav.innerHTML = html;

  nav.querySelectorAll('[data-nav-cfg-id]').forEach(btn => {
    btn.addEventListener('click', () => selectConfig(btn.getAttribute('data-nav-cfg-id') || ''));
  });
  if (empty) empty.classList.toggle('d-none', FILTERED_CFG_IDS.length !== 0);
  updateConfigSummary();
}

function applyFormFilter() {
  renderConfigNavigator();
}

function categoryClass(cat) {
  cat = (cat || '').toLowerCase();
  if (cat === 'service') return 'badge-cat-service';
  if (cat === 'uncategorized' || cat === 'uncat' || !cat) return 'badge-cat-uncat';
  return 'badge-cat-other';
}

function serviceKindInfo(serviceStr) {
  const raw = String(serviceStr || '').trim();
  const s = raw.toLowerCase();
  if (!s) return { label: 'keine Ausführung', cls: 'badge-svc-none', icon: 'bi-dash-circle' };
  if (/^(?:bash|sh|perl|exec):/.test(s)) {
    return { label: 'Script / Programm', cls: 'badge-svc-script', icon: 'bi-terminal' };
  }
  return { label: 'Systemdienst', cls: 'badge-svc-systemd', icon: 'bi-hdd-network' };
}

// -------------------- Category Widget --------------------
function buildCategoryOptions(selectEl, current) {
  const cur = (current || '').trim();
  const known = (Array.isArray(KNOWN_CATEGORIES) ? KNOWN_CATEGORIES : []).slice().filter(Boolean).sort((a, b) => a.localeCompare(b));

  let html = '<option value="">auswählen</option>';
  known.forEach(c => {
    const sel = (c === cur) ? ' selected' : '';
    html += '<option value="' + esc(c) + '"' + sel + '>' + esc(c) + '</option>';
  });
  html += '<option disabled>──────────</option><option value="__NEW__">Neue Kategorie</option>';
  selectEl.innerHTML = html;
}

function ensureCategoryKnown(cat) {
  const v = (cat || '').trim();
  if (!v) return;

  const exists = (KNOWN_CATEGORIES || []).some(c => c.toLowerCase() === v.toLowerCase());
  if (!exists) {
    KNOWN_CATEGORIES.push(v);
    KNOWN_CATEGORIES.sort((a, b) => a.localeCompare(b));
  }
}

function refreshAllCategorySelects() {
  document.querySelectorAll('.category-widget').forEach(widget => {
    const hidden = widget.querySelector('[data-field="category"]');
    const select = widget.querySelector('.cat-select');
    const input = widget.querySelector('.cat-input');
    const mode = widget.dataset.mode || 'list';
    const val = (hidden?.value || '').trim();

    buildCategoryOptions(select, val);

    if (mode === 'new') {
      select.value = '__NEW__';
      input.classList.remove('d-none');
      input.value = val;
    } else {
      input.classList.add('d-none');
      select.value = val || '';
    }
  });
}

function updateCategoryChip(card, cat) {
  const chip = card.querySelector('[data-cat-chip]');
  if (chip) {
    const text = chip.querySelector('.cat-chip-text');
    if (text) text.textContent = (cat && String(cat).trim()) ? cat : 'keine Kategorie';
    chip.className = 'chip badge-pill cfg-category-chip ' + categoryClass(cat || '');
  }
  updateCardSummary(card);
}

function bindCategoryWidget(card, initial) {
  const widget = card.querySelector('.category-widget');
  if (!widget) return;

  const hidden = widget.querySelector('[data-field="category"]');
  const select = widget.querySelector('.cat-select');
  const input = widget.querySelector('.cat-input');

  hidden.value = initial || '';
  widget.dataset.mode = (initial && !(KNOWN_CATEGORIES || []).includes(initial)) ? 'new' : 'list';

  buildCategoryOptions(select, hidden.value);

  if (widget.dataset.mode === 'new') {
    select.value = '__NEW__';
    input.classList.remove('d-none');
    input.value = hidden.value;
  } else {
    input.classList.add('d-none');
    if (hidden.value) select.value = hidden.value;
  }

  updateCategoryChip(card, hidden.value);

  if (READ_ONLY_MODE) {
    select.disabled = true;
    input.disabled = true;
    return;
  }

  select.addEventListener('change', () => {
    if (select.value === '__NEW__') {
      widget.dataset.mode = 'new';
      input.classList.remove('d-none');
      input.focus();
    } else {
      widget.dataset.mode = 'list';
      input.classList.add('d-none');
      input.value = '';
      hidden.value = select.value;
      updateCategoryChip(card, hidden.value);
      syncActiveEditorToModel({silent:true});
      renderConfigNavigator();
    }
  });

  input.addEventListener('input', () => {
    hidden.value = input.value;
    updateCategoryChip(card, hidden.value);
    syncActiveEditorToModel({silent:true});
    renderConfigNavigator();
  });

  const commitFinal = () => {
    const v = input.value.trim();
    hidden.value = v;
    updateCategoryChip(card, v);
    if (!v) return;

    ensureCategoryKnown(v);
    widget.dataset.mode = 'list';
    buildCategoryOptions(select, v);
    select.value = v;
    input.classList.add('d-none');
    refreshAllCategorySelects();
    updateFilterOptions(collectForm());
  };

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commitFinal();
    }
  });

  input.addEventListener('blur', commitFinal);
}

// -------------------- Actions UI --------------------
const CSRF_TOKEN = <?= json_encode($csrf_token, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;
const SERVER_IDX = <?= json_encode((string)$server_idx, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;
const UNSUPPORTED_ACTIONS = new Set(['stop_start']);

function sanitizeActionsMap(actions) {
  if (!actions || typeof actions !== 'object' || Array.isArray(actions)) return {};
  Object.keys(actions).forEach(k => {
    if (UNSUPPORTED_ACTIONS.has(String(k).toLowerCase())) delete actions[k];
  });
  return actions;
}


function serviceActionSet(kind) {
  if (kind === 'safe') return ['status', 'reload', 'restart'];
  if (kind === 'full') return ['status', 'reload', 'restart', 'start', 'stop'];
  return ['status', 'reload', 'restart'];
}

function actionLabel(token) {
  const t = String(token || '').toLowerCase();
  const labels = {
    status: 'Status',
    reload: 'Reload',
    restart: 'Restart',
    start: 'Start',
    stop: 'Stop',
  };
  return labels[t] || token;
}

function actionIcon(token) {
  const t = String(token || '').toLowerCase();
  if (t === 'status') return 'bi-activity';
  if (t === 'reload') return 'bi-arrow-clockwise';
  if (t === 'restart') return 'bi-arrow-repeat';
  if (t === 'start') return 'bi-play-fill';
  if (t === 'stop') return 'bi-stop-fill';
  return 'bi-terminal';
}

function actionIsRisky(token) {
  return ['restart', 'stop'].includes(String(token || '').toLowerCase());
}

function actionCmdsForControls() {
  return ['status', 'start', 'stop', 'reload', 'restart'];
}

function actionMapFromCard(card) {
  const map = {};
  if (!card) return map;

  card.querySelectorAll('.actions-list .actions-row').forEach(row => {
    const tok = (row.querySelector('.token')?.value || '').trim();
    if (!tok) return;
    if (UNSUPPORTED_ACTIONS.has(tok.toLowerCase())) return;
    map[tok.toLowerCase()] = tok;
  });

  return map;
}

function cardHasAction(card, cmd) {
  const m = actionMapFromCard(card);
  return Object.prototype.hasOwnProperty.call(m, String(cmd || '').toLowerCase());
}

function serviceValueFromCard(card) {
  return (card?.querySelector('[data-field="service"]')?.value || '').trim();
}

function categoryValueFromCard(card) {
  return (card?.querySelector('[data-field="category"]')?.value || '').trim();
}

function serviceIsRunner(value) {
  return /^(?:bash|sh|perl|exec):/i.test(String(value || '').trim());
}

function serviceShouldBeVisible(card) {
  const service = serviceValueFromCard(card);
  if (serviceIsRunner(service)) return false;
  return !!service || categoryValueFromCard(card).toLowerCase() === 'service';
}

function updateCardSummary(card) {
  if (!card) return;
  const id = (card.querySelector('[data-field="id"]')?.value || '').trim() || 'ohne ID';
  const filePath = (card.querySelector('[data-field="path"]')?.value || '').trim() || 'kein Dateipfad gesetzt';
  const service = serviceValueFromCard(card);
  const info = serviceKindInfo(service);

  const idText = card.querySelector('[data-summary-id]');
  const pathText = card.querySelector('[data-summary-path]');
  const serviceChips = card.querySelectorAll('[data-service-kind-chip]');
  const serviceTexts = card.querySelectorAll('[data-service-kind-text]');
  const serviceIcons = card.querySelectorAll('[data-service-kind-icon]');
  const headerState = card.querySelector('[data-header-service-state]');

  if (idText) idText.textContent = id;
  if (validConfigId(id)) card.setAttribute('data-cfg-id', id);
  if (pathText) {
    pathText.textContent = filePath;
    pathText.title = filePath;
  }
  serviceChips.forEach(el => { el.className = 'chip badge-pill cfg-kind-chip ' + info.cls; });
  serviceTexts.forEach(el => { el.textContent = info.label; });
  serviceIcons.forEach(el => { el.className = 'bi ' + info.icon; });
  if (headerState) headerState.classList.toggle('d-none', !service || serviceIsRunner(service));
}

function updateActionPresentation(card) {
  if (!card) return;
  const count = card.querySelectorAll('.actions-list .actions-row').length;
  const countEls = card.querySelectorAll('[data-actions-count]');
  countEls.forEach(el => el.textContent = String(count));
  const empty = card.querySelector('[data-actions-empty]');
  const tableHead = card.querySelector('[data-actions-table-head]');
  if (empty) empty.classList.toggle('d-none', count !== 0);
  if (tableHead) tableHead.classList.toggle('d-none', count === 0);
  if (card.classList.contains('cfg-detail-card') && ACTIVE_CFG_ID) {
    syncActiveEditorToModel({silent:true});
    renderConfigNavigator();
  }
}

function setServiceState(card, state, detail) {
  state = String(state || 'unknown').toLowerCase();
  if (!['running', 'stopped', 'error', 'unknown'].includes(state)) state = 'unknown';

  const label = {
    running: 'läuft',
    stopped: 'gestoppt',
    error: 'Fehler',
    unknown: 'unbekannt'
  }[state];

  card?.querySelectorAll('[data-service-state-chip]').forEach(chip => {
    chip.className = 'chip badge-pill service-state-chip service-state-' + state;
    const txt = chip.querySelector('[data-service-state-text]');
    if (txt) txt.textContent = label;
    if (detail) chip.title = String(detail);
  });
}

function extractServiceStatus(response) {
  let r = response;
  if (r && typeof r === 'object' && Object.prototype.hasOwnProperty.call(r, 'response')) r = r.response;
  if (typeof r === 'string') {
    try { r = JSON.parse(r); } catch (_) {}
  }
  if (r && typeof r === 'object') {
    const st = String(r.status || r.state || '').toLowerCase();
    if (st === 'running' || st === 'active') return 'running';
    if (st === 'stopped' || st === 'inactive' || st === 'failed') return 'stopped';
    if (st === 'error') return 'error';
  }
  return 'unknown';
}

function updateServiceControls(card) {
  if (!card) return;

  const panel = card.querySelector('.service-control-panel');
  const serviceName = serviceValueFromCard(card);
  const visible = serviceShouldBeVisible(card);
  const nameEl = card.querySelector('[data-service-name]');

  if (nameEl) nameEl.textContent = serviceName || 'kein service gesetzt';
  if (panel) panel.classList.toggle('d-none', !visible);

  const map = actionMapFromCard(card);
  const missing = [];

  card.querySelectorAll('[data-service-cmd]').forEach(btn => {
    const cmd = String(btn.getAttribute('data-service-cmd') || '').toLowerCase();
    const allowed = Object.prototype.hasOwnProperty.call(map, cmd);
    const usable = visible && !!serviceName && allowed && !READ_ONLY_MODE;
    btn.disabled = !usable;

    if (!serviceName) {
      btn.title = 'Zuerst service setzen, z. B. postfix.service';
    } else if (!allowed) {
      btn.title = 'Action "' + cmd + '" fehlt. Preset Vollstaendig einfuegen und speichern.';
      missing.push(cmd);
    } else {
      btn.title = actionLabel(cmd) + ' für ' + serviceName;
    }
  });

  const hint = card.querySelector('[data-service-actions-hint]');
  if (hint) {
    if (!visible) {
      hint.textContent = '';
    } else if (!serviceName) {
      hint.textContent = 'Service-Feld fehlt.';
    } else if (missing.length) {
      hint.textContent = 'Für die Service-Steuerung fehlen noch: ' + Array.from(new Set(missing)).join(', ') + '. Eine Vorlage kann diese Aktionen ergänzen.';
    } else {
      hint.textContent = 'Die benötigten Service-Aktionen sind freigegeben.';
    }
  }

  updateCardSummary(card);
  updateActionPresentation(card);
}

function updateAllServiceControls() {
  document.querySelectorAll('#cards .accordion-item').forEach(updateServiceControls);
}

function actionRowHtml(token, args) {
  token = token || '';
  args = Array.isArray(args) ? args : [];
  const argsValue = args.join(' ');
  const disabled = READ_ONLY_MODE ? ' disabled' : '';
  return ''
    + '<div class="action-field action-token-field">'
    + '  <label class="action-field-label">Aktion</label>'
    + '  <input class="form-control form-control-sm token" placeholder="z. B. reload oder deploy" value="' + esc(token) + '"' + disabled + '>'
    + '</div>'
    + '<div class="action-field action-args-field">'
    + '  <label class="action-field-label">Argumente <span class="text-muted fw-normal">(optional)</span></label>'
    + '  <input class="form-control form-control-sm args" placeholder="z. B. --env=prod &quot;Nachricht&quot;" value="' + esc(argsValue) + '"' + disabled + '>'
    + '</div>'
    + '<div class="action-row-tools" aria-label="Aktion bearbeiten">'
    + '  <button type="button" class="btn btn-sm btn-outline-success btn-run-action mmbb-btn mmbb-btn-success mmbb-action-run" title="Bereits gespeicherte Aktion ausführen"' + disabled + '><i class="bi bi-play-circle"></i></button>'
    + '  <button type="button" class="btn btn-sm btn-outline-secondary btn-up mmbb-btn mmbb-btn-secondary" title="Nach oben verschieben"' + disabled + '><i class="bi bi-chevron-up"></i></button>'
    + '  <button type="button" class="btn btn-sm btn-outline-secondary btn-down mmbb-btn mmbb-btn-secondary" title="Nach unten verschieben"' + disabled + '><i class="bi bi-chevron-down"></i></button>'
    + '  <button type="button" class="btn btn-sm btn-outline-danger btn-remove mmbb-btn mmbb-btn-danger mmbb-action-delete" title="Aktion entfernen"' + disabled + '><i class="bi bi-trash"></i></button>'
    + '</div>';
}

function addActionRow(list, token, args) {
  const row = document.createElement('div');
  row.className = 'actions-row';
  row.innerHTML = actionRowHtml(token, args || []);
  list.appendChild(row);
  const card = list.closest('.accordion-item');
  updateServiceControls(card);
  updateActionPresentation(card);
  return row;
}

function setServiceActions(card, kind) {
  if (READ_ONLY_MODE) return;

  const svcEl = card.querySelector('[data-field="service"]');
  const catEl = card.querySelector('[data-field="category"]');
  const svc = (svcEl?.value || '').trim();

  if (!svc) {
    alert('Zuerst das Feld service setzen, z. B. postfix.service.');
    svcEl?.focus();
    return;
  }

  if (catEl && !catEl.value.trim()) {
    catEl.value = 'service';
    updateCategoryChip(card, 'service');
  }

  const list = card.querySelector('.actions-list');
  if (!list) return;

  const existing = new Map();
  list.querySelectorAll('.actions-row').forEach(row => {
    const tok = (row.querySelector('.token')?.value || '').trim();
    if (tok && !UNSUPPORTED_ACTIONS.has(tok.toLowerCase())) existing.set(tok.toLowerCase(), row);
  });

  serviceActionSet(kind).forEach(tok => {
    if (!existing.has(tok)) addActionRow(list, tok, []);
  });

  updateServiceControls(card);
  showActionResult(card, 'info', 'Service-Aktionen wurden eingefuegt. Bitte speichern, damit der Agent sie kennt.');
}

function showActionResult(card, type, message, details) {
  const box = card.querySelector('.action-result');
  if (!box) return;

  const cls = type === 'ok' ? 'alert-success' : (type === 'info' ? 'alert-info' : 'alert-warning');
  let html = '<div class="alert ' + cls + ' py-2 px-3 mb-0 small">' + esc(message || '') + '</div>';

  if (details !== undefined && details !== null && details !== '') {
    let detailText = '';
    try {
      detailText = typeof details === 'string' ? details : JSON.stringify(details, null, 2);
    } catch (_) {
      detailText = String(details);
    }
    if (detailText) {
      html += '<pre class="small bg-body-tertiary border rounded p-2 mt-2 mb-0" style="max-height:220px;overflow:auto;">' + esc(detailText) + '</pre>';
    }
  }

  box.innerHTML = html;
}

async function runConfigAction(card, token, btn, options) {
  options = options || {};
  token = String(token || '').trim();
  if (!token) {
    alert('Keine Aktion angegeben.');
    return;
  }

  const id = (card.querySelector('[data-field="id"]')?.value || '').trim();
  if (!id) {
    alert('Keine Config ID vorhanden.');
    return;
  }

  if (!options.silent && actionIsRisky(token)) {
    const msg = 'Aktion "' + actionLabel(token) + '" für "' + id + '" wirklich ausführen?';
    if (!confirm(msg)) return;
  }

  const oldHtml = btn ? btn.innerHTML : '';
  if (btn) {
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner-border spinner-border-sm" aria-hidden="true"></span>';
  }

  if (!options.silent) {
    showActionResult(card, 'info', 'Aktion wird ausgeführt: ' + actionLabel(token));
  }

  try {
    const fd = new FormData();
    fd.append('csrf_token', CSRF_TOKEN);
    fd.append('ajax_action', 'run_config_action');
    fd.append('config_name', id);
    fd.append('cmd', token);

    const url = new URL('configs_editor.php', window.location.href);
    url.searchParams.set('server_idx', document.getElementById('serverSelect')?.value || SERVER_IDX);

    const res = await fetch(url.toString(), {
      method: 'POST',
      body: fd,
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-Token': CSRF_TOKEN
      },
      credentials: 'same-origin',
      cache: 'no-store'
    });

    const data = await res.json().catch(() => null);
    if (!data) {
      throw new Error('Keine gültige JSON Antwort vom PHP Controller. HTTP ' + res.status);
    }

    if (data.ok) {
      const st = extractServiceStatus(data.response || data);
      if (String(data.cmd || token).toLowerCase() === 'status') {
        setServiceState(card, st, JSON.stringify(data.response || data));
      }
      if (!options.silent) {
        showActionResult(card, 'ok', 'Aktion ausgeführt: ' + actionLabel(data.cmd || token), data.response || data);
      }
      const t = String(data.cmd || token).toLowerCase();
      if (t !== 'status' && cardHasAction(card, 'status')) {
        window.setTimeout(() => runConfigAction(card, 'status', null, { silent: true }), 700);
      }
    } else {
      setServiceState(card, 'error', data.error || 'Aktion fehlgeschlagen.');
      if (!options.silent) {
        showActionResult(card, 'warn', data.error || 'Aktion fehlgeschlagen.', data.response || data);
      }
    }
  } catch (e) {
    setServiceState(card, 'error', e?.message || e);
    if (!options.silent) {
      showActionResult(card, 'warn', 'Aktion fehlgeschlagen: ' + (e?.message || e));
    }
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.innerHTML = oldHtml;
    }
  }
}

function populateActions(card, map) {
  const list = card.querySelector('.actions-list');
  if (!list) return;

  list.innerHTML = '';
  Object.keys(map || {}).forEach(tok => addActionRow(list, tok, map[tok] || []));

  const addBtn = card.querySelector('.btn-action-add');
  if (addBtn && !addBtn._bound) {
    addBtn._bound = true;
    addBtn.addEventListener('click', () => {
      if (READ_ONLY_MODE) return;
      addActionRow(list, '', []);
    });
  }

  const safeSvcBtn = card.querySelector('.btn-service-actions-safe');
  if (safeSvcBtn && !safeSvcBtn._bound) {
    safeSvcBtn._bound = true;
    safeSvcBtn.addEventListener('click', () => setServiceActions(card, 'safe'));
  }

  const fullSvcBtn = card.querySelector('.btn-service-actions-full');
  if (fullSvcBtn && !fullSvcBtn._bound) {
    fullSvcBtn._bound = true;
    fullSvcBtn.addEventListener('click', () => setServiceActions(card, 'full'));
  }

  card.querySelectorAll('[data-service-cmd]').forEach(btn => {
    if (btn._bound) return;
    btn._bound = true;
    btn.addEventListener('click', () => runConfigAction(card, btn.getAttribute('data-service-cmd'), btn));
  });

  ['[data-field="service"]', '[data-field="category"]'].forEach(sel => {
    const el = card.querySelector(sel);
    if (el && !el._svcBound) {
      el._svcBound = true;
      el.addEventListener('input', () => updateServiceControls(card));
      el.addEventListener('change', () => updateServiceControls(card));
    }
  });

  if (!list._bound) {
    list._bound = true;
    list.addEventListener('click', function(e) {
      if (READ_ONLY_MODE) return;

      const row = e.target.closest('.actions-row');
      if (!row) return;

      if (e.target.closest('.btn-run-action')) {
        const tok = (row.querySelector('.token')?.value || '').trim();
        runConfigAction(card, tok, e.target.closest('.btn-run-action'));
        return;
      }
      if (e.target.closest('.btn-remove')) { row.remove(); updateServiceControls(card); }
      if (e.target.closest('.btn-up') && row.previousElementSibling) { row.parentElement.insertBefore(row, row.previousElementSibling); updateServiceControls(card); }
      if (e.target.closest('.btn-down') && row.nextElementSibling) { row.parentElement.insertBefore(row.nextElementSibling, row); updateServiceControls(card); }
    });
  }

  updateServiceControls(card);
}

// -------------------- Form collect/render --------------------
function sortedKeysByCatThenId(obj) {
  return Object.keys(obj || {}).sort((a, b) => {
    const ca = (obj[a]?.category || '').localeCompare(obj[b]?.category || '');
    return ca !== 0 ? ca : a.localeCompare(b);
  });
}

function updateKnownCatsDatalist(dataObj) {
  const dl = document.getElementById('knownCategoriesList');
  if (!dl) return;

  const set = {};
  (KNOWN_CATEGORIES || []).forEach(c => set[c] = 1);
  Object.keys(dataObj || {}).forEach(k => {
    const c = dataObj[k];
    if (c && c.category) set[c.category] = 1;
  });

  const arr = Object.keys(set).filter(Boolean).sort((a, b) => a.localeCompare(b));
  dl.innerHTML = arr.map(c => '<option value="' + esc(c) + '"></option>').join('');
}

function activeConfigCard() {
  return document.querySelector('#cards .cfg-detail-card');
}

function renderSelectedEditor() {
  const host = document.getElementById('cards');
  const empty = document.getElementById('cfgDetailEmpty');
  if (!host) return;

  if (!ACTIVE_CFG_ID || !Object.prototype.hasOwnProperty.call(CFG_DATA, ACTIVE_CFG_ID)) {
    host.innerHTML = '';
    if (empty) empty.classList.remove('d-none');
    return;
  }
  if (empty) empty.classList.add('d-none');

  const id = ACTIVE_CFG_ID;
  const cfg = CFG_DATA[id] || {};
  const catCls = categoryClass(cfg.category || '');
  const svcInfo = serviceKindInfo(cfg.service || '');
  const actionsCount = Object.keys(actionsToMap(cfg.actions)).length;
  const disabled = READ_ONLY_MODE ? ' disabled' : '';

  host.innerHTML = ''
    + '<div class="accordion-item cfg-detail-card" data-cfg-id="' + esc(id) + '" data-original-id="' + esc(id) + '">'
    + '  <header class="cfg-detail-header">'
    + '    <div class="cfg-detail-title">'
    + '      <span class="cfg-detail-icon"><i class="bi bi-file-earmark-code"></i></span>'
    + '      <div><div class="cfg-detail-title-line"><h2 data-summary-id>' + esc(id) + '</h2><span class="chip badge-pill cfg-category-chip ' + catCls + '" data-cat-chip><i class="bi bi-folder2"></i><span class="cat-chip-text">' + esc(cfg.category || 'keine Kategorie') + '</span></span></div>'
    + '      <p data-summary-path title="' + esc(cfg.path || '') + '">' + esc(cfg.path || 'Kein Dateipfad gesetzt') + '</p></div>'
    + '    </div>'
    + '    <div class="cfg-detail-header-meta">'
    + '      <span class="chip badge-pill cfg-kind-chip ' + svcInfo.cls + '" data-service-kind-chip><i class="bi ' + svcInfo.icon + '" data-service-kind-icon></i><span data-service-kind-text>' + esc(svcInfo.label) + '</span></span>'
    + '      <span class="chip badge-pill cfg-action-count-chip"><i class="bi bi-lightning-charge"></i><span data-actions-count>' + actionsCount + '</span> Aktionen</span>'
    + '      <button type="button" class="btn btn-sm btn-outline-secondary mmbb-btn" data-detail-action="duplicate" title="Eintrag duplizieren"' + disabled + '><i class="bi bi-files"></i></button>'
    + '      <button type="button" class="btn btn-sm btn-outline-danger mmbb-btn" data-detail-action="delete" title="Eintrag löschen"' + disabled + '><i class="bi bi-trash"></i></button>'
    + '    </div>'
    + '  </header>'
    + '  <nav class="configuration-detail-tabs nav nav-pills" role="tablist">'
    + '    <button class="nav-link active" data-bs-toggle="tab" data-bs-target="#cfg-detail-general" type="button"><i class="bi bi-card-list"></i> Allgemein</button>'
    + '    <button class="nav-link" data-bs-toggle="tab" data-bs-target="#cfg-detail-rights" type="button"><i class="bi bi-shield-lock"></i> Rechte</button>'
    + '    <button class="nav-link" data-bs-toggle="tab" data-bs-target="#cfg-detail-actions" type="button"><i class="bi bi-lightning-charge"></i> Aktionen <span class="badge rounded-pill text-bg-light border" data-actions-count>' + actionsCount + '</span></button>'
    + '  </nav>'
    + '  <div class="tab-content configuration-detail-content">'
    + '    <div class="tab-pane fade show active" id="cfg-detail-general" role="tabpanel">'
    + '      <div class="cfg-detail-form-grid">'
    + '        <div><label class="form-label">Interne ID</label><input class="form-control form-control-sm" data-field="id" value="' + esc(id) + '" placeholder="autoreply-agent"' + disabled + '><div class="form-text">Eindeutige ID für Portal und REST-API.</div></div>'
    + '        <div><label class="form-label">Kategorie</label><div class="category-widget"><input type="hidden" data-field="category" value="' + esc(cfg.category || '') + '"><select class="form-select form-select-sm cat-select"' + disabled + '></select><input class="form-control form-control-sm mt-2 cat-input d-none" placeholder="Neue Kategorie"' + disabled + '></div></div>'
    + '        <div class="cfg-field-wide"><label class="form-label">Dateipfad</label><div class="input-group input-group-sm"><span class="input-group-text"><i class="bi bi-file-earmark"></i></span><input class="form-control font-monospace" data-field="path" value="' + esc(cfg.path || '') + '" placeholder="/opt/mmbb_services/anwendung/config.json"' + disabled + '></div></div>'
    + '        <div class="cfg-field-wide"><label class="form-label">Service oder Runner <span class="text-muted fw-normal">(optional)</span></label><input class="form-control form-control-sm font-monospace" data-field="service" value="' + esc(cfg.service || '') + '" placeholder="postfix.service oder perl:/opt/mmbb_script/tool.pl"' + disabled + '><div class="form-text">Leer für reine Dateien. systemd-Unit oder fester Runner für Aktionen.</div></div>'
    + '      </div>'
    + '      <div class="service-control-panel d-none mt-3">'
    + '        <div class="service-control-head"><div><span class="service-title"><i class="bi bi-hdd-network"></i> Service-Steuerung</span><span class="service-name" data-service-name></span></div><span class="chip badge-pill service-state-chip service-state-unknown" data-service-state-chip><i class="bi bi-activity"></i><span data-service-state-text>unbekannt</span></span></div>'
    + '        <div class="service-control-buttons"><button type="button" class="btn btn-sm btn-outline-secondary" data-service-cmd="status"><i class="bi bi-activity"></i> Status</button><button type="button" class="btn btn-sm btn-outline-success" data-service-cmd="start"><i class="bi bi-play-fill"></i> Start</button><button type="button" class="btn btn-sm btn-outline-warning" data-service-cmd="stop"><i class="bi bi-stop-fill"></i> Stop</button><button type="button" class="btn btn-sm btn-outline-primary" data-service-cmd="reload"><i class="bi bi-arrow-clockwise"></i> Reload</button><button type="button" class="btn btn-sm btn-outline-danger" data-service-cmd="restart"><i class="bi bi-arrow-repeat"></i> Restart</button></div>'
    + '        <div class="service-control-hint" data-service-actions-hint></div>'
    + '      </div>'
    + '    </div>'
    + '    <div class="tab-pane fade" id="cfg-detail-rights" role="tabpanel">'
    + '      <div class="cfg-rights-intro"><i class="bi bi-info-circle"></i><span>Diese Werte werden nach dem Speichern auf die verwaltete Datei angewendet.</span></div>'
    + '      <div class="cfg-rights-grid"><div><label class="form-label">Besitzer</label><input class="form-control form-control-sm" data-field="user" value="' + esc(cfg.user || '') + '" placeholder="root"' + disabled + '></div><div><label class="form-label">Gruppe</label><input class="form-control form-control-sm" data-field="group" value="' + esc(cfg.group || '') + '" placeholder="taskmgmt"' + disabled + '></div><div><label class="form-label">Modus (oktal)</label><input class="form-control form-control-sm font-monospace" data-field="mode" value="' + esc(cfg.mode || '') + '" placeholder="0640" maxlength="4"' + disabled + '></div></div>'
    + '      <div class="cfg-mode-preview" data-mode-preview><strong>' + esc(cfg.mode || '—') + '</strong><span>' + esc(permissionModeDescription(cfg.mode || '')) + '</span></div>'
    + '    </div>'
    + '    <div class="tab-pane fade" id="cfg-detail-actions" role="tabpanel">'
    + '      <div class="cfg-actions-toolbar"><div><strong>Erlaubte Aktionen</strong><small>Nur gespeicherte Aktionen können ausgeführt werden.</small></div><div class="btn-group btn-group-sm"><button type="button" class="btn btn-outline-success btn-service-actions-safe"' + disabled + '>Standard-Service</button><button type="button" class="btn btn-outline-secondary btn-service-actions-full"' + disabled + '>Mit Start/Stop</button><button type="button" class="btn btn-outline-primary btn-action-add"' + disabled + '><i class="bi bi-plus-circle"></i> Aktion</button></div></div>'
    + '      <div class="actions-table-head d-none" data-actions-table-head><span>Aktion</span><span>Argumente</span><span>Werkzeuge</span></div>'
    + '      <div class="actions-list"></div>'
    + '      <div class="cfg-actions-empty d-none" data-actions-empty><i class="bi bi-inbox"></i><div><strong>Keine Aktionen konfiguriert</strong><span>Eine Aktion hinzufügen oder eine Service-Vorlage anwenden.</span></div></div>'
    + '      <div class="action-result mt-3"></div>'
    + '    </div>'
    + '  </div>'
    + '</div>';

  const card = activeConfigCard();
  populateActions(card, actionsToMap(cfg.actions));
  bindCategoryWidget(card, cfg.category || '');

  const onEdit = () => {
    DETAIL_DIRTY = true;
    markManagedDirty();
    updateCardSummary(card);
    updateServiceControls(card);
    updateModePreview(card);
    syncActiveEditorToModel({silent:true});
    renderConfigNavigator();
  };
  card.querySelectorAll('[data-field]').forEach(el => {
    el.addEventListener('input', onEdit);
    el.addEventListener('change', onEdit);
  });
  card.querySelector('.actions-list')?.addEventListener('input', onEdit);

  card.querySelector('[data-detail-action="delete"]')?.addEventListener('click', deleteActiveConfig);
  card.querySelector('[data-detail-action="duplicate"]')?.addEventListener('click', duplicateActiveConfig);

  card.querySelectorAll('.configuration-detail-tabs [data-bs-toggle="tab"]').forEach(btn => {
    btn.addEventListener('shown.bs.tab', () => {
      try { localStorage.setItem('cfgEditor.detailTab', btn.getAttribute('data-bs-target') || ''); } catch (_) {}
    });
  });
  try {
    const wanted = localStorage.getItem('cfgEditor.detailTab');
    const btn = wanted ? card.querySelector('.configuration-detail-tabs [data-bs-target="' + wanted + '"]') : null;
    if (btn && window.bootstrap) bootstrap.Tab.getOrCreateInstance(btn).show();
  } catch (_) {}

  updateServiceControls(card);
  updateActionPresentation(card);
  updateCardSummary(card);
  updateModePreview(card);
}

function permissionModeDescription(mode) {
  const raw = String(mode || '').trim();
  if (!/^[0-7]{3,4}$/.test(raw)) return 'Noch kein gültiger Modus gesetzt.';
  const perms = raw.slice(-3);
  const special = raw.length === 4 && raw[0] !== '0' ? ('Sonderbits: ' + raw[0] + ' · ') : '';
  const names = ['Andere', 'Gruppe', 'Besitzer'];
  const parts = perms.split('').reverse().map((d, idx) => {
    const n = Number(d);
    const p = [(n & 4) ? 'lesen' : '', (n & 2) ? 'schreiben' : '', (n & 1) ? 'ausführen' : ''].filter(Boolean).join(', ') || 'kein Zugriff';
    return names[idx] + ': ' + p;
  }).reverse();
  return special + parts.join(' · ');
}

function updateModePreview(card) {
  const box = card?.querySelector('[data-mode-preview]');
  if (!box) return;
  const mode = (card.querySelector('[data-field="mode"]')?.value || '').trim();
  const strong = box.querySelector('strong');
  const span = box.querySelector('span');
  if (strong) strong.textContent = mode || '—';
  if (span) span.textContent = permissionModeDescription(mode);
}

function selectConfig(id) {
  if (!id || !Object.prototype.hasOwnProperty.call(CFG_DATA, id)) return;
  try { syncActiveEditorToModel(); } catch (e) { alert(e.message || e); return; }
  ACTIVE_CFG_ID = id;
  try { localStorage.setItem('cfgEditor.selectedId', id); } catch (_) {}
  renderSelectedEditor();
  renderConfigNavigator();
  autoRefreshServiceStatuses();
}

function duplicateActiveConfig() {
  if (READ_ONLY_MODE || !ACTIVE_CFG_ID) return;
  try { syncActiveEditorToModel(); } catch (e) { alert(e.message || e); return; }
  let candidate = ACTIVE_CFG_ID + '_copy';
  let n = 2;
  while (Object.prototype.hasOwnProperty.call(CFG_DATA, candidate)) candidate = ACTIVE_CFG_ID + '_copy' + n++;
  CFG_DATA[candidate] = JSON.parse(JSON.stringify(CFG_DATA[ACTIVE_CFG_ID] || {}));
  markManagedDirty();
  ACTIVE_CFG_ID = candidate;
  updateFilterOptions(CFG_DATA);
  renderSelectedEditor();
  renderConfigNavigator();
  activeConfigCard()?.querySelector('[data-field="id"]')?.select();
}

function deleteActiveConfig() {
  if (READ_ONLY_MODE || !ACTIVE_CFG_ID) return;
  const id = ACTIVE_CFG_ID;
  if (!confirm('Eintrag "' + id + '" wirklich löschen?')) return;
  const ordered = sortedKeysByCatThenId(CFG_DATA);
  const idx = ordered.indexOf(id);
  delete CFG_DATA[id];
  markManagedDirty();
  const left = sortedKeysByCatThenId(CFG_DATA);
  ACTIVE_CFG_ID = left[Math.min(Math.max(idx, 0), Math.max(left.length - 1, 0))] || '';
  updateFilterOptions(CFG_DATA);
  renderSelectedEditor();
  renderConfigNavigator();
}

function renderForm(dataObj) {
  CFG_DATA = JSON.parse(JSON.stringify((dataObj && typeof dataObj === 'object') ? dataObj : {}));
  updateFilterOptions(CFG_DATA);
  updateKnownCatsDatalist(CFG_DATA);
  let saved = '';
  try { saved = localStorage.getItem('cfgEditor.selectedId') || ''; } catch (_) {}
  if (ACTIVE_CFG_ID && Object.prototype.hasOwnProperty.call(CFG_DATA, ACTIVE_CFG_ID)) {
    // aktuelle Auswahl behalten
  } else if (saved && Object.prototype.hasOwnProperty.call(CFG_DATA, saved)) {
    ACTIVE_CFG_ID = saved;
  } else {
    ACTIVE_CFG_ID = sortedKeysByCatThenId(CFG_DATA)[0] || '';
  }
  renderSelectedEditor();
  renderConfigNavigator();
  updateConfigSummary();
}

function collectForm() {
  syncActiveEditorToModel();
  return JSON.parse(JSON.stringify(CFG_DATA));
}

function validateFormData(obj) {
  for (const id in obj) {
    if (!validConfigId(id)) {
      throw new Error('Ungültige ID ' + id);
    }

    const cfg = obj[id];

    if (cfg.mode && !validMode(cfg.mode)) {
      throw new Error('Der Modus bei "' + id + '" muss aus 3 oder 4 Oktalziffern bestehen, zum Beispiel 640 oder 0640.');
    }

    if (!cfg.actions || typeof cfg.actions !== 'object') {
      cfg.actions = {};
    }

    Object.keys(cfg.actions).forEach(tok => {
      if (UNSUPPORTED_ACTIONS.has(String(tok).toLowerCase())) {
        delete cfg.actions[tok];
        return;
      }
      if (!validActionToken(tok)) {
        throw new Error('Ungültiger Action Token "' + tok + '" bei ID "' + id + '".');
      }
      if (!Array.isArray(cfg.actions[tok])) {
        cfg.actions[tok] = [];
      }
    });
  }
}

// -------------------- Buttons / Events --------------------
function bindMainButtons() {
  document.getElementById('filterText')?.addEventListener('input', applyFormFilter);
  document.getElementById('filterCat')?.addEventListener('change', applyFormFilter);
  document.getElementById('filterType')?.addEventListener('change', applyFormFilter);

  document.getElementById('btnFilterReset')?.addEventListener('click', () => {
    const fc = document.getElementById('filterCat'); if (fc) fc.value = '';
    const ft = document.getElementById('filterText'); if (ft) ft.value = '';
    const fy = document.getElementById('filterType'); if (fy) fy.value = '';
    applyFormFilter();
  });

  document.getElementById('btnJsonPretty')?.addEventListener('click', () => {
    if (!window.aceEditor) return;
    const parsed = parseJsonSafe(window.aceEditor.getValue());
    if (!parsed) return alert('Ungültiges JSON.');
    window.aceEditor.setValue(jsonEncodePrettyInline(parsed, '  ', 120, 0), -1);
  });

  document.getElementById('btnJsonToForm')?.addEventListener('click', () => {
    if (!window.aceEditor) return;
    const parsed = parseJsonSafe(window.aceEditor.getValue());
    if (!parsed || typeof parsed !== 'object') return alert('Ungültiges JSON.');
    renderForm(parsed);
    document.querySelector('#tab-form')?.click();
    JSON_DIRTY = false;
  });

  function navigateToServer(serverValue) {
    try {
      localStorage.setItem('cfgEditor.activeTab', document.querySelector('.mmbb-content-tabs .nav-link.active')?.id || 'tab-form');
      localStorage.setItem('cfgEditor.selectedId', ACTIVE_CFG_ID || '');
    } catch (_) {}
    const url = new URL(window.location.href);
    url.searchParams.set('server_idx', serverValue || '0');
    const cat = document.getElementById('filterCat')?.value || '';
    if (cat) url.searchParams.set('category', cat); else url.searchParams.delete('category');
    url.hash = '';
    window.location.href = url.toString();
  }

  document.getElementById('btnRefreshServers')?.addEventListener('click', () => {
    if (MANAGED_DIRTY && !confirm('Ungespeicherte Änderungen verwerfen und Serverliste aktualisieren?')) return;
    const url = new URL(window.location.href);
    url.searchParams.set('server_idx', document.getElementById('serverSelect')?.value || '0');
    url.searchParams.delete('load');
    window.location.href = url.toString();
  });
  document.getElementById('btnReloadServer')?.addEventListener('click', loadManagedConfigs);
  document.getElementById('serverSelect')?.addEventListener('change', event => {
    const select = event.currentTarget;
    const previous = select.dataset.previousValue || SERVER_IDX;
    if (MANAGED_DIRTY && !confirm('Ungespeicherte Änderungen verwerfen und Zielserver wechseln?')) {
      select.value = previous;
      return;
    }
    select.dataset.previousValue = select.value;
    resetManagedLoadedState();
  });

  document.getElementById('btnAddEntry')?.addEventListener('click', () => {
    if (READ_ONLY_MODE) return;
    try { syncActiveEditorToModel(); } catch (e) { alert(e.message || e); return; }
    let id = 'new_entry';
    let n = 2;
    while (Object.prototype.hasOwnProperty.call(CFG_DATA, id)) id = 'new_entry_' + n++;
    const category = document.getElementById('filterCat')?.value || 'uncategorized';
    CFG_DATA[id] = {path:'', category, service:'', user:'root', group:'root', mode:'0640', actions:{}};
    markManagedDirty();
    ACTIVE_CFG_ID = id;
    updateFilterOptions(CFG_DATA);
    renderSelectedEditor();
    renderConfigNavigator();
    const idInput = activeConfigCard()?.querySelector('[data-field="id"]');
    idInput?.focus(); idInput?.select();
  });

  const tabJson = document.getElementById('tab-json');
  const tabForm = document.getElementById('tab-form');

  tabForm?.addEventListener('show.bs.tab', e => {
    if (e.relatedTarget?.id === 'tab-json') {
      const parsed = parseJsonSafe(window.aceEditor?.getValue() || '');
      if (!parsed || typeof parsed !== 'object') {
        if (JSON_DIRTY) { e.preventDefault(); alert('Ungültiges JSON. Bitte korrigieren.'); }
        return;
      }
      renderForm(parsed);
      JSON_DIRTY = false;
      try { localStorage.removeItem('cfgEditor.jsonDirty'); } catch (_) {}
    }
    try { localStorage.setItem('cfgEditor.activeTab', 'tab-form'); } catch (_) {}
  });

  tabJson?.addEventListener('show.bs.tab', e => {
    if (e.relatedTarget?.id === 'tab-form') {
      try {
        const obj = collectForm();
        window.aceEditor?.setValue(jsonEncodePrettyInline(obj, '  ', 120, 0), -1);
      } catch (ex) { e.preventDefault(); alert(ex.message || ex); }
    }
    try { localStorage.setItem('cfgEditor.activeTab', 'tab-json'); } catch (_) {}
  });
  tabJson?.addEventListener('shown.bs.tab', () => focusAceReliably(12));

  document.getElementById('cfgForm')?.addEventListener('submit', e => {
    e.preventDefault();
    saveManagedConfigs();
  });

  window.addEventListener('beforeunload', event => {
    try { syncActiveEditorToModel({silent:true}); localStorage.setItem('cfgEditor.selectedId', ACTIVE_CFG_ID || ''); } catch (_) {}
    saveAceState(); saveWindowScroll();
    if (MANAGED_DIRTY) { event.preventDefault(); event.returnValue = ''; }
  });
  window.addEventListener('error', e => console.error('JS Error:', e.error || e.message));

  document.querySelectorAll('.alert[data-autohide]').forEach(el => {
    const ms = parseInt(el.getAttribute('data-autohide'), 10) || 0;
    if (ms > 0) setTimeout(() => { try { bootstrap.Alert.getOrCreateInstance(el).close(); } catch (_) { el.remove(); } }, ms);
  });
}

function autoRefreshServiceStatuses() {
  const card = activeConfigCard();
  if (card && serviceShouldBeVisible(card) && serviceValueFromCard(card) && cardHasAction(card, 'status')) {
    window.setTimeout(() => runConfigAction(card, 'status', null, {silent:true}), 180);
  }
}


function managedCurrentContent() {
  const activeTab = document.querySelector('.mmbb-content-tabs .nav-link.active')?.id || '';
  let obj;
  if (activeTab === 'tab-json' || JSON_DIRTY) {
    obj = parseJsonSafe(window.aceEditor?.getValue() || '');
    if (!obj || typeof obj !== 'object') throw new Error('Ungültiges JSON.');
  } else {
    obj = collectForm();
  }
  validateFormData(obj);
  return JSON.stringify(obj);
}

function updateManagedUiState() {
  const loaded = MANAGED_LOADED && !READ_ONLY_MODE;
  document.body.classList.toggle('cfg-not-loaded', !MANAGED_LOADED);
  ['btnAddEntry','btnValidateManaged','btnSaveManaged','btnSaveManagedJson','filterText','filterCat','filterType','btnFilterReset','btnJsonPretty','btnJsonToForm'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.disabled = MANAGED_BUSY || !loaded;
  });
  const load = document.getElementById('btnReloadServer');
  if (load) load.disabled = MANAGED_BUSY || !document.getElementById('serverSelect')?.value;
  const server = document.getElementById('serverSelect');
  if (server) server.disabled = MANAGED_BUSY;
  const refresh = document.getElementById('btnRefreshServers');
  if (refresh) refresh.disabled = MANAGED_BUSY;
  if (window.aceEditor) window.aceEditor.setReadOnly(MANAGED_BUSY || !loaded);
}

function markManagedDirty() {
  if (!MANAGED_LOADED || MANAGED_HYDRATING) return;
  MANAGED_DIRTY = true;
  updateManagedUiState();
}

function resetManagedLoadedState() {
  MANAGED_HYDRATING = true;
  MANAGED_LOADED = false;
  MANAGED_DIRTY = false;
  JSON_DIRTY = false;
  DETAIL_DIRTY = false;
  CFG_DATA = {};
  ACTIVE_CFG_ID = '';
  renderForm({});
  window.aceEditor?.setValue('{}', -1);
  document.getElementById('cfgNavigatorEmpty')?.classList.remove('d-none');
  const navEmpty = document.getElementById('cfgNavigatorEmpty');
  if (navEmpty) {
    navEmpty.querySelector('strong').textContent = 'Noch keine Konfiguration geladen';
    navEmpty.querySelector('span').textContent = 'Zuerst managed_configs.json vom Zielserver laden.';
  }
  const detailEmpty = document.getElementById('cfgDetailEmpty');
  detailEmpty?.classList.remove('d-none');
  if (detailEmpty) {
    detailEmpty.querySelector('h3').textContent = 'Keine Datei geladen';
    detailEmpty.querySelector('p').textContent = 'Zielserver wählen und anschliessend „Vom Server laden“ verwenden.';
  }
  MANAGED_HYDRATING = false;
  updateManagedUiState();
}

async function loadManagedConfigs() {
  const idx = document.getElementById('serverSelect')?.value || '';
  if (!idx) return;
  if (MANAGED_DIRTY && !confirm('Ungespeicherte Änderungen verwerfen und neu laden?')) return;
  MANAGED_BUSY = true;
  updateManagedUiState();
  try {
    const data = await cfgFetchJson('configs_editor.php?api=managed_get&server_idx=' + encodeURIComponent(idx));
    MANAGED_HYDRATING = true;
    renderForm(data.config || {});
    window.aceEditor?.setValue(String(data.content || '{}'), -1);
    JSON_DIRTY = false;
    DETAIL_DIRTY = false;
    MANAGED_LOADED = true;
    MANAGED_DIRTY = false;
    document.getElementById('cfgNavigatorEmpty')?.classList.toggle('d-none', Object.keys(CFG_DATA).length > 0);
    MANAGED_HYDRATING = false;
  } catch (error) {
    MANAGED_HYDRATING = false;
    resetManagedLoadedState();
    alert(error.message || String(error));
  } finally {
    MANAGED_BUSY = false;
    updateManagedUiState();
  }
}

async function validateManagedConfigs() {
  if (!MANAGED_LOADED) return;
  let content;
  try { content = managedCurrentContent(); }
  catch (error) { return alert(error.message || String(error)); }
  MANAGED_BUSY = true;
  updateManagedUiState();
  try {
    const body = new URLSearchParams({ajax_action:'validate_managed', csrf_token:CSRF_TOKEN, json_content:content});
    const data = await cfgFetchJson('configs_editor.php?server_idx=' + encodeURIComponent(document.getElementById('serverSelect')?.value || ''), {
      method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8','X-CSRF-Token':CSRF_TOKEN}, body:body.toString()
    });
    alert('managed_configs.json ist gültig. ' + String(data.summary?.entries ?? 0) + ' Eintrag/Einträge.');
  } catch (error) {
    alert(error.message || String(error));
  } finally { MANAGED_BUSY = false; updateManagedUiState(); }
}

async function saveManagedConfigs() {
  if (!MANAGED_LOADED || READ_ONLY_MODE) return;
  let content;
  try { content = managedCurrentContent(); }
  catch (error) { return alert(error.message || String(error)); }
  const serverName = document.getElementById('serverSelect')?.selectedOptions[0]?.textContent || 'dem Server';
  if (!confirm('managed_configs.json auf ' + serverName + ' speichern? Vorher wird automatisch ein Backup erstellt.')) return;
  MANAGED_BUSY = true;
  updateManagedUiState();
  try {
    const idx = document.getElementById('serverSelect')?.value || '';
    const body = new URLSearchParams({ajax_action:'save_managed', csrf_token:CSRF_TOKEN, json_content:content});
    const data = await cfgFetchJson('configs_editor.php?server_idx=' + encodeURIComponent(idx), {
      method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8','X-CSRF-Token':CSRF_TOKEN}, body:body.toString()
    });
    MANAGED_DIRTY = false;
    await loadManagedConfigs();
    alert(data.audit_error ? 'Gespeichert. Audit-Warnung: ' + data.audit_error : 'managed_configs.json wurde gespeichert und neu geladen.');
  } catch (error) {
    alert(error.message || String(error));
  } finally { MANAGED_BUSY = false; updateManagedUiState(); }
}

// -------------------- Init --------------------
document.addEventListener('DOMContentLoaded', function() {
  const managedServerSelect = document.getElementById('serverSelect');
  if (managedServerSelect) managedServerSelect.dataset.previousValue = managedServerSelect.value;

  window.aceEditor = window.MMBBConfigurationJsonEditor.create('jsonEditor');

  window.aceEditor.setValue(<?= json_encode($rawJsonPretty, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>, -1);

  try {
    JSON_DIRTY = localStorage.getItem('cfgEditor.jsonDirty') === '1';
  } catch (_) {}

  window.aceEditor.session.on('change', function() {
    if (MANAGED_HYDRATING || !MANAGED_LOADED) return;
    JSON_DIRTY = true;
    markManagedDirty();
    try {
      localStorage.setItem('cfgEditor.jsonDirty', '1');
    } catch (_) {}
  });

  renderForm({});
  resetManagedLoadedState();
  updateAllServiceControls();

  restoreUiState();
  restoreWindowScroll();
  forceReturnToJsonIfNeeded();

  bindMainButtons();
  document.getElementById('btnValidateManaged')?.addEventListener('click', validateManagedConfigs);
  document.getElementById('btnSaveManaged')?.addEventListener('click', saveManagedConfigs);
  document.getElementById('btnSaveManagedJson')?.addEventListener('click', saveManagedConfigs);

});

window.addEventListener('pageshow', function() {
  restoreWindowScroll();
  forceReturnToJsonIfNeeded();
});


// =======================================================
// Registry-Backups (Portal 3.0.0)
// =======================================================
const cfgBackupState = {items: [], selected: '', loaded: false};
const cfgBackupList = document.getElementById('cfgBackupList');
const cfgBackupEmpty = document.getElementById('cfgBackupEmpty');
const cfgBackupCount = document.getElementById('cfgBackupCount');
const cfgBackupListCount = document.getElementById('cfgBackupListCount');
const cfgBackupTitle = document.getElementById('cfgBackupTitle');
const cfgBackupMeta = document.getElementById('cfgBackupMeta');
const cfgBackupPreview = document.getElementById('cfgBackupPreview');
const cfgBackupMessage = document.getElementById('cfgBackupMessage');
const cfgRestoreBackup = document.getElementById('cfgRestoreBackup');
const cfgLoadBackups = document.getElementById('cfgLoadBackups');

function cfgBackupAlert(kind, text) {
  if (!cfgBackupMessage) return;
  cfgBackupMessage.className = 'alert alert-' + kind + ' mt-3 mb-0';
  cfgBackupMessage.textContent = text;
}

function cfgBackupClearAlert() {
  if (!cfgBackupMessage) return;
  cfgBackupMessage.className = 'alert d-none mt-3 mb-0';
  cfgBackupMessage.textContent = '';
}

function cfgRenderBackupList() {
  if (!cfgBackupList) return;
  cfgBackupCount.textContent = String(cfgBackupState.items.length);
  cfgBackupListCount.textContent = String(cfgBackupState.items.length);
  cfgBackupList.innerHTML = cfgBackupState.items.map(name => {
    const active = name === cfgBackupState.selected;
    return '<button type="button" class="configuration-backup-item' + (active ? ' active' : '') + '" data-backup-name="' + esc(name) + '" role="option" aria-selected="' + (active ? 'true' : 'false') + '">' +
      '<span class="configuration-backup-icon"><i class="bi bi-file-earmark-zip"></i></span>' +
      '<span><strong>' + esc(name) + '</strong><small>managed_configs.json</small></span>' +
      '<i class="bi bi-chevron-right"></i></button>';
  }).join('');
  cfgBackupEmpty.classList.toggle('d-none', cfgBackupState.items.length > 0);
  cfgBackupList.querySelectorAll('[data-backup-name]').forEach(btn => {
    btn.addEventListener('click', () => cfgSelectBackup(btn.getAttribute('data-backup-name') || ''));
  });
}

async function cfgFetchJson(url, options = {}) {
  const response = await fetch(url, {credentials: 'same-origin', cache: 'no-store', ...options});
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.ok === false) throw new Error(data.error || 'Anfrage fehlgeschlagen.');
  return data;
}

async function cfgLoadBackupList(showMessage = true) {
  const idx = document.getElementById('serverSelect')?.value || '';
  if (!idx) return;
  cfgLoadBackups.disabled = true;
  try {
    const data = await cfgFetchJson('configs_editor.php?api=managed_backups&server_idx=' + encodeURIComponent(idx));
    cfgBackupState.items = Array.isArray(data.backups) ? data.backups : [];
    cfgBackupState.loaded = true;
    if (!cfgBackupState.items.includes(cfgBackupState.selected)) cfgBackupState.selected = '';
    cfgRenderBackupList();
    if (showMessage) cfgBackupAlert('success', cfgBackupState.items.length + ' Backup(s) geladen.');
  } catch (error) {
    cfgBackupState.items = [];
    cfgRenderBackupList();
    cfgBackupAlert('danger', error.message || String(error));
  } finally {
    cfgLoadBackups.disabled = false;
  }
}

async function cfgSelectBackup(name) {
  const idx = document.getElementById('serverSelect')?.value || '';
  if (!idx || !name) return;
  cfgBackupState.selected = name;
  cfgRenderBackupList();
  cfgBackupTitle.textContent = name;
  cfgBackupMeta.textContent = 'Inhalt wird geladen …';
  cfgBackupPreview.textContent = 'Backup wird geladen …';
  cfgRestoreBackup.disabled = true;
  cfgBackupClearAlert();
  try {
    const data = await cfgFetchJson('configs_editor.php?api=managed_backup_get&server_idx=' + encodeURIComponent(idx) + '&filename=' + encodeURIComponent(name));
    const backup = data.backup || {};
    const content = String(backup.content || '');
    try { cfgBackupPreview.textContent = JSON.stringify(JSON.parse(content), null, 2); }
    catch (_) { cfgBackupPreview.textContent = content; }
    cfgBackupMeta.textContent = String(backup.entries ?? '—') + ' Einträge · managed_configs.json';
    cfgRestoreBackup.disabled = false;
  } catch (error) {
    cfgBackupPreview.textContent = 'Die Backup-Vorschau konnte nicht geladen werden.';
    cfgBackupMeta.textContent = 'Vorschau nicht verfügbar';
    cfgBackupAlert('danger', error.message || String(error));
  }
}

async function cfgRestoreSelectedBackup() {
  const idx = document.getElementById('serverSelect')?.value || '';
  const name = cfgBackupState.selected;
  if (!idx || !name) return;
  if (!window.confirm(name + ' wiederherstellen? Der aktuelle Stand wird vorher erneut gesichert.')) return;
  cfgRestoreBackup.disabled = true;
  try {
    const body = new URLSearchParams({ajax_action: 'restore_managed_backup', csrf_token: CSRF_TOKEN, filename: name});
    const data = await cfgFetchJson('configs_editor.php?server_idx=' + encodeURIComponent(idx), {
      method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8', 'X-CSRF-Token': CSRF_TOKEN}, body: body.toString()
    });
    cfgBackupAlert(data.audit_error ? 'warning' : 'success', data.audit_error ? 'Backup wiederhergestellt; Audit-Warnung: ' + data.audit_error : name + ' wurde wiederhergestellt.');
    MANAGED_DIRTY = false;
    window.setTimeout(() => loadManagedConfigs(), 350);
  } catch (error) {
    cfgBackupAlert('danger', error.message || String(error));
    cfgRestoreBackup.disabled = false;
  }
}

cfgLoadBackups?.addEventListener('click', () => cfgLoadBackupList(true));
cfgRestoreBackup?.addEventListener('click', cfgRestoreSelectedBackup);
document.getElementById('tab-backups')?.addEventListener('shown.bs.tab', () => {
  if (!cfgBackupState.loaded) cfgLoadBackupList(false);
});

</script>
</body>
</html>
