<?php
declare(strict_types=1);

// TEKO Config Manager 3.17.0 - Remote Fleet + Canary Rollout
require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../autoloader.php';
require_once __DIR__ . '/../Repository/ConfigManagerRepository.php';
require_once __DIR__ . '/../Service/ConfigManagerService.php';
require_once __DIR__ . '/../Controller/ConfigManagerController.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';
require_once __DIR__ . '/../lib/desired_state.php';
require_once __DIR__ . '/../lib/deploy_profiles.php';

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;
use ConfigManager\Controller\ConfigManagerController;

if (session_status() === PHP_SESSION_NONE) session_start();
if (empty($_SESSION['csrf_token'])) $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
$csrfToken = (string)$_SESSION['csrf_token'];

if (!headers_sent()) {
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('Pragma: no-cache');
    header('Expires: 0');
}

function ds_json(array $payload, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($payload, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

function ds_actor(): string
{
    $value = trim((string)($_SESSION['standalone_user'] ?? 'portal-user'));
    $value = preg_replace('/[\x00-\x1f\x7f]/', '?', $value) ?? 'portal-user';
    return substr($value, 0, 128);
}

function ds_controller(array $server): ConfigManagerController
{
    return new ConfigManagerController(new ConfigManagerService(new ConfigManagerRepository($server)));
}

function ds_sync_deploy_profiles(ConfigManagerController $controller): void
{
    $central = dp_content();
    try {
        $current = $controller->getGitDeployConfig();
        $currentContent = (string)($current['content'] ?? '');
        if ($currentContent !== '') {
            try {
                $normalized = dp_encode(dp_decode_content($currentContent));
                if (hash_equals(hash('sha256', $central), hash('sha256', $normalized))) return;
            } catch (Throwable $ignore) {
                // Ungültiger Altstand wird ersetzt.
            }
        }
    } catch (Throwable $ignore) {
        // Save liefert bei einem echten Erreichbarkeitsfehler die klare Meldung.
    }
    $controller->saveGitDeployConfig($central);
}

function ds_read_body(): array
{
    $raw = file_get_contents('php://input');
    if (!is_string($raw) || $raw === '') throw new InvalidArgumentException('Leerer JSON-Body.');
    if (strlen($raw) > 1024 * 1024) throw new LengthException('JSON-Body ist zu gross.');
    $data = json_decode($raw, true);
    if (!is_array($data)) throw new InvalidArgumentException('Ungueltiges JSON.');
    return $data;
}

function ds_csrf(array $payload): void
{
    $token = (string)($payload['csrf_token'] ?? '');
    if ($token === '' || !hash_equals((string)($_SESSION['csrf_token'] ?? ''), $token)) {
        throw new RuntimeException('Ungueltiges CSRF-Token.', 403);
    }
}

function ds_load_runtime(): array
{
    $configFile = __DIR__ . '/../config/config.php';
    $cfg = require $configFile;
    if (!is_array($cfg)) throw new RuntimeException('config.php ist ungueltig.');
    $servers = cm_load_config_manager_servers($configFile);

    $file = trim((string)($cfg['desired_state']['file'] ?? ''));
    if ($file === '') $file = __DIR__ . '/../standalone/data/desired_state.json';
    if (is_link($file)) throw new RuntimeException('desired_state.json darf kein Symlink sein.');

    if (!is_file($file)) {
        $doc = ['schema_version'=>1, 'policies'=>[]];
    } else {
        $raw = file_get_contents($file);
        $decoded = is_string($raw) ? json_decode($raw, true) : null;
        if (!is_array($decoded)) throw new RuntimeException('desired_state.json ist kein gueltiges JSON.');
        $doc = ds_validate_document($decoded);
    }

    return [$cfg, $servers, $file, $doc];
}

function ds_public_server(array $server, int $idx): array
{
    return [
        'idx'=>$idx,
        'name'=>(string)$server['name'],
        'url'=>(string)$server['url'],
        'groups'=>array_values((array)($server['groups'] ?? [])),
        'labels'=>(array)($server['labels'] ?? []),
        'token_source'=>(string)($server['token_source'] ?? 'global'),
    ];
}


function ds_managed_config_catalog(array $servers): array
{
    $catalog = [];
    foreach ($servers as $idx => $server) {
        $name = (string)($server['name'] ?? ('server-' . $idx));
        $entry = ['server_idx'=>(int)$idx, 'server_name'=>$name, 'configs'=>[], 'error'=>''];
        try {
            $raw = ds_controller($server)->getRawConfigs();
            if (!is_array($raw)) {
                throw new RuntimeException('managed_configs.json lieferte kein Objekt.');
            }
            foreach ($raw as $id => $cfg) {
                if (!is_string($id) || !is_array($cfg)) continue;
                $entry['configs'][$id] = [
                    'id'=>$id,
                    'path'=>(string)($cfg['path'] ?? ''),
                    'category'=>(string)($cfg['category'] ?? ''),
                    'service'=>(string)($cfg['service'] ?? ''),
                    'user'=>(string)($cfg['user'] ?? ''),
                    'group'=>(string)($cfg['group'] ?? ''),
                    'mode'=>(string)($cfg['mode'] ?? ''),
                ];
            }
            ksort($entry['configs'], SORT_NATURAL|SORT_FLAG_CASE);
        } catch (Throwable $e) {
            $entry['error'] = substr($e->getMessage(), 0, 300);
        }
        $catalog[$name] = $entry;
    }
    return $catalog;
}

function ds_validate_config_object_references(array $servers, array $doc): void
{
    $catalog = ds_managed_config_catalog($servers);
    foreach ((array)($doc['policies'] ?? []) as $policyId => $policy) {
        $source = is_array($policy['source'] ?? null) ? $policy['source'] : [];
        if (($source['type'] ?? '') !== 'config_manager') continue;
        $refServer = (string)($source['reference_server'] ?? '');
        $sourceId = (string)($source['source_config'] ?? '');
        $targetId = (string)($source['target_config'] ?? $sourceId);
        if (!isset($catalog[$refServer])) {
            throw new InvalidArgumentException("Policy $policyId: Referenzserver '$refServer' existiert nicht.");
        }
        if (($catalog[$refServer]['error'] ?? '') !== '') {
            throw new RuntimeException("Policy $policyId: Config-Katalog von '$refServer' konnte nicht geladen werden: " . $catalog[$refServer]['error']);
        }
        if (!isset($catalog[$refServer]['configs'][$sourceId])) {
            throw new InvalidArgumentException("Policy $policyId: Quell-Konfiguration '$sourceId' existiert auf '$refServer' nicht.");
        }

        // Zielobjekt ist eine stabile Config-ID. Mindestens ein durch den Selector
        // erfasster Server muss diese ID kennen; fehlende IDs auf einzelnen Zielen
        // werden im Drift-Check weiterhin sichtbar.
        $matched = 0; $knownTarget = 0;
        foreach ($servers as $server) {
            if (!ds_server_matches($server, $policy)) continue;
            $matched++;
            $serverName = (string)($server['name'] ?? '');
            if (isset($catalog[$serverName]['configs'][$targetId])) $knownTarget++;
        }
        if ($matched > 0 && $knownTarget === 0) {
            throw new InvalidArgumentException("Policy $policyId: Ziel-Konfiguration '$targetId' existiert auf keinem selektierten Server.");
        }
    }
}

function ds_policy_targets(array $servers, array $policy): array
{
    $targets = [];
    foreach ($servers as $idx => $server) {
        if (ds_server_matches($server, $policy)) $targets[$idx] = $server;
    }
    $limit = min(100, (int)($policy['max_targets'] ?? 100));
    if (count($targets) > $limit) {
        throw new RuntimeException("Policy selektiert mehr als $limit Zielserver.");
    }
    return $targets;
}

function ds_find_server_by_name(array $servers, string $name): array
{
    foreach ($servers as $idx => $server) {
        if (strcasecmp((string)($server['name'] ?? ''), $name) === 0) {
            return [(int)$idx, $server];
        }
    }
    throw new RuntimeException('Referenzserver ist nicht in der Fleet-Registry vorhanden: ' . $name);
}

function ds_prepare_policy_context(array $servers, array $policy): array
{
    $source = is_array($policy['source'] ?? null) ? $policy['source'] : ['type' => 'git'];
    $type = (string)($source['type'] ?? 'git');

    if ($type === 'git') {
        return ['type' => 'git'];
    }

    if ($type !== 'config_manager') {
        throw new RuntimeException('Unbekannter Desired-State-Quelltyp.');
    }

    [$referenceIdx, $referenceServer] = ds_find_server_by_name(
        $servers,
        (string)($source['reference_server'] ?? '')
    );
    $sourceConfig = (string)($source['source_config'] ?? '');
    $targetConfig = (string)($source['target_config'] ?? $sourceConfig);

    $content = ds_controller($referenceServer)->getConfigContent($sourceConfig);
    if (!is_string($content)) {
        throw new RuntimeException('Referenz-Konfiguration konnte nicht gelesen werden.');
    }

    return [
        'type' => 'config_manager',
        'reference_idx' => $referenceIdx,
        'reference_server' => (string)$referenceServer['name'],
        'source_config' => $sourceConfig,
        'target_config' => $targetConfig,
        'content' => $content,
        'sha256' => hash('sha256', $content),
        'bytes' => strlen($content),
    ];
}

function ds_check_server(array $server, int $idx, string $policyId, array $policy, array $context = []): array
{
    $source = is_array($policy['source'] ?? null) ? $policy['source'] : ['type'=>'git'];
    $sourceType = (string)($source['type'] ?? 'git');
    $deployment = (string)($policy['deployment'] ?? '');

    $row = [
        'server_idx'=>$idx,
        'server_name'=>(string)$server['name'],
        'server_url'=>(string)$server['url'],
        'groups'=>array_values((array)($server['groups'] ?? [])),
        'labels'=>(array)($server['labels'] ?? []),
        'policy'=>$policyId,
        'source_type'=>$sourceType,
        'deployment'=>$deployment,
        'desired_type'=>(string)($policy['desired']['type'] ?? ''),
        'desired_value'=>(string)($policy['desired']['value'] ?? ''),
        'active_commit'=>null,
        'desired_commit'=>null,
        'repository_commit'=>null,
        'allowed_ref'=>'',
        'active_hash'=>null,
        'desired_hash'=>null,
        'reference_server'=>'',
        'source_config'=>'',
        'target_config'=>'',
        'content_bytes'=>null,
        'compliance'=>'error',
        'error'=>'',
        'checked_at'=>gmdate('c'),
    ];

    try {
        $controller = ds_controller($server);

        if ($sourceType === 'config_manager') {
            if (($context['type'] ?? '') !== 'config_manager') {
                throw new RuntimeException('Config-Manager-Policy-Kontext fehlt.');
            }

            $targetConfig = (string)$context['target_config'];
            $targetContent = $controller->getConfigContent($targetConfig);
            if (!is_string($targetContent)) {
                throw new RuntimeException('Ziel-Konfiguration konnte nicht gelesen werden.');
            }

            $row['reference_server'] = (string)$context['reference_server'];
            $row['source_config'] = (string)$context['source_config'];
            $row['target_config'] = $targetConfig;
            $row['desired_hash'] = (string)$context['sha256'];
            $row['active_hash'] = hash('sha256', $targetContent);
            $row['desired_type'] = 'config_hash';
            $row['desired_value'] = substr((string)$context['sha256'], 0, 12);
            $row['content_bytes'] = strlen($targetContent);
            $row['compliance'] = ds_compliance($row['active_hash'], $row['desired_hash']);
            return $row;
        }

        // Git-Deploy-Profile sind zentral. Vor der Statusprüfung wird der aktuelle
        // Profilkatalog auf den Zielagenten synchronisiert.
        ds_sync_deploy_profiles($controller);
        $statusResult = $controller->getGitDeployStatus($deployment);
        $code = (int)($statusResult['http_code'] ?? 0);
        $status = is_array($statusResult['response'] ?? null) ? $statusResult['response'] : [];
        if ($code < 200 || $code >= 300 || empty($status['ok'])) {
            throw new RuntimeException((string)($status['error'] ?? "Agent HTTP $code"));
        }

        $row['active_commit'] = isset($status['active_commit']) ? (string)$status['active_commit'] : null;
        $row['repository_commit'] = isset($status['repository_commit']) ? (string)$status['repository_commit'] : null;
        $row['allowed_ref'] = (string)($status['allowed_ref'] ?? '');

        $type = (string)$policy['desired']['type'];
        if ($type === 'allowed_ref') {
            $row['desired_commit'] = $row['repository_commit'];
            if (!$row['desired_commit'] && !empty($status['repository_error'])) {
                throw new RuntimeException((string)$status['repository_error']);
            }
        } elseif ($type === 'commit') {
            $row['desired_commit'] = (string)$policy['desired']['value'];
        } elseif ($type === 'tag') {
            $releases = $controller->getGitDeployReleases($deployment);
            $row['desired_commit'] = ds_resolve_tag_commit($releases, (string)$policy['desired']['value']);
            if (!$row['desired_commit']) {
                throw new RuntimeException('Tag wurde im freigegebenen Repository-Verlauf nicht gefunden.');
            }
        }

        $row['compliance'] = ds_compliance($row['active_commit'], $row['desired_commit']);
    } catch (Throwable $e) {
        $row['error'] = substr($e->getMessage(), 0, 500);
        $row['compliance'] = 'error';
    }

    return $row;
}

try {
    [$portalConfig, $servers, $desiredFile, $desiredDoc] = ds_load_runtime();
} catch (Throwable $e) {
    http_response_code(500);
    exit('Desired-State-Konfiguration konnte nicht geladen werden: ' . htmlspecialchars($e->getMessage(), ENT_QUOTES, 'UTF-8'));
}

$requiredService = trim((string)($portalConfig['git_deploy']['required_service'] ?? ''));
$requiredService = $requiredService !== '' ? $requiredService : 'ConfigManager';
if (function_exists('mmbb_has_service') && !mmbb_has_service($requiredService)) {
    http_response_code(403);
    exit('Keine Berechtigung fuer Desired State.');
}

if (isset($_GET['api'])) {
    $api = (string)$_GET['api'];
    try {
        if ($api === 'summary') {
            $policies = [];
            foreach ($desiredDoc['policies'] as $id => $policy) {
                $matched = 0;
                foreach ($servers as $server) if (ds_server_matches($server, $policy)) $matched++;
                $policies[] = [
                    'id'=>$id, 'enabled'=>!empty($policy['enabled']),
                    'description'=>(string)$policy['description'],
                    'source'=>$policy['source'] ?? ['type'=>'git'],
                    'deployment'=>(string)$policy['deployment'],
                    'selector'=>$policy['selector'], 'desired'=>$policy['desired'],
                    'enforcement'=>(string)$policy['enforcement'],
                    'max_targets'=>(int)$policy['max_targets'],
                    'rollout'=>$policy['rollout'] ?? ['strategy'=>'all'],
                    'matched_servers'=>$matched,
                ];
            }
            ds_json([
                'ok'=>true,
                'servers'=>array_map(fn($s,$i)=>ds_public_server($s,$i), $servers, array_keys($servers)),
                'policies'=>$policies,
                'desired_state_file'=>$desiredFile,
                'server_registry_file'=>(string)($portalConfig['server_registry_file'] ?? ''),
            ]);
        }

        if ($api === 'document') {
            ds_json(['ok'=>true, 'content'=>json_encode($desiredDoc, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)]);
        }

        if ($api === 'editor_catalog') {
            $deployments = [];
            $catalogError = '';
            try {
                foreach (dp_inventory_profiles() as $profile) {
                    if (!is_array($profile)) continue;
                    $id = trim((string)($profile['id'] ?? ''));
                    if ($id === '') continue;
                    $deployments[$id] = [
                        'id'=>$id,
                        'git_url'=>(string)($profile['git_url'] ?? $profile['repository'] ?? ''),
                        'allowed_ref'=>(string)($profile['allowed_ref'] ?? $profile['branch'] ?? ''),
                        'enabled'=>!array_key_exists('enabled',$profile) || !empty($profile['enabled']),
                    ];
                }
            } catch (Throwable $e) {
                $catalogError = $e->getMessage();
            }
            ds_json([
                'ok'=>true,
                'deployments'=>array_values($deployments),
                'config_catalog'=>ds_managed_config_catalog($servers),
                'catalog_error'=>$catalogError,
            ]);
        }

        ds_json(['ok'=>false,'error'=>'Unbekannte API-Aktion.'],404);
    } catch (Throwable $e) {
        ds_json(['ok'=>false,'error'=>$e->getMessage()],500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    try {
        $payload = ds_read_body();
        ds_csrf($payload);
        $action = (string)($payload['action'] ?? '');

        if ($action === 'validate' || $action === 'save') {
            $content = (string)($payload['content'] ?? '');
            if ($content === '' || strlen($content) > 1024 * 1024) {
                throw new InvalidArgumentException('Policy-JSON fehlt oder ist zu gross.');
            }
            $decoded = json_decode($content, true);
            if (!is_array($decoded)) throw new InvalidArgumentException('Policy-JSON ist ungueltig.');
            $normalized = ds_validate_document($decoded);
            ds_validate_config_object_references($servers, $normalized);

            if ($action === 'save') {
                ds_atomic_save($desiredFile, $normalized);
                mmbb_audit_write('desired_state_save', 'desired_state.json',
                    ['policy_count'=>count($normalized['policies'])], 'desired_state.php', 'ok');
            }
            ds_json(['ok'=>true,'action'=>$action,'document'=>$normalized]);
        }

        if (!in_array($action, ['check','enforce','enforce_canary','enforce_remaining'], true)) {
            throw new InvalidArgumentException('Unbekannte POST-Aktion.');
        }

        $policyId = ds_policy_id((string)($payload['policy_id'] ?? ''));
        $policy = $desiredDoc['policies'][$policyId] ?? null;
        if (!is_array($policy)) throw new InvalidArgumentException('Unbekannte Policy.');
        if (empty($policy['enabled'])) throw new RuntimeException('Policy ist deaktiviert.',409);
        if (in_array($action,['enforce','enforce_canary','enforce_remaining'],true)
            && (string)$policy['enforcement'] === 'check_only') {
            throw new RuntimeException('Policy ist auf check_only gesetzt.',403);
        }

        $targets = ds_policy_targets($servers, $policy);
        if ($targets === []) throw new RuntimeException('Policy selektiert keine Server.',409);

        $rollout = ds_rollout_partition($targets, $policy);
        $rolloutStrategy=(string)($policy['rollout']['strategy'] ?? 'all');
        if ($action === 'enforce' && $rolloutStrategy === 'canary') {
            throw new RuntimeException('Canary-Policy: zuerst Canary ausrollen, danach Rest ausrollen.',409);
        }
        if ($action === 'enforce_canary') {
            if ($rolloutStrategy !== 'canary') throw new RuntimeException('Policy verwendet keinen Canary-Rollout.',409);
            $targets=$rollout['canary'];
        } elseif ($action === 'enforce_remaining') {
            if ($rolloutStrategy !== 'canary') throw new RuntimeException('Policy verwendet keinen Canary-Rollout.',409);
            $targets=$rollout['remaining'];
        }

        // Optionaler Einzelserver-Target fuer die Tabellenaktion. Der Index
        // muss bereits durch den Policy-Selector selektiert worden sein.
        if (array_key_exists('server_idx', $payload) && $payload['server_idx'] !== null && $payload['server_idx'] !== '') {
            $serverIdx = filter_var($payload['server_idx'], FILTER_VALIDATE_INT);
            if ($serverIdx === false || $serverIdx < 0 || !array_key_exists($serverIdx, $targets)) {
                throw new RuntimeException('Server ist kein gueltiges Ziel dieser Policy.',403);
            }
            $targets = [$serverIdx => $targets[$serverIdx]];
        }

        // Lange Agent-Aufrufe duerfen die PHP-Session nicht blockieren.
        session_write_close();

        // Beim zweiten Rollout-Schritt muessen die Canary-Systeme vor jeder
        // Aenderung erneut vollstaendig compliant sein.
        if ($action === 'enforce_remaining'
            && !empty($policy['rollout']['require_canary_compliant'])) {
            $gateContext = ds_prepare_policy_context($servers, $policy);
            foreach ($rollout['canary'] as $cidx=>$cserver) {
                $crow=ds_check_server($cserver,(int)$cidx,$policyId,$policy,$gateContext);
                if (($crow['compliance'] ?? 'error') !== 'compliant') {
                    throw new RuntimeException(
                        'Canary-Gate blockiert Rollout: '.(string)$cserver['name'].' ist '.(string)$crow['compliance'],
                        409
                    );
                }
            }
        }

        // Quellinhalt einer Config-Manager-Policy wird genau einmal vom
        // Referenzserver gelesen und dann nur per Hash/Inhalt gegen die Ziele
        // verglichen. Git-Policies brauchen keinen zusaetzlichen Kontext.
        $policyContext = ds_prepare_policy_context($servers, $policy);

        $rows = [];
        foreach ($targets as $idx => $server) {
            $rows[$idx] = ds_check_server($server, (int)$idx, $policyId, $policy, $policyContext);
        }

        $deployments = [];
        if (in_array($action,['enforce','enforce_canary','enforce_remaining'],true)) {
            $actor = ds_actor();
            $sourceType = (string)(($policy['source']['type'] ?? 'git'));

            foreach ($targets as $idx => $server) {
                $row = $rows[$idx];
                if (!in_array($row['compliance'], ['drift','not_installed'], true)) continue;

                if ($sourceType === 'config_manager') {
                    $entry = [
                        'server_idx'=>(int)$idx,
                        'server_name'=>(string)$server['name'],
                        'ok'=>false,
                        'source_type'=>'config_manager',
                        'target_config'=>(string)$policyContext['target_config'],
                        'desired_hash'=>(string)$policyContext['sha256'],
                    ];
                    try {
                        $controller = ds_controller($server);
                        $targetConfig = (string)$policyContext['target_config'];
                        $oldContent = $controller->getConfigContent($targetConfig);
                        if (!is_string($oldContent)) {
                            throw new RuntimeException('Ziel-Konfiguration konnte vor Enforce nicht gelesen werden.');
                        }

                        // Wichtig: bewusst ueber ConfigManagerController::saveConfig().
                        // Dadurch bleiben vorhandenes Backup, Agent-Path-Guard,
                        // apply_meta und Config-Manager-Audit erhalten.
                        $result = $controller->saveConfig(
                            $targetConfig,
                            (string)$policyContext['content'],
                            $oldContent,
                            md5($oldContent)
                        );

                        $raw = $result['response'] ?? '';
                        $decoded = is_string($raw) ? json_decode($raw, true) : (is_array($raw) ? $raw : []);
                        $entry['http_code'] = (int)($result['http_code'] ?? 0);
                        $entry['response'] = is_array($decoded) ? [
                            'ok'=>!empty($decoded['ok']),
                            'saved'=>(string)($decoded['saved'] ?? $targetConfig),
                            'noop'=>!empty($decoded['noop']),
                            'error'=>(string)($decoded['error'] ?? ''),
                        ] : ['ok'=>false,'error'=>'Ungueltige Config-Manager-Antwort'];
                        $entry['ok'] = $entry['http_code'] >= 200 && $entry['http_code'] < 300
                            && !empty($entry['response']['ok']);
                    } catch (Throwable $e) {
                        $entry['http_code'] = max(0,(int)$e->getCode());
                        $entry['response'] = ['ok'=>false,'error'=>substr($e->getMessage(),0,500)];
                    }
                    $deployments[] = $entry;
                    $rows[$idx] = ds_check_server($server, (int)$idx, $policyId, $policy, $policyContext);
                    continue;
                }

                $desiredCommit = (string)($row['desired_commit'] ?? '');
                if ($desiredCommit === '') continue;

                $entry = [
                    'server_idx'=>(int)$idx,
                    'server_name'=>(string)$server['name'],
                    'ok'=>false,
                    'source_type'=>'git',
                    'desired_commit'=>$desiredCommit
                ];
                try {
                    $controller = ds_controller($server);
                    ds_sync_deploy_profiles($controller);
                    $result = $controller->deployGit((string)$policy['deployment'], $desiredCommit, '', $actor);
                    $response = is_array($result['response'] ?? null) ? $result['response'] : [];
                    $entry['http_code'] = (int)($result['http_code'] ?? 0);
                    $entry['response'] = [
                        'ok'=>!empty($response['ok']),
                        'action'=>(string)($response['action'] ?? ''),
                        'active_commit'=>(string)($response['active_commit'] ?? $response['commit'] ?? ''),
                        'previous_commit'=>(string)($response['previous_commit'] ?? ''),
                        'error'=>(string)($response['error'] ?? ''),
                        'error_stage'=>(string)($response['error_stage'] ?? ''),
                    ];
                    $entry['ok'] = $entry['http_code'] >= 200 && $entry['http_code'] < 300 && !empty($response['ok']);
                } catch (Throwable $e) {
                    $entry['http_code'] = max(0,(int)$e->getCode());
                    $entry['response'] = ['ok'=>false,'error'=>substr($e->getMessage(),0,500),'error_stage'=>'portal'];
                }
                $deployments[] = $entry;
                $rows[$idx] = ds_check_server($server, (int)$idx, $policyId, $policy, $policyContext);
            }

            mmbb_audit_write('desired_state_enforce', $policyId, [
                'rollout_action'=>$action,
                'source_type'=>$sourceType,
                'deployment'=>(string)($policy['deployment'] ?? ''),
                'targets'=>count($targets),
                'changes'=>array_map(static fn($d)=>[
                    'server_name'=>$d['server_name'],
                    'source_type'=>$d['source_type'] ?? '',
                    'ok'=>$d['ok'],
                    'desired_commit'=>$d['desired_commit'] ?? '',
                    'desired_hash'=>$d['desired_hash'] ?? '',
                    'target_config'=>$d['target_config'] ?? '',
                ], $deployments),
            ], 'desired_state.php', 'ok');
        }

        $resultRows = array_values($rows);
        ds_json([
            'ok'=>true,
            'action'=>$action,
            'policy_id'=>$policyId,
            'source_type'=>(string)($policy['source']['type'] ?? 'git'),
            'deployment'=>(string)$policy['deployment'],
            'results'=>$resultRows,
            'summary'=>ds_summary($resultRows),
            'deployments'=>$deployments,
        ]);
    } catch (Throwable $e) {
        $status = (int)$e->getCode();
        if ($status < 400 || $status > 599) $status = $e instanceof InvalidArgumentException ? 400 : 500;
        ds_json(['ok'=>false,'error'=>$e->getMessage()],$status);
    }
}
?>
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Desired State</title>
<?php require MMBB_UI . '/includes/css.php'; ?>
<style>
.ds-page{--ds-gap:.85rem}
.ds-title{font-weight:700;letter-spacing:-.02em}
.ds-subtitle{color:var(--bs-secondary-color);font-size:.92rem}
.ds-kpis{display:grid;grid-template-columns:repeat(5,minmax(140px,1fr));gap:var(--ds-gap)}
.ds-kpi{position:relative;overflow:hidden;border:1px solid var(--bs-border-color);border-radius:.7rem;padding:1rem 1.05rem;background:var(--bs-body-bg);min-height:112px}
.ds-kpi .ds-kpi-label{color:var(--bs-secondary-color);font-size:.82rem;font-weight:600}
.ds-kpi strong{display:block;font-size:1.75rem;line-height:1.1;margin-top:.35rem}
.ds-kpi .ds-kpi-foot{font-size:.76rem;color:var(--bs-secondary-color);margin-top:.35rem}
.ds-kpi .bi{position:absolute;right:1rem;top:1rem;font-size:2rem;opacity:.32}
.ds-kpi-ok{border-color:rgba(25,135,84,.45)}
.ds-kpi-ok strong,.ds-kpi-ok .bi{color:var(--bs-success)}
.ds-kpi-drift{border-color:rgba(255,193,7,.5)}
.ds-kpi-drift strong,.ds-kpi-drift .bi{color:#c58b00}
.ds-kpi-err{border-color:rgba(220,53,69,.45)}
.ds-kpi-err strong,.ds-kpi-err .bi{color:var(--bs-danger)}
.ds-toolbar{display:grid;grid-template-columns:minmax(180px,1.4fr) repeat(3,minmax(150px,1fr)) auto auto;gap:.65rem;align-items:center}
.ds-table th{white-space:nowrap;font-size:.78rem;color:var(--bs-secondary-color);font-weight:700}
.ds-table td{vertical-align:middle}
.ds-server-dot{width:.55rem;height:.55rem;border-radius:50%;display:inline-block;background:var(--bs-success);margin-right:.5rem;box-shadow:0 0 0 .18rem rgba(25,135,84,.12)}
.ds-server-dot.error{background:var(--bs-danger);box-shadow:0 0 0 .18rem rgba(220,53,69,.12)}
.ds-sha{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.81rem}
.ds-label{font-size:.69rem;margin:.08rem .15rem .08rem 0}
.ds-status{display:inline-flex;align-items:center;gap:.35rem;font-weight:600;font-size:.8rem}
.ds-status.compliant{color:var(--bs-success)}
.ds-status.drift{color:#b17b00}
.ds-status.error{color:var(--bs-danger)}
.ds-status.not_installed,.ds-status.desired_unknown{color:var(--bs-secondary-color)}
.ds-bottom{display:grid;grid-template-columns:1fr 1.35fr;gap:var(--ds-gap)}
.ds-detail-grid{display:grid;grid-template-columns:150px 1fr;gap:.45rem .8rem;font-size:.86rem}
.ds-detail-grid dt{color:var(--bs-secondary-color);font-weight:600;margin:0}
.ds-detail-grid dd{margin:0;min-width:0;overflow-wrap:anywhere}
.ds-dist{display:grid;grid-template-columns:1fr;gap:.75rem}
.ds-dist-row{display:grid;grid-template-columns:115px 1fr 48px;gap:.65rem;align-items:center;font-size:.82rem}
.ds-dist-track{height:.7rem;border-radius:99px;background:var(--bs-tertiary-bg);overflow:hidden}
.ds-dist-bar{height:100%;border-radius:99px;transition:width .25s ease}
.ds-dist-bar.ok{background:var(--bs-success)}
.ds-dist-bar.drift{background:var(--bs-warning)}
.ds-dist-bar.missing{background:var(--bs-secondary)}
.ds-dist-bar.error{background:var(--bs-danger)}
.ds-empty{padding:2.5rem 1rem;text-align:center;color:var(--bs-secondary-color)}
.ds-editor{min-height:380px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.82rem}
.ds-code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.ds-modal-backdrop{position:fixed;inset:0;background:rgba(0,0,0,.48);z-index:1040;display:flex;align-items:center;justify-content:center;padding:1rem}
.ds-modal{width:min(720px,100%);max-height:85vh;overflow:auto;background:var(--bs-body-bg);border:1px solid var(--bs-border-color);border-radius:.8rem;box-shadow:0 1rem 3rem rgba(0,0,0,.25)}
.ds-modal-head{display:flex;align-items:center;justify-content:space-between;padding:1rem 1.1rem;border-bottom:1px solid var(--bs-border-color)}
.ds-modal-body{padding:1.1rem}
.ds-hidden{display:none!important}
@media(max-width:1200px){.ds-kpis{grid-template-columns:repeat(3,1fr)}.ds-toolbar{grid-template-columns:1fr 1fr 1fr}.ds-bottom{grid-template-columns:1fr}}
@media(max-width:760px){.ds-kpis{grid-template-columns:repeat(2,1fr)}.ds-toolbar{grid-template-columns:1fr}.ds-detail-grid{grid-template-columns:1fr}.ds-detail-grid dd{margin-bottom:.45rem}}
</style>
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3 ds-page mmbb-page">
<?php require MMBB_UI . '/module_header.php'; ?>

<div class="d-flex flex-wrap gap-2 mb-3" role="navigation" aria-label="Desired State Bereiche">
  <a class="btn btn-primary btn-sm" href="desired_state.php"><i class="bi bi-speedometer2 me-1"></i>Übersicht & Abweichungen</a>
  <a class="btn btn-outline-primary btn-sm" href="desired_state_editor.php"><i class="bi bi-layers me-1"></i>Baselines verwalten</a>
  <span class="small text-body-secondary align-self-center ms-1">Baseline definieren → Server zuweisen → Drift prüfen → gezielt beheben</span>
</div>

<div class="mmbb-page-toolbar mb-3">
  <div class="mmbb-page-toolbar-spacer"></div>
  <button class="btn btn-outline-secondary btn-sm" id="dsReload"><i class="bi bi-arrow-clockwise me-1"></i>Neu laden</button>
</div>

<div id="dsMsg" class="alert d-none" role="alert"></div>

<div class="ds-kpis mb-3">
  <div class="ds-kpi">
    <div class="ds-kpi-label">Gesamt Server</div><strong id="kFleet">—</strong>
    <div class="ds-kpi-foot" id="kFleetFoot">Registry</div><i class="bi bi-server"></i>
  </div>
  <div class="ds-kpi ds-kpi-ok">
    <div class="ds-kpi-label">Compliant</div><strong id="kOk">—</strong>
    <div class="ds-kpi-foot" id="kOkPct">—</div><i class="bi bi-check-circle"></i>
  </div>
  <div class="ds-kpi ds-kpi-drift">
    <div class="ds-kpi-label">Drift</div><strong id="kDrift">—</strong>
    <div class="ds-kpi-foot" id="kDriftPct">—</div><i class="bi bi-exclamation-triangle"></i>
  </div>
  <div class="ds-kpi ds-kpi-err">
    <div class="ds-kpi-label">Fehler / Offline</div><strong id="kError">—</strong>
    <div class="ds-kpi-foot">Agent nicht prüfbar oder Fehler</div><i class="bi bi-power"></i>
  </div>
  <div class="ds-kpi">
    <div class="ds-kpi-label">Baselines</div><strong id="kPolicies">—</strong>
    <div class="ds-kpi-foot" id="kPoliciesFoot">aktiv</div><i class="bi bi-file-earmark-text"></i>
  </div>
</div>

<section class="card shadow-sm mb-3">
 <div class="card-body">
  <div class="ds-toolbar">
    <input class="form-control" id="dsSearch" placeholder="Server suchen …" autocomplete="off">
    <select class="form-select" id="dsGroup"><option value="">Alle Gruppen</option></select>
    <select class="form-select" id="dsLabel"><option value="">Alle Labels</option></select>
    <select class="form-select" id="dsPolicy"><option value="">Baselines werden geladen …</option></select>
    <div class="form-check form-switch m-0">
      <input class="form-check-input" type="checkbox" id="dsOnlyDrift">
      <label class="form-check-label small" for="dsOnlyDrift">Nur Abweichungen</label>
    </div>
    <div class="d-flex gap-2 justify-content-end">
      <button class="btn btn-primary btn-sm" id="dsCheck" disabled><i class="bi bi-search me-1"></i>Check only</button>
      <button class="btn btn-warning btn-sm d-none" id="dsCanary" disabled><i class="bi bi-bezier2 me-1"></i>Canary ausrollen</button>
      <button class="btn btn-success btn-sm d-none" id="dsRemaining" disabled><i class="bi bi-fast-forward me-1"></i>Rest ausrollen</button>
      <button class="btn btn-success btn-sm" id="dsEnforceAll" disabled><i class="bi bi-shield-check me-1"></i>Drift beheben</button>
      <button class="btn btn-outline-secondary btn-sm" id="dsEdit" title="Baselines bearbeiten"><i class="bi bi-braces"></i></button>
    </div>
  </div>
  <div class="small text-body-secondary mt-2" id="dsPolicyMeta"></div>
 </div>

 <div class="table-responsive">
  <table class="table table-hover align-middle mb-0 ds-table">
   <thead>
    <tr>
      <th>Server</th><th>Gruppen / Labels</th><th>Baseline / Quelle</th><th>Soll</th>
      <th>Ist</th><th>Status</th><th>Letzte Prüfung</th><th class="text-end">Aktionen</th>
    </tr>
   </thead>
   <tbody id="dsBody"><tr><td colspan="8" class="ds-empty">Noch keine Compliance-Prüfung ausgeführt.</td></tr></tbody>
  </table>
 </div>
</section>

<div class="ds-bottom mb-3">
 <section class="card shadow-sm">
  <div class="card-header mmbb-card-header d-flex justify-content-between align-items-center">
   <span><i class="bi bi-file-earmark-check me-1"></i>Baseline Details</span>
   <button class="btn btn-outline-secondary btn-sm" id="dsEdit2">Baseline bearbeiten</button>
  </div>
  <div class="card-body">
   <dl class="ds-detail-grid mb-0">
    <dt>Baseline</dt><dd id="pdId">—</dd>
    <dt>Beschreibung</dt><dd id="pdDescription">—</dd>
    <dt>Quelle</dt><dd id="pdDeployment">—</dd>
    <dt>Selector</dt><dd id="pdSelector">—</dd>
    <dt>Soll</dt><dd id="pdDesired">—</dd>
    <dt>Modus</dt><dd id="pdMode">—</dd><dt>Rollout</dt><dd id="pdRollout">—</dd>
    <dt>Max. Ziele</dt><dd id="pdMax">—</dd>
   </dl>
  </div>
 </section>

 <section class="card shadow-sm">
  <div class="card-header mmbb-card-header"><i class="bi bi-bar-chart me-1"></i>Aktuelle Compliance-Verteilung</div>
  <div class="card-body">
   <div class="ds-dist">
    <div class="ds-dist-row"><span>Compliant</span><div class="ds-dist-track"><div id="barOk" class="ds-dist-bar ok" style="width:0"></div></div><strong id="barOkN">0</strong></div>
    <div class="ds-dist-row"><span>Drift</span><div class="ds-dist-track"><div id="barDrift" class="ds-dist-bar drift" style="width:0"></div></div><strong id="barDriftN">0</strong></div>
    <div class="ds-dist-row"><span>Nicht installiert</span><div class="ds-dist-track"><div id="barMissing" class="ds-dist-bar missing" style="width:0"></div></div><strong id="barMissingN">0</strong></div>
    <div class="ds-dist-row"><span>Fehler</span><div class="ds-dist-track"><div id="barError" class="ds-dist-bar error" style="width:0"></div></div><strong id="barErrorN">0</strong></div>
   </div>
  </div>
 </section>
</div>

<section class="card shadow-sm d-none" id="dsEditorCard">
 <div class="card-header mmbb-card-header d-flex justify-content-between align-items-center">
  <span><i class="bi bi-braces me-1"></i>desired_state.json</span><span id="dsEditorState" class="small"></span>
 </div>
 <div class="card-body">
  <textarea id="dsEditor" class="form-control ds-editor" spellcheck="false"></textarea>
  <div class="d-flex gap-2 mt-3">
   <button class="btn btn-outline-primary" id="dsValidate">Validieren</button>
   <button class="btn btn-primary" id="dsSave">Atomar speichern</button>
  </div>
 </div>
</section>

<div id="dsModalBackdrop" class="ds-modal-backdrop ds-hidden" aria-hidden="true">
 <div class="ds-modal" role="dialog" aria-modal="true" aria-labelledby="dsModalTitle">
  <div class="ds-modal-head">
   <strong id="dsModalTitle">Server Details</strong>
   <button class="btn btn-sm btn-outline-secondary" id="dsModalClose" aria-label="Schließen"><i class="bi bi-x-lg"></i></button>
  </div>
  <div class="ds-modal-body" id="dsModalBody"></div>
 </div>
</div>
</div>

<script>
const DS = {
 csrf: <?= json_encode($csrfToken, JSON_UNESCAPED_SLASHES) ?>,
 policies: [], summary: null, results: []
};
const $ = id => document.getElementById(id);
const esc = v => String(v ?? '').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
const shortSha = v => String(v ?? '') ? String(v).slice(0,12) : '—';
const pct = (n,t) => t > 0 ? `${Math.round((n/t)*100)}%` : '0%';
function msg(text,type='info'){const e=$('dsMsg');e.className='alert alert-'+type;e.textContent=text;e.classList.remove('d-none')}
function statusHtml(state){
 const map={
  compliant:['check-circle','compliant','Compliant'],
  drift:['exclamation-triangle','drift','Drift'],
  not_installed:['dash-circle','not_installed','Nicht installiert'],
  desired_unknown:['question-circle','desired_unknown','Soll unbekannt'],
  error:['x-circle','error','Fehler']
 };
 const x=map[state]||['question-circle','desired_unknown',state];
 return `<span class="ds-status ${x[1]}"><i class="bi bi-${x[0]}"></i>${esc(x[2])}</span>`;
}
async function api(url,opts={}){
 const r=await fetch(url,{cache:'no-store',...opts});
 const j=await r.json().catch(()=>({ok:false,error:'Ungültige Serverantwort'}));
 if(!r.ok||!j.ok)throw new Error(j.error||`HTTP ${r.status}`);
 return j;
}
function selectedPolicy(){return DS.policies.find(x=>x.id===$('dsPolicy').value)||null}
function updatePolicyDetails(){
 const p=selectedPolicy();
 if(!p){
  for(const id of ['pdId','pdDescription','pdDeployment','pdSelector','pdDesired','pdMode','pdRollout','pdMax']) $(id).textContent='—';
  $('dsPolicyMeta').textContent=''; $('dsCheck').disabled=true; return;
 }
 const groups=(p.selector?.groups||[]).map(x=>`group=${x}`);
 const labels=Object.entries(p.selector?.labels||{}).map(([k,v])=>`${k}=${v}`);
 const sourceType=p.source?.type||'git';
 let sourceLabel='', d='';
 if(sourceType==='config_manager'){
   sourceLabel=`Config Manager: ${p.source.reference_server}/${p.source.source_config} → ${p.source.target_config}`;
   d='Hash der Referenzdatei';
 }else{
   sourceLabel=`Git Deployment: ${p.deployment}`;
   d=p.desired?.type==='allowed_ref'?'allowed_ref':`${p.desired?.type}: ${p.desired?.value||'—'}`;
 }
 $('pdId').textContent=p.id;
 $('pdDescription').textContent=p.description||'—';
 $('pdDeployment').textContent=sourceLabel;
 $('pdSelector').textContent=[...groups,...labels].join(' · ')||'alle';
 $('pdDesired').textContent=d;
 $('pdMode').textContent=p.enforcement;
 const rollout=p.rollout||{strategy:'all'};
 const isCanary=rollout.strategy==='canary';
 const csel=[
   ...(rollout.canary_selector?.groups||[]).map(x=>`group=${x}`),
   ...Object.entries(rollout.canary_selector?.labels||{}).map(([k,v])=>`${k}=${v}`)
 ].join(' · ');
 $('pdRollout').textContent=isCanary
   ? `Canary (${csel||'Selector'}, max ${rollout.max_canary_targets||5}) → Rest`
   : 'Alle Zielserver';
 $('pdMax').textContent=String(p.max_targets);
 $('dsPolicyMeta').textContent=`${p.matched_servers} Zielserver · ${sourceLabel} · Soll: ${d} · ${p.enforcement}`;
 $('dsCheck').disabled=!p.enabled;
 $('dsEnforceAll').classList.toggle('d-none',isCanary);
 $('dsCanary').classList.toggle('d-none',!isCanary);
 $('dsRemaining').classList.toggle('d-none',!isCanary);
 $('dsEnforceAll').disabled=!p.enabled||p.enforcement==='check_only';
 $('dsCanary').disabled=!p.enabled||p.enforcement==='check_only';
 $('dsRemaining').disabled=!p.enabled||p.enforcement==='check_only';
}
function buildFilters(){
 const groups=new Set(), labels=new Set();
 for(const s of (DS.summary?.servers||[])){
  for(const g of (s.groups||[])) groups.add(g);
  for(const [k,v] of Object.entries(s.labels||{})) labels.add(`${k}=${v}`);
 }
 const g=$('dsGroup'), l=$('dsLabel');
 g.innerHTML='<option value="">Alle Gruppen</option>'+[...groups].sort().map(x=>`<option value="${esc(x)}">${esc(x)}</option>`).join('');
 l.innerHTML='<option value="">Alle Labels</option>'+[...labels].sort().map(x=>`<option value="${esc(x)}">${esc(x)}</option>`).join('');
}
async function loadSummary(){
 try{
  const j=await api('desired_state.php?api=summary');
  DS.summary=j; DS.policies=j.policies||[];
  $('kFleet').textContent=(j.servers||[]).length;
  $('kFleetFoot').textContent=`${(j.servers||[]).length} in Registry`;
  $('kPolicies').textContent=DS.policies.length;
  $('kPoliciesFoot').textContent=`${DS.policies.filter(p=>p.enabled).length} aktiv`;
  const current=$('dsPolicy').value;
  $('dsPolicy').innerHTML=DS.policies.length
   ? DS.policies.map(p=>`<option value="${esc(p.id)}">${esc(p.id)}${p.enabled?'':' [deaktiviert]'}</option>`).join('')
   : '<option value="">Keine Policies</option>';
  if(current && DS.policies.some(p=>p.id===current)) $('dsPolicy').value=current;
  buildFilters(); updatePolicyDetails();
 }catch(e){msg(e.message,'danger')}
}
function renderDistribution(summary={}){
 const total=summary.total||0;
 const vals={
  ok:summary.compliant||0, drift:summary.drift||0,
  missing:summary.not_installed||0, error:summary.error||0
 };
 $('kOk').textContent=vals.ok; $('kOkPct').textContent=pct(vals.ok,total);
 $('kDrift').textContent=vals.drift; $('kDriftPct').textContent=pct(vals.drift,total);
 $('kError').textContent=vals.error;
 for(const [key,n] of Object.entries(vals)){
  const cap=key[0].toUpperCase()+key.slice(1);
  $(`bar${cap}`).style.width=pct(n,total);
  $(`bar${cap}N`).textContent=n;
 }
}
function rowMatches(r){
 const q=$('dsSearch').value.trim().toLowerCase();
 const group=$('dsGroup').value;
 const label=$('dsLabel').value;
 const only=$('dsOnlyDrift').checked;
 if(q && !(`${r.server_name} ${r.server_url||''} ${r.policy} ${r.deployment||''} ${r.source_type||''} ${r.source_config||''} ${r.target_config||''}`).toLowerCase().includes(q)) return false;
 if(group && !(r.groups||[]).includes(group)) return false;
 if(label){
  const labels=Object.entries(r.labels||{}).map(([k,v])=>`${k}=${v}`);
  if(!labels.includes(label)) return false;
 }
 if(only && !['drift','not_installed','error','desired_unknown'].includes(r.compliance)) return false;
 return true;
}
function renderTable(){
 const rows=DS.results.filter(rowMatches);
 $('dsBody').innerHTML=rows.length?rows.map(r=>{
  const tags=[
    ...(r.groups||[]).map(g=>`<span class="badge text-bg-primary ds-label">${esc(g)}</span>`),
    ...Object.entries(r.labels||{}).map(([k,v])=>`<span class="badge text-bg-secondary ds-label">${esc(k)}:${esc(v)}</span>`)
  ].join('');
  let desiredLabel='', currentLabel='', sourceLabel='';
  if(r.source_type==='config_manager'){
    desiredLabel=`<div class="ds-sha" title="${esc(r.desired_hash||'')}">${shortSha(r.desired_hash)}</div><div class="small text-body-secondary">${esc(r.reference_server)}:${esc(r.source_config)}</div>`;
    currentLabel=`<div class="ds-sha" title="${esc(r.active_hash||'')}">${shortSha(r.active_hash)}</div><div class="small text-body-secondary">${esc(r.target_config)}</div>`;
    sourceLabel=`<span class="badge text-bg-info ds-label">Config Manager</span><div class="small text-body-secondary">${esc(r.target_config)}</div>`;
  }else{
    desiredLabel=r.desired_type==='tag'&&r.desired_value
      ? `<div><i class="bi bi-tag me-1"></i>${esc(r.desired_value)}</div><div class="ds-sha text-body-secondary">${shortSha(r.desired_commit)}</div>`
      : `<span class="ds-sha" title="${esc(r.desired_commit||'')}">${shortSha(r.desired_commit)}</span>`;
    currentLabel=`<span class="ds-sha" title="${esc(r.active_commit||'')}">${shortSha(r.active_commit)}</span>`;
    sourceLabel=`<span class="badge text-bg-dark ds-label">Git</span><div class="small text-body-secondary">${esc(r.deployment)}</div>`;
  }
  const ts=r.checked_at?new Date(r.checked_at).toLocaleString():'—';
  const dot=r.compliance==='error'?'error':'';
  return `<tr>
   <td><div class="fw-semibold"><span class="ds-server-dot ${dot}"></span>${esc(r.server_name)}</div><div class="small text-body-secondary">${esc(r.server_url||'')}</div></td>
   <td>${tags||'—'}</td><td><span class="text-primary">${esc(r.policy)}</span>${sourceLabel}</td>
   <td>${desiredLabel}</td>
   <td>${currentLabel}</td>
   <td>${statusHtml(r.compliance)}</td><td class="small">${esc(ts)}</td>
   <td class="text-end text-nowrap">
    <button class="btn btn-outline-secondary btn-sm me-1" data-detail="${r.server_idx}">Details</button>
    <button class="btn btn-success btn-sm" data-enforce="${r.server_idx}" ${r.compliance==='compliant'?'disabled':''}><i class="bi bi-play-fill"></i> Enforce</button>
   </td></tr>`;
 }).join(''):'<tr><td colspan="8" class="ds-empty">Keine Server entsprechen den Filtern.</td></tr>';
}
function renderResult(j){
 DS.results=j.results||[];
 renderDistribution(j.summary||{});
 renderTable();
}
async function run(action,serverIdx=null){
 const p=$('dsPolicy').value;if(!p)return;
 if(['enforce','enforce_canary','enforce_remaining'].includes(action)){
  let label=serverIdx===null?'alle abweichenden Zielserver':(DS.results.find(x=>x.server_idx===serverIdx)?.server_name||'diesen Server');
  if(action==='enforce_canary') label='die Canary-Gruppe';
  if(action==='enforce_remaining') label='die restlichen Zielserver (Canary-Gate wird geprüft)';
  if(!confirm(`Policy "${p}" auf ${label} ausrollen?`))return;
 }
 $('dsCheck').disabled=true;
 try{
  const payload={action,policy_id:p,csrf_token:DS.csrf};
  if(serverIdx!==null) payload.server_idx=serverIdx;
  const j=await api('desired_state.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
  if(serverIdx===null) renderResult(j);
  else {
   const changed=(j.results||[])[0];
   const pos=DS.results.findIndex(x=>x.server_idx===serverIdx);
   if(changed&&pos>=0) DS.results[pos]=changed; else if(changed) DS.results.push(changed);
   const s={total:DS.results.length,compliant:0,drift:0,not_installed:0,desired_unknown:0,error:0};
   for(const r of DS.results) s[r.compliance]=(s[r.compliance]||0)+1;
   renderDistribution(s); renderTable();
  }
  msg(action==='check'?'Compliance-Prüfung abgeschlossen.':'Enforcement abgeschlossen.','success');
 }catch(e){msg(e.message,'danger')}
 finally{updatePolicyDetails()}
}
function showDetails(idx){
 const r=DS.results.find(x=>x.server_idx===idx); if(!r)return;
 const labels=Object.entries(r.labels||{}).map(([k,v])=>`${k}=${v}`).join(', ')||'—';
 $('dsModalTitle').textContent=`Server Details: ${r.server_name}`;
 const sourceRows=r.source_type==='config_manager'
   ? `<dt>Quelle</dt><dd>Config Manager</dd>
      <dt>Referenzserver</dt><dd>${esc(r.reference_server||'—')}</dd>
      <dt>Quell-Config</dt><dd class="ds-code">${esc(r.source_config||'—')}</dd>
      <dt>Ziel-Config</dt><dd class="ds-code">${esc(r.target_config||'—')}</dd>
      <dt>Soll SHA-256</dt><dd class="ds-code">${esc(r.desired_hash||'—')}</dd>
      <dt>Ist SHA-256</dt><dd class="ds-code">${esc(r.active_hash||'—')}</dd>`
   : `<dt>Quelle</dt><dd>Git</dd>
      <dt>Deployment</dt><dd>${esc(r.deployment||'—')}</dd>
      <dt>Allowed Ref</dt><dd class="ds-code">${esc(r.allowed_ref||'—')}</dd>
      <dt>Repository</dt><dd class="ds-code">${esc(r.repository_commit||'—')}</dd>
      <dt>Soll Commit</dt><dd class="ds-code">${esc(r.desired_commit||'—')}</dd>
      <dt>Ist Commit</dt><dd class="ds-code">${esc(r.active_commit||'—')}</dd>`;
 $('dsModalBody').innerHTML=`<dl class="ds-detail-grid mb-0">
  <dt>Agent URL</dt><dd>${esc(r.server_url||'—')}</dd>
  <dt>Baseline</dt><dd>${esc(r.policy)}</dd>
  <dt>Gruppen</dt><dd>${esc((r.groups||[]).join(', ')||'—')}</dd>
  <dt>Labels</dt><dd>${esc(labels)}</dd>
  ${sourceRows}
  <dt>Status</dt><dd>${statusHtml(r.compliance)}</dd>
  <dt>Fehler</dt><dd class="text-danger">${esc(r.error||'—')}</dd>
 </dl>`;
 $('dsModalBackdrop').classList.remove('ds-hidden'); $('dsModalBackdrop').setAttribute('aria-hidden','false');
}
function hideDetails(){$('dsModalBackdrop').classList.add('ds-hidden');$('dsModalBackdrop').setAttribute('aria-hidden','true')}
async function toggleEditor(){
 const c=$('dsEditorCard'); c.classList.toggle('d-none');
 if(!c.classList.contains('d-none')){
  try{const j=await api('desired_state.php?api=document');$('dsEditor').value=j.content||''}catch(e){msg(e.message,'danger')}
 }
}
async function editorAction(action){
 try{
  const j=await api('desired_state.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,content:$('dsEditor').value,csrf_token:DS.csrf})});
  $('dsEditorState').textContent=action==='save'?'gespeichert':'gültig';
  msg(action==='save'?'Baselines atomar gespeichert.':'Baseline-Konfiguration ist gültig.','success');
  if(action==='save')await loadSummary();
 }catch(e){$('dsEditorState').textContent='Fehler';msg(e.message,'danger')}
}

$('dsPolicy').addEventListener('change',()=>{updatePolicyDetails();DS.results=[];renderDistribution({});renderTable()});
$('dsCheck').addEventListener('click',()=>run('check'));
$('dsEnforceAll').addEventListener('click',()=>run('enforce'));
$('dsCanary').addEventListener('click',()=>run('enforce_canary'));
$('dsRemaining').addEventListener('click',()=>run('enforce_remaining'));
$('dsReload').addEventListener('click',async()=>{await loadSummary();if(selectedPolicy()?.enabled)await run('check')});
$('dsEdit').addEventListener('click',toggleEditor); $('dsEdit2').addEventListener('click',toggleEditor);
$('dsValidate').addEventListener('click',()=>editorAction('validate')); $('dsSave').addEventListener('click',()=>editorAction('save'));
for(const id of ['dsSearch','dsGroup','dsLabel','dsOnlyDrift']) $(id).addEventListener(id==='dsSearch'?'input':'change',renderTable);
$('dsBody').addEventListener('click',e=>{
 const detail=e.target.closest('[data-detail]'); if(detail){showDetails(Number(detail.dataset.detail));return}
 const enforce=e.target.closest('[data-enforce]'); if(enforce){run('enforce',Number(enforce.dataset.enforce))}
});
$('dsModalClose').addEventListener('click',hideDetails);
$('dsModalBackdrop').addEventListener('click',e=>{if(e.target===$('dsModalBackdrop'))hideDetails()});
document.addEventListener('keydown',e=>{if(e.key==='Escape')hideDetails()});

(async()=>{await loadSummary(); if(selectedPolicy()?.enabled) await run('check')})();
</script>
<?php require MMBB_UI . '/includes/js.php'; ?>
</body>
</html>
