<?php
declare(strict_types=1);

// Config Manager Portal 3.25.0 - geführter Git-Deploy-Workflow

require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../autoloader.php';
require_once __DIR__ . '/../Repository/ConfigManagerRepository.php';
require_once __DIR__ . '/../Service/ConfigManagerService.php';
require_once __DIR__ . '/../Controller/ConfigManagerController.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';
require_once __DIR__ . '/../lib/deploy_profiles.php';

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

function gd_h(mixed $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function gd_json_out(array $payload, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('Pragma: no-cache');
    header('Expires: 0');
    header('X-Content-Type-Options: nosniff');

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

function gd_actor(): string
{
    foreach (['user_id', 'username', 'user', 'login'] as $key) {
        $value = trim((string)($_SESSION[$key] ?? ''));
        if ($value !== '') {
            return substr(preg_replace('/[\x00-\x1f\x7f]/', '?', $value) ?? 'portal-user', 0, 128);
        }
    }
    return 'portal-user';
}

function gd_controller_for(array $server): ConfigManagerController
{
    $repo = new ConfigManagerRepository($server);
    $service = new ConfigManagerService($repo);
    return new ConfigManagerController($service);
}

function gd_service_for(array $server): ConfigManagerService
{
    return new ConfigManagerService(new ConfigManagerRepository($server));
}

function gd_deployment_id(string $value): string
{
    $value = trim($value);
    if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $value)) {
        throw new InvalidArgumentException('Ungültige Deployment-ID.');
    }
    return $value;
}

function gd_commit_sha(string $value): string
{
    $value = strtolower(trim($value));
    if ($value === '' || $value === 'auto') {
        return 'auto';
    }
    if (!preg_match('/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/', $value)) {
        throw new InvalidArgumentException('Commit muss automatisch gewählt werden oder eine vollständige SHA sein.');
    }
    return $value;
}

function gd_sync_central_profiles(ConfigManagerController $controller): array
{
    $central = dp_content();
    try {
        $current = $controller->getGitDeployConfig();
        $currentContent = (string)($current['content'] ?? '');
        if ($currentContent !== '') {
            try {
                if (hash_equals(hash('sha256', $central), hash('sha256', dp_encode(dp_decode_content($currentContent))))) {
                    return ['changed' => false];
                }
            } catch (Throwable $ignore) {
                // Ungültiger Altstand wird durch den zentralen Katalog ersetzt.
            }
        }
    } catch (Throwable $ignore) {
        // Save liefert die autoritative Fehlermeldung, falls der Agent nicht erreichbar ist.
    }
    $result = $controller->saveGitDeployConfig($central);
    return ['changed' => true, 'result' => $result];
}

function gd_token(string $value): string
{
    if ($value === '') {
        return '';
    }
    if (strlen($value) > 4096 || preg_match('/[\x00-\x20\x7f]/', $value)) {
        throw new InvalidArgumentException('Deploy-Token enthält ungültige Zeichen.');
    }
    return $value;
}

function gd_read_json_body(): array
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

function gd_redact(mixed $value, string $secret): mixed
{
    if ($secret === '') {
        return $value;
    }
    if (is_string($value)) {
        return str_replace($secret, '[REDACTED]', $value);
    }
    if (is_array($value)) {
        foreach ($value as $key => $item) {
            $value[$key] = gd_redact($item, $secret);
        }
    }
    return $value;
}

$portalConfigFile = __DIR__ . '/../config/config.php';

try {
    $servers = cm_load_config_manager_servers($portalConfigFile);
} catch (Throwable $e) {
    if (isset($_GET['api']) || isset($_POST['api'])) {
        gd_json_out(['ok' => false, 'error' => $e->getMessage()], 500);
    }
    http_response_code(500);
    exit('Config-Manager-Konfiguration konnte nicht geladen werden: ' . gd_h($e->getMessage()));
}

// Git-Deploy kann optional auf eine strengere Portal-Berechtigung als das
// restliche Config-Manager-Modul eingeschränkt werden.
$portalConfig = require $portalConfigFile;
$requiredService = trim((string)($portalConfig['git_deploy']['required_service'] ?? ''));
$requiredService = $requiredService !== '' ? $requiredService : 'ConfigManager';
if (function_exists('mmbb_has_service') && !mmbb_has_service($requiredService)) {
    if (isset($_GET['api']) || $_SERVER['REQUEST_METHOD'] === 'POST') {
        gd_json_out(['ok' => false, 'error' => 'Keine Berechtigung für Git Deploy.'], 403);
    }
    http_response_code(403);
    exit('Keine Berechtigung für Git Deploy.');
}

$gitExampleFile = __DIR__ . '/../config/git_deploy.example.json';
$gitExample = is_file($gitExampleFile) ? (string)file_get_contents($gitExampleFile) : '';

if (isset($_GET['download']) && $_GET['download'] === 'git_example') {
    $content = $gitExample;
    $filename = 'git_deploy.example.json';
    if ($content === '') {
        http_response_code(404);
        exit('Beispieldatei nicht gefunden.');
    }
    header('Content-Type: application/json; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . $filename . '"');
    header('Content-Length: ' . strlen($content));
    echo $content;
    exit;
}

$apiAction = trim((string)($_GET['api'] ?? ''));
if ($apiAction !== '') {
    try {
        if ($apiAction === 'inventory') {
            $items = [];
            foreach ($servers as $idx => $server) {
                $item = [
                    'idx' => $idx,
                    'name' => (string)$server['name'],
                    'url' => (string)$server['url'],
                    'online' => false,
                    'version' => '',
                    'git_enabled' => false,
                    'git_degraded' => false,
                    'config_valid' => false,
                    'allow_direct_request' => false,
                    'deploy_token_source' => 'file',
                    'requires_deploy_token' => false,
                    'settings_file' => 'global.json:git_deploy',
                    'profiles_file' => 'git_deploy.json',
                    'config_file' => 'git_deploy.json',
                    'config_generation' => 0,
                    'state_dir' => '',
                    'profiles' => [],
                    'error' => '',
                ];

                try {
                    $service = gd_service_for($server);
                    // Fuer diese Seite ist /git_deployments die autoritative
                    // Erreichbarkeitsprobe. Ein Versions-Endpoint darf einen
                    // funktionierenden Git-Deploy-Agenten nicht als offline
                    // markieren.
                    $deployments = $service->getGitDeployments();
                    $item['online'] = true;
                    $item['version'] = $service->getServerVersion();
                    $item['git_enabled'] = !empty($deployments['enabled']);
                    $item['git_degraded'] = !empty($deployments['degraded']);
                    $item['config_valid'] = !array_key_exists('config_valid', $deployments) || !empty($deployments['config_valid']);
                    $item['allow_direct_request'] = !empty($deployments['allow_direct_request']);
                    $item['deploy_token_source'] = (string)($deployments['deploy_token_source'] ?? 'file');
                    $item['requires_deploy_token'] = !empty($deployments['requires_deploy_token']);
                    $item['settings_file'] = (string)($deployments['settings_file'] ?? 'global.json:git_deploy');
                    $item['profiles_file'] = (string)($deployments['profiles_file'] ?? 'git_deploy.json');
                    $item['config_file'] = (string)($deployments['config_file'] ?? 'git_deploy.json');
                    $item['config_generation'] = (int)($deployments['config_generation'] ?? 0);
                    $item['state_dir'] = (string)($deployments['state_dir'] ?? '');
                    $item['agent_profiles'] = is_array($deployments['profiles'] ?? null)
                        ? array_values($deployments['profiles'])
                        : [];
                    // Deploy-Profile sind portalweit zentral und nicht mehr an einen einzelnen Agenten gebunden.
                    $item['profiles'] = dp_inventory_profiles();
                    if ($item['git_degraded'] || !$item['config_valid']) {
                        $item['error'] = trim((string)(
                            $deployments['settings_error']
                            ?? $deployments['error']
                            ?? 'Git-Deploy-Konfiguration ist degraded.'
                        ));
                    }
                } catch (Throwable $e) {
                    $item['error'] = $e->getMessage();
                }

                $items[] = $item;
            }

            gd_json_out(['ok' => true, 'servers' => $items]);
        }

        if ($apiAction === 'status') {
            $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx === null || !array_key_exists($serverIdx, $servers)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Serverindex.'], 400);
            }
            $deployment = gd_deployment_id((string)($_GET['deployment'] ?? ''));
            $result = gd_controller_for($servers[$serverIdx])->getGitDeployStatus($deployment);
            $code = (int)($result['http_code'] ?? 500);

            gd_json_out([
                'ok' => $code >= 200 && $code < 300,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'http_code' => $code,
                'response' => $result['response'] ?? [],
            ], $code === 404 ? 200 : ($code >= 400 ? min($code, 599) : 200));
        }

        if ($apiAction === 'releases') {
            $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx === null || !array_key_exists($serverIdx, $servers)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Serverindex.'], 400);
            }
            $deployment = gd_deployment_id((string)($_GET['deployment'] ?? ''));
            $releases = gd_controller_for($servers[$serverIdx])->getGitDeployReleases($deployment);
            gd_json_out([
                'ok' => true,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'releases' => $releases,
            ]);
        }

        if ($apiAction === 'profiles_get') {
            $source = 'portal';
            // Upgrade-Pfad: Beim ersten Aufruf einmalig vorhandene Agent-Profile in den
            // zentralen Katalog übernehmen. Danach ist ausschliesslich der Portal-Katalog autoritativ.
            if (!is_file(dp_profiles_file())) {
                foreach ($servers as $server) {
                    try {
                        $legacy = gd_controller_for($server)->getGitDeployConfig();
                        $legacyContent = (string)($legacy['content'] ?? '');
                        if ($legacyContent !== '') {
                            dp_atomic_write($legacyContent, false);
                            $source = 'migrated_from_agent:' . (string)$server['name'];
                            break;
                        }
                    } catch (Throwable $ignore) {
                        // Nächsten Agenten versuchen.
                    }
                }
            }
            $content = dp_content();
            $doc = dp_load();
            gd_json_out([
                'ok' => true,
                'config' => [
                    'content' => $content,
                    'valid' => true,
                    'sha256' => hash('sha256', $content),
                    'source' => $source,
                    'profiles' => count((array)$doc['profiles']),
                ],
            ]);
        }

        if ($apiAction === 'profiles_backups') {
            gd_json_out(['ok' => true, 'backups' => dp_backups()]);
        }

        if ($apiAction === 'profiles_backup_get') {
            gd_json_out(['ok' => true, 'backup' => dp_backup_get(trim((string)($_GET['filename'] ?? '')))]);
        }

        if ($apiAction === 'config_get') {
            $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx === null || !array_key_exists($serverIdx, $servers)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Serverindex.'], 400);
            }
            $result = gd_controller_for($servers[$serverIdx])->getGitDeployConfig();
            gd_json_out([
                'ok' => true,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'config' => $result,
            ]);
        }

        if ($apiAction === 'config_backups') {
            $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx === null || !array_key_exists($serverIdx, $servers)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Serverindex.'], 400);
            }
            $backups = gd_controller_for($servers[$serverIdx])->getGitDeployConfigBackups();
            gd_json_out([
                'ok' => true,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'backups' => $backups,
            ]);
        }

        if ($apiAction === 'config_backup_get') {
            $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx === null || !array_key_exists($serverIdx, $servers)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Serverindex.'], 400);
            }
            $filename = trim((string)($_GET['filename'] ?? ''));
            if (!preg_match('/^git_deploy\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Git-Deploy-Backupname.'], 400);
            }
            $backup = gd_controller_for($servers[$serverIdx])->getGitDeployConfigBackup($filename);
            gd_json_out([
                'ok' => true,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'backup' => $backup,
            ]);
        }

        if ($apiAction === 'repo_list') {
            $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx === null || !array_key_exists($serverIdx, $servers)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Serverindex.'], 400);
            }
            $refresh = filter_var($_GET['refresh'] ?? false, FILTER_VALIDATE_BOOL);
            $repositories = gd_controller_for($servers[$serverIdx])->getGitUploadRepositories($refresh);
            gd_json_out([
                'ok' => true,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'repositories' => $repositories,
            ]);
        }

        if ($apiAction === 'repo_branches') {
            $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx === null || !array_key_exists($serverIdx, $servers)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Serverindex.'], 400);
            }
            $owner = trim((string)($_GET['owner'] ?? ''));
            $repository = trim((string)($_GET['repository'] ?? ''));
            $result = gd_controller_for($servers[$serverIdx])->getGitUploadBranches($owner, $repository);
            gd_json_out(['ok' => true, 'server_idx' => $serverIdx, 'result' => $result]);
        }

        if ($apiAction === 'repo_scan') {
            $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx === null || !array_key_exists($serverIdx, $servers)) {
                gd_json_out(['ok' => false, 'error' => 'Ungültiger Serverindex.'], 400);
            }
            $owner = trim((string)($_GET['owner'] ?? ''));
            $repository = trim((string)($_GET['repository'] ?? ''));
            $branch = trim((string)($_GET['branch'] ?? ''));
            $result = gd_controller_for($servers[$serverIdx])->scanGitRepository($owner, $repository, $branch);
            gd_json_out(['ok' => true, 'server_idx' => $serverIdx, 'server_name' => (string)$servers[$serverIdx]['name'], 'scan' => $result]);
        }

        if (str_starts_with($apiAction, 'settings_')) {
            gd_json_out(['ok' => false, 'error' => 'Allgemeine Git-Einstellungen aus global.json sind im Portal nicht editierbar.'], 403);
        }

        gd_json_out(['ok' => false, 'error' => 'Unbekannte API-Aktion.'], 404);
    } catch (InvalidArgumentException $e) {
        gd_json_out(['ok' => false, 'error' => $e->getMessage()], 400);
    } catch (Throwable $e) {
        gd_json_out(['ok' => false, 'error' => $e->getMessage()], 502);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    try {
        $payload = gd_read_json_body();
        $sentCsrf = (string)($_SERVER['HTTP_X_CSRF_TOKEN'] ?? $payload['csrf_token'] ?? '');
        if ($sentCsrf === '' || !hash_equals($csrfToken, $sentCsrf)) {
            gd_json_out(['ok' => false, 'error' => 'Ungültiges CSRF-Token.'], 403);
        }

        $action = trim((string)($payload['action'] ?? ''));

        if ($action === 'status') {
            $serverIdxRaw = $payload['server_idx'] ?? null;
            if (!is_int($serverIdxRaw) && !(is_string($serverIdxRaw) && preg_match('/^\d+$/', $serverIdxRaw))) {
                throw new InvalidArgumentException('Ungültiger Serverindex.');
            }
            $serverIdx = (int)$serverIdxRaw;
            if (!array_key_exists($serverIdx, $servers)) {
                throw new InvalidArgumentException('Unbekannter Serverindex: ' . $serverIdx);
            }
            $deployment = gd_deployment_id((string)($payload['deployment'] ?? ''));
            $deployToken = gd_token((string)($payload['deploy_token'] ?? ''));
            $result = gd_controller_for($servers[$serverIdx])->getGitDeployStatus($deployment, $deployToken);
            $code = (int)($result['http_code'] ?? 500);
            gd_json_out([
                'ok' => $code >= 200 && $code < 300,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'http_code' => $code,
                'response' => gd_redact($result['response'] ?? [], $deployToken),
            ], $code === 404 ? 200 : ($code >= 400 ? min($code, 599) : 200));
        }

        if ($action === 'release_history') {
            $serverIdxRaw = $payload['server_idx'] ?? null;
            if (!is_int($serverIdxRaw) && !(is_string($serverIdxRaw) && preg_match('/^\d+$/', $serverIdxRaw))) {
                throw new InvalidArgumentException('Ungültiger Serverindex.');
            }
            $serverIdx = (int)$serverIdxRaw;
            if (!array_key_exists($serverIdx, $servers)) {
                throw new InvalidArgumentException('Unbekannter Serverindex: ' . $serverIdx);
            }
            $deployment = gd_deployment_id((string)($payload['deployment'] ?? ''));
            $deployToken = gd_token((string)($payload['deploy_token'] ?? ''));
            $releases = gd_controller_for($servers[$serverIdx])->getGitDeployReleases($deployment, $deployToken);
            gd_json_out([
                'ok' => true,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'releases' => $releases,
            ]);
        }

        if ($action === 'compare') {
            $serverIdxRaw = $payload['server_idx'] ?? null;
            if (!is_int($serverIdxRaw) && !(is_string($serverIdxRaw) && preg_match('/^\d+$/', $serverIdxRaw))) {
                throw new InvalidArgumentException('Ungültiger Serverindex.');
            }
            $serverIdx = (int)$serverIdxRaw;
            if (!array_key_exists($serverIdx, $servers)) throw new InvalidArgumentException('Unbekannter Serverindex: ' . $serverIdx);
            $deployment = gd_deployment_id((string)($payload['deployment'] ?? ''));
            $commitSha = gd_commit_sha((string)($payload['commit_sha'] ?? 'auto'));
            $deployToken = gd_token((string)($payload['deploy_token'] ?? ''));
            $controller = gd_controller_for($servers[$serverIdx]);
            // Vor Compare/Deploy erhält der Agent den zentralen, generischen Profilkatalog.
            $sync = gd_sync_central_profiles($controller);
            $compare = $controller->compareGitDeploy($deployment, $commitSha, $deployToken);
            gd_json_out(['ok'=>true,'server_idx'=>$serverIdx,'server_name'=>(string)$servers[$serverIdx]['name'],'compare'=>$compare]);
        }

        if (in_array($action, ['profiles_validate', 'profiles_save', 'profiles_restore'], true)) {
            if ($action === 'profiles_restore') {
                $filename = trim((string)($payload['filename'] ?? ''));
                $result = dp_restore($filename);
                mmbb_audit_write('deploy_profiles_restore', $filename, ['profiles' => $result['profiles']], 'git_deploy.php', 'ok');
                gd_json_out(['ok' => true, 'action' => $action, 'result' => $result]);
            }

            $content = (string)($payload['content'] ?? '');
            $doc = dp_decode_content($content);
            $warning = '';
            $validatedBy = 'portal';

            // Wenn ein kompatibler Agent erreichbar ist, zusätzlich dessen reale Git-Deploy-Validierung verwenden.
            foreach ($servers as $idx => $server) {
                try {
                    $ctl = gd_controller_for($server);
                    $check = $ctl->validateGitDeployConfig($content);
                    $validatedBy = (string)$server['name'];
                    $warning = trim((string)($check['combined_warning'] ?? $check['config_warning'] ?? ''));
                    break;
                } catch (Throwable $ignore) {
                    // Zentraler Katalog bleibt auch ohne erreichbaren Agenten editierbar.
                }
            }

            if ($action === 'profiles_validate') {
                gd_json_out(['ok' => true, 'result' => ['profiles' => count((array)$doc['profiles']), 'validated_by' => $validatedBy, 'config_warning' => $warning]]);
            }

            $result = dp_atomic_write($content, true);
            $result['validated_by'] = $validatedBy;
            $result['config_warning'] = $warning;
            mmbb_audit_write('deploy_profiles_save', 'deploy_profiles.json', ['profiles' => $result['profiles'], 'sha256' => $result['sha256'], 'validated_by' => $validatedBy], 'git_deploy.php', 'ok');
            gd_json_out(['ok' => true, 'action' => $action, 'result' => $result]);
        }

        if (in_array($action, ['config_validate', 'config_save', 'config_restore'], true)) {
            $serverIdxRaw = $payload['server_idx'] ?? null;
            if (!is_int($serverIdxRaw) && !(is_string($serverIdxRaw) && preg_match('/^\d+$/', $serverIdxRaw))) {
                throw new InvalidArgumentException('Ungültiger Serverindex.');
            }
            $serverIdx = (int)$serverIdxRaw;
            if (!array_key_exists($serverIdx, $servers)) {
                throw new InvalidArgumentException('Unbekannter Serverindex: ' . $serverIdx);
            }
            $controller = gd_controller_for($servers[$serverIdx]);

            if (in_array($action, ['config_validate', 'config_save'], true)) {
                $content = (string)($payload['content'] ?? '');
                if ($content === '') {
                    throw new InvalidArgumentException('git_deploy.json darf nicht leer sein.');
                }
                if (strlen($content) > 1024 * 1024) {
                    throw new LengthException('git_deploy.json ist zu gross (Maximum 1 MiB).');
                }
                $expectedSha256 = strtolower(trim((string)($payload['expected_sha256'] ?? '')));
                if ($expectedSha256 !== '' && !preg_match('/^[0-9a-f]{64}$/', $expectedSha256)) {
                    throw new InvalidArgumentException('Ungültiger expected_sha256-Wert.');
                }
                $result = $action === 'config_validate'
                    ? $controller->validateGitDeployConfig($content)
                    : $controller->saveGitDeployConfig($content, $expectedSha256);
                gd_json_out([
                    'ok' => true,
                    'action' => $action,
                    'server_idx' => $serverIdx,
                    'server_name' => (string)$servers[$serverIdx]['name'],
                    'result' => $result,
                    'audit_error' => (string)($result['audit_error'] ?? ''),
                ]);
            }

            $filename = trim((string)($payload['filename'] ?? ''));
            if (!preg_match('/^git_deploy\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
                throw new InvalidArgumentException('Ungültiger Git-Deploy-Backupname.');
            }
            $result = $controller->restoreGitDeployConfig($filename);
            gd_json_out([
                'ok' => true,
                'action' => $action,
                'server_idx' => $serverIdx,
                'server_name' => (string)$servers[$serverIdx]['name'],
                'result' => $result,
                'audit_error' => (string)($result['audit_error'] ?? ''),
            ]);
        }

        // Allgemeine Git-Einstellungen aus global.json sind über das Portal absichtlich nicht editierbar.
        if (str_starts_with($action, 'settings_')) {
            gd_json_out(['ok' => false, 'error' => 'Allgemeine Git-Einstellungen aus global.json sind im Portal nicht editierbar.'], 403);
        }

        if (!in_array($action, ['deploy', 'restore'], true)) {
            gd_json_out(['ok' => false, 'error' => 'Unbekannte POST-Aktion.'], 400);
        }

        $serverIndices = $payload['server_indices'] ?? null;
        if (!is_array($serverIndices) || $serverIndices === []) {
            gd_json_out(['ok' => false, 'error' => 'Mindestens ein Zielserver muss ausgewählt sein.'], 400);
        }
        if (count($serverIndices) > 100) {
            gd_json_out(['ok' => false, 'error' => 'Zu viele Zielserver (Maximum 100).'], 400);
        }

        $deployment = gd_deployment_id((string)($payload['deployment'] ?? ''));
        $commitSha = gd_commit_sha((string)($payload['commit_sha'] ?? ''));
        if ($action === 'restore' && $commitSha === 'auto') {
            throw new InvalidArgumentException('Für den manuellen Restore muss ein früherer Commit ausgewählt werden.');
        }
        $deployToken = gd_token((string)($payload['deploy_token'] ?? ''));
        $diffPreviews = $payload['diff_previews'] ?? [];
        if (!is_array($diffPreviews)) {
            throw new InvalidArgumentException('diff_previews muss ein Objekt sein.');
        }
        $actor = gd_actor();

        $selected = [];
        foreach ($serverIndices as $idx) {
            if (!is_int($idx) && !(is_string($idx) && preg_match('/^\d+$/', $idx))) {
                throw new InvalidArgumentException('Ungültiger Serverindex.');
            }
            $idx = (int)$idx;
            if (!array_key_exists($idx, $servers)) {
                throw new InvalidArgumentException('Unbekannter Serverindex: ' . $idx);
            }
            $selected[$idx] = true;
        }

        // Lange Agent-Aufrufe dürfen die PHP-Session nicht blockieren.
        session_write_close();

        $results = [];
        $allOk = true;
        foreach (array_keys($selected) as $idx) {
            $server = $servers[$idx];
            $entry = [
                'server_idx' => $idx,
                'server_name' => (string)$server['name'],
                'deployment' => $deployment,
                'requested_commit' => $commitSha,
                'http_code' => 0,
                'ok' => false,
                'response' => [],
                'audit_error' => '',
            ];

            try {
                $controller = gd_controller_for($server);
                // Profile sind zentral. Der Zielagent bekommt vor jeder Aktion den aktuellen Katalog.
                $sync = gd_sync_central_profiles($controller);
                $preview = $diffPreviews[(string)$idx] ?? $diffPreviews[$idx] ?? [];
                if (!is_array($preview)) {
                    throw new InvalidArgumentException('Ungültige Diff-Vorschau für Serverindex ' . $idx . '.');
                }
                $previewToken = strtolower(trim((string)($preview['token'] ?? '')));
                if ($previewToken !== '' && !preg_match('/^[0-9a-f]{64}$/', $previewToken)) {
                    throw new InvalidArgumentException('Ungültiges Diff-Preview-Token für Serverindex ' . $idx . '.');
                }
                $previewFiles = max(0, (int)($preview['files_changed'] ?? 0));
                $previewDirection = strtolower(trim((string)($preview['direction'] ?? 'change')));
                if (!in_array($previewDirection, ['initial', 'upgrade', 'downgrade', 'same', 'change'], true)) {
                    $previewDirection = 'change';
                }
                $result = $action === 'restore'
                    ? $controller->restoreGit($deployment, $commitSha, $deployToken, $actor, $previewToken, $previewFiles, $previewDirection)
                    : $controller->deployGit($deployment, $commitSha, $deployToken, $actor, $previewToken, $previewFiles, $previewDirection);
                $entry['http_code'] = (int)($result['http_code'] ?? 0);
                $entry['response'] = gd_redact($result['response'] ?? [], $deployToken);
                $entry['audit_error'] = gd_redact((string)($result['audit_error'] ?? ''), $deployToken);
                $entry['ok'] = $entry['http_code'] >= 200
                    && $entry['http_code'] < 300
                    && !empty($entry['response']['ok']);
            } catch (Throwable $e) {
                $entry['http_code'] = max(0, (int)$e->getCode());
                $entry['response'] = [
                    'ok' => false,
                    'error' => gd_redact($e->getMessage(), $deployToken),
                    'error_stage' => 'portal',
                ];
            }

            if (!$entry['ok']) {
                $allOk = false;
            }
            $results[] = $entry;
        }

        // Keine Referenz auf das Token über die Antwortbildung hinaus behalten.
        $deployToken = '';

        gd_json_out([
            'ok' => $allOk,
            'partial' => !$allOk && count(array_filter($results, static fn(array $r): bool => !empty($r['ok']))) > 0,
            'deployment' => $deployment,
            'requested_commit' => $commitSha,
            'requested_by' => $actor,
            'action' => $action,
            'results' => $results,
        ]);
    } catch (LengthException $e) {
        gd_json_out(['ok' => false, 'error' => $e->getMessage()], 413);
    } catch (InvalidArgumentException $e) {
        gd_json_out(['ok' => false, 'error' => $e->getMessage()], 400);
    } catch (Throwable $e) {
        gd_json_out(['ok' => false, 'error' => $e->getMessage()], 500);
    }
}

$selfUrl = (string)($_SERVER['SCRIPT_NAME'] ?? 'git_deploy.php');
if ($selfUrl === '' || str_contains($selfUrl, "\0")) {
    $selfUrl = 'git_deploy.php';
}
?>
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Git Deploy</title>
    <?php require MMBB_UI . '/includes/css.php'; ?>
    <link rel="stylesheet" href="assets/css/git_deploy.css?v=3.25.0">
    <link rel="stylesheet" href="assets/css/configuration_workspace.css">
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3 git-deploy-page">
    <?php require MMBB_UI . '/module_header.php'; ?>

      <noscript>
        <div class="alert alert-danger">Git Deploy benötigt JavaScript.</div>
    </noscript>

    <div id="gitDeployMessage" class="alert d-none" role="alert"></div>

    <nav class="git-deploy-mode-tabs mb-3" aria-label="Git Deploy Bereiche">
        <button type="button" class="git-deploy-mode-tab is-active" data-gd-tab="deploy">
            <i class="bi bi-rocket-takeoff me-1"></i> Deploy
        </button>
        <button type="button" class="git-deploy-mode-tab" data-gd-tab="history">
            <i class="bi bi-clock-history me-1"></i> Verlauf / Ergebnisse
        </button>
        <button type="button" class="git-deploy-mode-tab" data-gd-tab="restore">
            <i class="bi bi-arrow-counterclockwise me-1"></i> Restore
        </button>
    </nav>

    <div id="gitDeployTabDeploy" class="git-deploy-tab-panel">

    <section class="card shadow-sm mb-3 git-deploy-target-card">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-hdd-rack me-1"></i> Zielserver</span>
            <div class="d-flex align-items-center gap-2">
                <span class="badge text-bg-light border" id="gitDeployServerSummary">0 ausgewählt</span>
                <button type="button" class="btn btn-outline-secondary btn-sm" id="gitDeployReloadInventory">
                    <i class="bi bi-arrow-clockwise me-1"></i> Neu laden
                </button>
            </div>
        </div>
        <div class="card-body">
            <div id="gitDeployInventoryBusy" class="text-center py-4" role="status">
                <span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span>
                Agenten und Deployment-Profile werden geladen …
            </div>
            <div id="gitDeployServerPanel" class="d-none">
                <div class="git-deploy-server-toolbar mb-2">
                    <div class="input-group input-group-sm git-deploy-server-search">
                        <span class="input-group-text" aria-hidden="true"><i class="bi bi-search"></i></span>
                        <input type="search" class="form-control" id="gitDeployServerSearch"
                               placeholder="Servername, URL oder Status suchen …" autocomplete="off"
                               aria-label="Zielserver filtern">
                    </div>
                    <div class="d-flex flex-wrap gap-2">
                        <button type="button" class="btn btn-outline-primary btn-sm" id="gitDeploySelectVisible">
                            <i class="bi bi-check2-square me-1"></i> Sichtbare auswählen
                        </button>
                        <button type="button" class="btn btn-outline-secondary btn-sm" id="gitDeployClearServers">
                            <i class="bi bi-square me-1"></i> Auswahl löschen
                        </button>
                    </div>
                </div>
                <div class="git-deploy-server-table border rounded">
                    <div class="git-deploy-server-viewport">
                        <div class="git-deploy-server-row git-deploy-server-columns" aria-hidden="true">
                            <span></span><span>Server</span><span>Status</span><span>Git Deploy</span><span>Profile</span>
                        </div>
                        <div id="gitDeployServerList" class="git-deploy-server-list" role="listbox" aria-multiselectable="true"></div>
                    </div>
                    <div id="gitDeployServerEmpty" class="git-deploy-server-empty d-none">
                        <i class="bi bi-search me-1"></i> Keine Server entsprechen dem Filter.
                    </div>
                </div>
            </div>
        </div>
    </section>

    <section class="card shadow-sm mb-3">
        <div class="card-header mmbb-card-header">
            <i class="bi bi-git me-1"></i> Deployment
        </div>
        <div class="card-body">
            <div class="git-deploy-workflow mb-3" aria-label="Deployment-Ablauf">
                <div class="git-deploy-step" id="gitDeployStep1"><span class="git-deploy-step-no">1</span><span><strong>Ziel wählen</strong><small>Server auswählen</small></span></div>
                <div class="git-deploy-step" id="gitDeployStep2"><span class="git-deploy-step-no">2</span><span><strong>Version wählen</strong><small>Profil und Commit</small></span></div>
                <div class="git-deploy-step" id="gitDeployStep3"><span class="git-deploy-step-no">3</span><span><strong>Änderungen prüfen</strong><small>Diff ist Pflicht</small></span></div>
                <div class="git-deploy-step" id="gitDeployStep4"><span class="git-deploy-step-no">4</span><span><strong>Deploy</strong><small>Bestätigen und starten</small></span></div>
            </div>
            <div id="gitDeployNextAction" class="git-deploy-next-action mb-3" role="status" aria-live="polite">
                <i class="bi bi-arrow-right-circle me-2"></i><span>Zuerst mindestens einen aktiven Zielserver auswählen.</span>
            </div>
            <div class="row g-3">
                <div class="col-12 col-lg-5">
                    <label for="gitDeployProfile" class="form-label fw-semibold">Profil</label>
                    <select id="gitDeployProfile" class="form-select form-select-sm" disabled>
                        <option value="">Zuerst Zielserver auswählen …</option>
                    </select>
                    <div class="form-text">Nur Profile, die auf allen ausgewählten Servern vorhanden und aktiviert sind.</div>
                </div>
                <div class="col-12 col-lg-7">
                    <label for="gitDeployCommit" class="form-label fw-semibold">Version / Release</label>
                    <div class="input-group input-group-sm">
                        <select id="gitDeployCommit" class="form-select font-monospace" disabled>
                            <option value="auto">Aktueller freigegebener Ref-Stand (automatisch)</option>
                        </select>
                        <button type="button" class="btn btn-outline-secondary" id="gitDeployLoadCommits" disabled>
                            <i class="bi bi-clock-history me-1"></i> Releases laden
                        </button>
                        <button type="button" class="btn btn-outline-primary" id="gitDeployPreviewDiff" disabled>
                            <i class="bi bi-file-diff me-1"></i> Änderungen prüfen
                        </button>
                    </div>
                    <div class="form-text" id="gitDeployCommitSummary">Vor dem Deploy muss für die aktuelle Server-, Profil- und Commit-Auswahl eine Diff-Vorschau erstellt werden.</div>
                </div>
                <div class="col-12 d-none" id="gitDeployTokenWrap">
                    <label for="gitDeployToken" class="form-label fw-semibold">Kurzlebiges Forgejo-Deploy-Token</label>
                    <div class="input-group input-group-sm">
                        <input type="password" id="gitDeployToken" class="form-control font-monospace"
                               maxlength="4096" autocomplete="new-password" spellcheck="false">
                        <button class="btn btn-outline-secondary" type="button" id="gitDeployToggleToken" aria-label="Token ein- oder ausblenden">
                            <i class="bi bi-eye"></i>
                        </button>
                    </div>
                    <div class="form-text">Nur bei Request-Token-Modus erforderlich. Das Token wird nicht gespeichert oder auditiert.</div>
                </div>
            </div>

            <div id="gitDeployDiffPreview" class="mt-3 d-none"></div>

            <div id="gitDeployProfileDetails" class="mt-3 d-none"></div>

            <div class="git-deploy-activation mt-3">
            <div class="form-check">
                <input class="form-check-input" type="checkbox" id="gitDeployConfirm">
                <label class="form-check-label" for="gitDeployConfirm">
                    Ich habe die Änderungen geprüft und bestätige den Deploy auf die ausgewählten Server.
                </label>
            </div>

            <div class="d-flex flex-wrap gap-2 mt-3 align-items-center">
                <button type="button" class="btn btn-primary btn-sm" id="gitDeployStart" disabled>
                    <i class="bi bi-cloud-download me-1"></i> Deploy ausführen
                </button>
                <button type="button" class="btn btn-outline-secondary btn-sm" id="gitDeployLoadStatus" disabled>
                    <i class="bi bi-arrow-repeat me-1"></i> Status prüfen
                </button>
                <span class="small text-body-secondary" id="gitDeployBlockReason" role="status" aria-live="polite"></span>
            </div>
            </div>
        </div>
    </section>

    </div>

    <div id="gitDeployTabRestore" class="git-deploy-tab-panel d-none">
    <section class="card shadow-sm mb-3">
        <div class="card-header mmbb-card-header">
            <i class="bi bi-arrow-counterclockwise me-1"></i> Restore
        </div>
        <div class="card-body">
            <div class="alert alert-warning py-2 small">
                Ein früherer Commit wird erneut über den normalen Deploy-Ablauf installiert. Persistente Pfade bleiben erhalten; Preflight, Post-Deploy, Healthcheck und automatischer Rollback bleiben aktiv.
            </div>
            <div id="gitDeployRestoreMessage" class="alert d-none" role="alert"></div>
            <div class="row g-3">
                <div class="col-12 col-lg-4">
                    <label for="gitDeployRestoreServer" class="form-label fw-semibold">Server</label>
                    <select id="gitDeployRestoreServer" class="form-select form-select-sm" disabled></select>
                </div>
                <div class="col-12 col-lg-4">
                    <label for="gitDeployRestoreProfile" class="form-label fw-semibold">Deployment-Profil</label>
                    <select id="gitDeployRestoreProfile" class="form-select form-select-sm" disabled></select>
                </div>
                <div class="col-12 col-lg-4">
                    <label for="gitDeployRestoreRelease" class="form-label fw-semibold">Früherer Commit</label>
                    <div class="input-group input-group-sm">
                        <select id="gitDeployRestoreRelease" class="form-select font-monospace" disabled>
                            <option value="">Zuerst Releases laden …</option>
                        </select>
                        <button type="button" class="btn btn-outline-secondary" id="gitDeployRestoreLoad" disabled>
                            <i class="bi bi-arrow-clockwise"></i> Laden
                        </button>
                    </div>
                </div>
                <div class="col-12 d-none" id="gitDeployRestoreTokenWrap">
                    <label for="gitDeployRestoreToken" class="form-label fw-semibold">Kurzlebiges Forgejo-Deploy-Token</label>
                    <input type="password" id="gitDeployRestoreToken" class="form-control form-control-sm font-monospace"
                           maxlength="4096" autocomplete="new-password" spellcheck="false">
                </div>
            </div>
            <div class="small text-body-secondary mt-2" id="gitDeployRestoreSummary">Noch keine Releases geladen.</div>
            <div class="form-check mt-3">
                <input class="form-check-input" type="checkbox" id="gitDeployRestoreConfirm">
                <label class="form-check-label" for="gitDeployRestoreConfirm">
                    Ich bestätige die Wiederherstellung des ausgewählten Commits auf diesem Server.
                </label>
            </div>
            <button type="button" class="btn btn-warning btn-sm mt-3" id="gitDeployRestoreStart" disabled>
                <i class="bi bi-arrow-counterclockwise me-1"></i> Commit wiederherstellen
            </button>
        </div>
    </section>
    </div>

    <div id="gitDeployTabHistory" class="git-deploy-tab-panel d-none">
    <section class="card shadow-sm mb-3">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-list-check me-1"></i> Verlauf / Ergebnis pro Server</span>
            <span class="small text-body-secondary" id="gitDeployResultSummary">Noch kein Deploy ausgeführt</span>
        </div>
        <div class="card-body p-0">
            <div id="gitDeployResultEmpty" class="text-center text-body-secondary p-5">
                <i class="bi bi-git display-6 d-block mb-2"></i>
                Nach einem Deploy oder einer Statusabfrage erscheinen hier die Ergebnisse jedes Zielservers.
            </div>
            <div id="gitDeployResultBusy" class="text-center p-5 d-none" role="status">
                <span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span>
                Deploy läuft. Die ausgewählten Server werden unabhängig voneinander verarbeitet …
            </div>
            <div id="gitDeployResults" class="table-responsive d-none">
                <table class="table table-sm align-middle mb-0 git-deploy-results-table">
                    <thead>
                    <tr>
                        <th>Server</th>
                        <th>Deploy-Status</th>
                        <th>Installiertes Paket</th>
                        <th>Repository</th>
                        <th>SHA-Vergleich</th>
                        <th>Aktion / Stufe</th>
                        <th>Service / Rollback</th>
                        <th>Details</th>
                    </tr>
                    </thead>
                    <tbody id="gitDeployResultsBody"></tbody>
                </table>
            </div>
        </div>
    </section>
    </div>

</div>

<script>
window.GIT_DEPLOY_PAGE = <?= json_encode([
    'endpoint' => $selfUrl,
    'csrfToken' => $csrfToken,
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;
</script>
<?php require MMBB_UI . '/includes/js.php'; ?>
<script src="assets/js/git_deploy.js?v=3.25.0"></script>
</body>
</html>
