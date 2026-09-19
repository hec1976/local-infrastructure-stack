<?php
declare(strict_types=1);

require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../autoloader.php';
require_once __DIR__ . '/../Repository/ConfigManagerRepository.php';
require_once __DIR__ . '/../Service/ConfigManagerService.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';
require_once __DIR__ . '/../standalone/audit.php';

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;

if (!mmbb_has_service('ConfigManager')) {
    http_response_code(403);
    echo 'Forbidden';
    exit;
}

function ops_h(mixed $v): string
{
    return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function ops_try(callable $fn, mixed $fallback = null): array
{
    try {
        return ['ok' => true, 'value' => $fn(), 'error' => ''];
    } catch (Throwable $e) {
        return ['ok' => false, 'value' => $fallback, 'error' => $e->getMessage()];
    }
}

function ops_action_payload(array $result): array
{
    $raw = $result['response'] ?? null;
    if (is_array($raw)) {
        return $raw;
    }
    if (is_string($raw) && trim($raw) !== '') {
        $decoded = json_decode($raw, true);
        if (is_array($decoded)) {
            return $decoded;
        }
        return ['stdout' => trim($raw)];
    }
    return [];
}

function ops_state(string $raw): string
{
    $v = strtolower(trim($raw));
    if ($v === '') return 'unknown';
    if (preg_match('/\b(running|active|ok|healthy|success|up|ready|valid)\b/', $v)) return 'ok';
    if (preg_match('/\b(warn|warning|degraded|unmonitored|partial|mismatch)\b/', $v)) return 'warning';
    if (preg_match('/\b(failed|error|down|invalid|missing|unhealthy)\b/', $v)) return 'error';
    if (preg_match('/\b(stopped|inactive|disabled|off|not configured|nicht konfiguriert)\b/', $v)) return 'neutral';
    return 'unknown';
}

function ops_badge_class(string $state): string
{
    return match ($state) {
        'ok' => 'text-bg-success',
        'warning' => 'text-bg-warning',
        'error' => 'text-bg-danger',
        'neutral' => 'text-bg-secondary',
        default => 'text-bg-light border text-dark',
    };
}

function ops_state_label(string $state): string
{
    return match ($state) {
        'ok' => 'OK',
        'warning' => 'WARNUNG',
        'error' => 'FEHLER',
        'neutral' => 'INAKTIV',
        default => 'UNBEKANNT',
    };
}

function ops_bool_state(bool $ok): string
{
    return $ok ? 'ok' : 'error';
}

$servers = [];
$pageError = '';
try {
    $servers = cm_load_config_manager_servers(__DIR__ . '/../config/config.php');
} catch (Throwable $e) {
    $pageError = $e->getMessage();
}

$serverIdx = isset($_GET['server_idx']) ? (int)$_GET['server_idx'] : 0;
if ($serverIdx < 0 || !isset($servers[$serverIdx])) $serverIdx = 0;
$server = $servers[$serverIdx] ?? null;

$overview = ['ok' => false, 'value' => ['http_code' => 0, 'response' => []], 'error' => 'Kein Server verfügbar.'];
$health = ['ok' => false, 'value' => ['http_code' => 0, 'response' => []], 'error' => 'Kein Server verfügbar.'];
$configsResult = ['ok' => false, 'value' => [], 'error' => 'Kein Server verfügbar.'];
$backupsResult = ['ok' => false, 'value' => [], 'error' => 'Kein Server verfügbar.'];
$monitResult = ['ok' => false, 'value' => [], 'error' => 'Kein Server verfügbar.'];
$modsecResult = ['ok' => false, 'value' => [], 'error' => 'Kein Server verfügbar.'];
$serviceRows = [];

if (is_array($server)) {
    $service = new ConfigManagerService(new ConfigManagerRepository($server));
    $overview = ops_try(fn() => $service->getAgentOverview(), ['http_code' => 0, 'response' => []]);
    $health = ops_try(fn() => $service->getAgentHealth(), ['http_code' => 0, 'response' => []]);
    $configsResult = ops_try(fn() => $service->getAllConfigs(), []);

    $configs = is_array($configsResult['value']) ? $configsResult['value'] : [];
    $ids = [];
    foreach ($configs as $cfg) {
        if (is_array($cfg) && trim((string)($cfg['id'] ?? '')) !== '') {
            $ids[] = (string)$cfg['id'];
        }
    }
    if ($configsResult['ok']) {
        $backupsResult = ops_try(fn() => $service->getAllBackups($ids), []);
    }

    // Einen Status-Call pro systemd-Service statt pro Config-ID ausführen.
    // Mehrere Apache-/Postfix-Configs erzeugen so keine redundanten Status-Abfragen.
    $representatives = [];
    foreach ($configs as $cfg) {
        if (!is_array($cfg)) continue;
        $id = trim((string)($cfg['id'] ?? ''));
        $svc = trim((string)($cfg['service'] ?? ''));
        $actions = array_map('strtolower', array_map('strval', (array)($cfg['actions'] ?? [])));
        if ($id === '' || $svc === '' || !in_array('status', $actions, true)) continue;
        if (!isset($representatives[$svc])) {
            $representatives[$svc] = [
                'config_id' => $id,
                'configs' => [],
                'desired' => trim((string)($cfg['desired_status'] ?? 'running')) ?: 'running',
                'desired_values' => [],
            ];
        }
        $representatives[$svc]['configs'][] = $id;
        $desired = trim((string)($cfg['desired_status'] ?? 'running')) ?: 'running';
        $representatives[$svc]['desired_values'][$desired] = true;
    }

    foreach ($representatives as $svc => $meta) {
        $statusResult = ops_try(fn() => $service->callAction((string)$meta['config_id'], 'status'), []);
        $payload = $statusResult['ok'] && is_array($statusResult['value']) ? ops_action_payload($statusResult['value']) : [];
        $httpCode = $statusResult['ok'] ? (int)($statusResult['value']['http_code'] ?? 0) : 0;
        $runtime = trim((string)($payload['status'] ?? $payload['state'] ?? $payload['message'] ?? ''));
        if ($runtime === '' && !$statusResult['ok']) $runtime = 'error';
        $runtimeState = ($httpCode >= 200 && $httpCode < 300) ? ops_state($runtime) : 'error';
        $desired = (string)$meta['desired'];
        $desiredState = ops_state($desired);
        $conflict = count($meta['desired_values']) > 1;
        $matches = !$conflict && (
            ($desiredState === 'ok' && $runtimeState === 'ok') ||
            ($desiredState === 'error' && $runtimeState === 'error') ||
            ($desiredState === 'neutral' && in_array($runtimeState, ['neutral', 'error'], true))
        );
        $serviceRows[] = [
            'service' => $svc,
            'config_id' => (string)$meta['config_id'],
            'config_count' => count($meta['configs']),
            'desired' => $desired,
            'runtime' => $runtime !== '' ? $runtime : 'unbekannt',
            'runtime_state' => $runtimeState,
            'matches' => $matches,
            'conflict' => $conflict,
            'error' => $statusResult['error'],
        ];
    }

    $monitResult = ops_try(fn() => $service->getMonitStatus(), []);
    $modsecResult = ops_try(fn() => $service->getModSecurityInfo(), []);
}

$agentResponse = is_array($overview['value']['response'] ?? null) ? $overview['value']['response'] : [];
$agentHttp = (int)($overview['value']['http_code'] ?? 0);
$healthResponse = is_array($health['value']['response'] ?? null) ? $health['value']['response'] : [];
$healthHttp = (int)($health['value']['http_code'] ?? 0);
$configs = is_array($configsResult['value']) ? $configsResult['value'] : [];
$backups = is_array($backupsResult['value']) ? $backupsResult['value'] : [];
$monit = is_array($monitResult['value']) ? $monitResult['value'] : [];
$modsecWrap = is_array($modsecResult['value']) ? $modsecResult['value'] : [];
$modsec = is_array($modsecWrap['response'] ?? null) ? $modsecWrap['response'] : [];

$totalConfigs = count($configs);
$coveredConfigs = 0;
$totalBackups = 0;
$latestBackup = '';
foreach ($configs as $cfg) {
    if (!is_array($cfg)) continue;
    $id = (string)($cfg['id'] ?? '');
    $items = is_array($backups[$id] ?? null) ? $backups[$id] : [];
    if ($items) $coveredConfigs++;
    $totalBackups += count($items);
    foreach ($items as $file) {
        $f = (string)$file;
        if ($f > $latestBackup) $latestBackup = $f;
    }
}
$backupCoverage = $totalConfigs > 0 ? (int)round(($coveredConfigs / $totalConfigs) * 100) : 0;

$audit = ['ok' => false, 'count24' => 0, 'errors24' => 0, 'last' => '', 'error' => ''];
try {
    if (!mmbb_audit_load_env()) throw new RuntimeException('Audit-DB-Verzeichnis nicht beschreibbar.');
    ensure_log_schema();
    $pdo = log_db();
    $since = gmdate('Y-m-d\\TH:i:s\\Z', time() - 86400);
    $moduleKey = mmbb_audit_module_key();
    $st = $pdo->prepare('SELECT COUNT(*) FROM audit_log WHERE module = ? AND ts >= ?');
    $st->execute([$moduleKey, $since]);
    $audit['count24'] = (int)$st->fetchColumn();
    $st = $pdo->prepare("SELECT COUNT(*) FROM audit_log WHERE module = ? AND ts >= ? AND lower(result) IN ('error','failed','failure')");
    $st->execute([$moduleKey, $since]);
    $audit['errors24'] = (int)$st->fetchColumn();
    $st = $pdo->prepare('SELECT ts FROM audit_log WHERE module = ? ORDER BY id DESC LIMIT 1');
    $st->execute([$moduleKey]);
    $audit['last'] = (string)($st->fetchColumn() ?: '');
    $audit['ok'] = true;
} catch (Throwable $e) {
    $audit['error'] = $e->getMessage();
}

$modules = [];
$agentStateRaw = (string)($agentResponse['status'] ?? ($agentHttp === 200 ? 'running' : 'error'));
$modules[] = [
    'name' => 'Config-Agent', 'icon' => 'bi bi-cpu',
    'state' => ($agentHttp === 200 && !empty($agentResponse['ok'])) ? ops_state($agentStateRaw) : 'error',
    'value' => $agentHttp === 200 ? ($agentStateRaw . ' · v' . (string)($agentResponse['version'] ?? '—')) : 'nicht erreichbar',
    'href' => 'index.php?server_idx=' . $serverIdx,
];

$managed = is_array($agentResponse['managed_configs'] ?? null) ? $agentResponse['managed_configs'] : [];
$modules[] = [
    'name' => 'Managed Configs', 'icon' => 'bi bi-sliders',
    'state' => !empty($managed['valid']) && $configsResult['ok'] ? 'ok' : 'error',
    'value' => $totalConfigs . ' Einträge' . (!empty($managed['legacy']) ? ' · Legacy' : ''),
    'href' => 'configs_editor.php',
];

$gitDeploy = is_array($agentResponse['git_deploy'] ?? null) ? $agentResponse['git_deploy'] : [];
$gdEnabled = !empty($gitDeploy['enabled']);
$modules[] = [
    'name' => 'Git Deploy', 'icon' => 'bi bi-git',
    'state' => !$gdEnabled ? 'neutral' : (!empty($gitDeploy['config_valid']) && empty($gitDeploy['degraded']) ? 'ok' : 'error'),
    'value' => !$gdEnabled ? 'deaktiviert' : (!empty($gitDeploy['config_valid']) ? 'Konfiguration gültig' : 'Konfiguration fehlerhaft'),
    'href' => 'git_deploy_overview.php',
];

$gitUpload = is_array($agentResponse['git_upload'] ?? null) ? $agentResponse['git_upload'] : [];
$guEnabled = !empty($gitUpload['enabled']);
$modules[] = [
    'name' => 'Git Upload', 'icon' => 'bi bi-cloud-arrow-up',
    'state' => !$guEnabled ? 'neutral' : (!empty($gitUpload['valid']) && empty($gitUpload['degraded']) ? 'ok' : 'error'),
    'value' => !$guEnabled ? 'deaktiviert' : (!empty($gitUpload['valid']) ? 'bereit' : 'degradiert'),
    'href' => 'git_upload.php',
];

if ($modsecResult['ok'] && is_array($modsec) && !empty($modsec['ok']) && (int)($modsecWrap['http_code'] ?? 0) >= 200 && (int)($modsecWrap['http_code'] ?? 0) < 300) {
    $runtime = is_array($modsec['runtime'] ?? null) ? $modsec['runtime'] : [];
    $installed = !empty($modsec['installed']);
    $msHealthy = $installed && !empty($modsec['module_loaded']) && !empty($modsec['crs_detected']) && !empty($runtime['override_matches']);
    $modules[] = [
        'name' => 'ModSecurity / CRS', 'icon' => 'bi bi-shield-lock',
        'state' => !$installed ? 'neutral' : ($msHealthy ? 'ok' : 'warning'),
        'value' => !$installed ? 'nicht installiert' : ((string)($runtime['effective_override_mode'] ?? '—') . ' · CRS ' . (!empty($modsec['crs_detected']) ? 'OK' : 'fehlt')),
        'href' => 'modsecurity.php',
    ];
} else {
    $modules[] = ['name'=>'ModSecurity / CRS','icon'=>'bi bi-shield-lock','state'=>'unknown','value'=>'Status nicht verfügbar','href'=>'modsecurity.php'];
}

if ($monitResult['ok'] && !empty($monit['ok'])) {
    $summary = is_array($monit['summary'] ?? null) ? $monit['summary'] : [];
    $overall = (string)($summary['overall'] ?? 'unknown');
    $modules[] = [
        'name' => 'Monit', 'icon' => 'bi bi-activity',
        'state' => ops_state($overall),
        'value' => (int)($summary['healthy'] ?? 0) . '/' . (int)($summary['total'] ?? 0) . ' healthy',
        'href' => 'monit_status.php',
    ];
} else {
    $modules[] = ['name'=>'Monit','icon'=>'bi bi-activity','state'=>'warning','value'=>'nicht erreichbar','href'=>'monit_status.php'];
}

$modules[] = [
    'name' => 'Backups / Restore', 'icon' => 'bi bi-clock-history',
    'state' => !$backupsResult['ok'] ? 'error' : ($backupCoverage >= 80 ? 'ok' : ($backupCoverage > 0 ? 'warning' : 'neutral')),
    'value' => $coveredConfigs . '/' . $totalConfigs . ' Configs · ' . $totalBackups . ' Backups',
    'href' => 'index.php?server_idx=' . $serverIdx,
];

$modules[] = [
    'name' => 'Audit-Trail', 'icon' => 'bi bi-file-earmark-text',
    'state' => $audit['ok'] ? ($audit['errors24'] > 0 ? 'warning' : 'ok') : 'error',
    'value' => $audit['ok'] ? ($audit['count24'] . ' Events / 24h · ' . $audit['errors24'] . ' Fehler') : 'DB nicht verfügbar',
    'href' => 'auditlog.php',
];

$dependencies = [];
$healthWarnings = is_array($healthResponse['warnings'] ?? null) ? $healthResponse['warnings'] : [];
$healthInfo = is_array($healthResponse['info'] ?? null) ? $healthResponse['info'] : [];
$healthErrors = is_array($healthResponse['errors'] ?? null) ? $healthResponse['errors'] : [];
$healthSummary = is_array($healthResponse['summary'] ?? null) ? $healthResponse['summary'] : [];
$healthOk = $health['ok'] && $healthHttp === 200 && !empty($healthResponse['ok']);
$healthState = !$healthOk ? 'error' : (count($healthWarnings) > 0 ? 'warning' : 'ok');
if ($healthOk) {
    $healthDetail = 'Health-Check erfolgreich';
    if (count($healthWarnings) > 0) $healthDetail .= ' · ' . count($healthWarnings) . ' Warnung(en)';
    $lazyBackups = (int)($healthSummary['backup_dirs_lazy'] ?? 0);
    if ($lazyBackups > 0) {
        $healthDetail .= ' · ' . $lazyBackups . ' Config(s) noch ohne Backup';
    } elseif (count($healthInfo) > 0) {
        $healthDetail .= ' · ' . count($healthInfo) . ' Info-Hinweis(e)';
    }
} else {
    $healthDetail = (string)($healthResponse['error'] ?? $health['error'] ?: 'nicht erreichbar');
}
$dependencies[] = [
    'name' => 'Config-Agent API /health',
    'state' => $healthState,
    'detail' => $healthDetail,
];
foreach (['curl' => 'PHP cURL', 'json' => 'PHP JSON', 'pdo_sqlite' => 'PHP PDO SQLite', 'mbstring' => 'PHP mbstring'] as $ext => $label) {
    $loaded = extension_loaded($ext);
    $dependencies[] = ['name' => $label, 'state' => $loaded ? 'ok' : 'error', 'detail' => $loaded ? 'geladen' : 'Extension fehlt'];
}
$dependencies[] = [
    'name' => 'Audit-Datenbank', 'state' => $audit['ok'] ? 'ok' : 'error',
    'detail' => $audit['ok'] ? ('letztes Event: ' . ($audit['last'] !== '' ? $audit['last'] : 'noch keines')) : $audit['error'],
];
$dependencies[] = [
    'name' => 'Backup-API', 'state' => $backupsResult['ok'] ? 'ok' : 'error',
    'detail' => $backupsResult['ok'] ? ($totalBackups . ' Sicherungen gefunden') : $backupsResult['error'],
];
$dependencies[] = [
    'name' => 'Monit XML API', 'state' => ($monitResult['ok'] && !empty($monit['ok'])) ? 'ok' : 'warning',
    'detail' => ($monitResult['ok'] && !empty($monit['ok'])) ? 'erreichbar' : ($monitResult['error'] ?: (string)($monit['error'] ?? 'nicht verfügbar')),
];
if ($modsecResult['ok'] && is_array($modsec) && !empty($modsec['ok']) && (int)($modsecWrap['http_code'] ?? 0) >= 200 && (int)($modsecWrap['http_code'] ?? 0) < 300) {
    $runtime = is_array($modsec['runtime'] ?? null) ? $modsec['runtime'] : [];
    $dependencies[] = [
        'name' => 'ModSecurity Runtime-Override',
        'state' => empty($modsec['installed']) ? 'neutral' : (!empty($runtime['override_matches']) ? 'ok' : 'warning'),
        'detail' => empty($modsec['installed']) ? 'nicht installiert' : ('Soll ' . (string)($runtime['configured_mode'] ?? '—') . ' · Effektiv ' . (string)($runtime['effective_override_mode'] ?? '—')),
    ];
}

$driftCount = 0;
foreach ($serviceRows as $row) {
    if (!$row['matches'] || $row['conflict']) $driftCount++;
}
$moduleErrors = count(array_filter($modules, fn($m) => in_array($m['state'], ['error'], true)));
$moduleWarnings = count(array_filter($modules, fn($m) => $m['state'] === 'warning'));
$overallState = $moduleErrors > 0 ? 'error' : (($moduleWarnings > 0 || $driftCount > 0) ? 'warning' : 'ok');
?>
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Betriebsübersicht – Config Manager</title>
  <?php require MMBB_UI . '/includes/css.php'; ?>
  <link rel="stylesheet" href="assets/css/operations.css?v=3.0.15">
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>
<div class="container mmbb-main py-3 operations-page">
  <?php require MMBB_UI . '/module_header.php'; ?>

  <?php if ($pageError !== ''): ?>
    <div class="alert alert-danger"><i class="bi bi-x-circle-fill me-2"></i><?= ops_h($pageError) ?></div>
  <?php endif; ?>

  <section class="card shadow-sm mb-3 ops-command-card">
    <div class="card-body d-flex flex-wrap align-items-end gap-3">
      <form method="get" class="d-flex flex-wrap align-items-end gap-2 me-auto">
        <div>
          <label for="server_idx" class="form-label small fw-semibold mb-1">Zielserver</label>
          <select class="form-select form-select-sm" id="server_idx" name="server_idx" onchange="this.form.submit()">
            <?php foreach ($servers as $i => $srv): ?>
              <option value="<?= (int)$i ?>" <?= $i === $serverIdx ? 'selected' : '' ?>><?= ops_h($srv['name'] ?? ('Server #' . $i)) ?></option>
            <?php endforeach; ?>
          </select>
        </div>
        <noscript><button class="btn btn-secondary btn-sm" type="submit">Laden</button></noscript>
      </form>
      <div class="ops-overall d-flex align-items-center gap-2">
        <span class="small text-body-secondary">Gesamtzustand</span>
        <span class="badge rounded-pill <?= ops_badge_class($overallState) ?>"><?= ops_state_label($overallState) ?></span>
      </div>
      <a class="btn btn-outline-secondary btn-sm" href="operations.php?server_idx=<?= (int)$serverIdx ?>"><i class="bi bi-arrow-clockwise me-1"></i>Neu prüfen</a>
    </div>
  </section>

  <div class="ops-module-grid mb-3">
    <?php foreach ($modules as $m): ?>
      <a class="card shadow-sm ops-module-card text-decoration-none" href="<?= ops_h($m['href']) ?>">
        <div class="card-body">
          <div class="d-flex align-items-start justify-content-between gap-2">
            <span class="ops-module-icon"><i class="<?= ops_h($m['icon']) ?>"></i></span>
            <span class="badge <?= ops_badge_class($m['state']) ?>"><?= ops_state_label($m['state']) ?></span>
          </div>
          <div class="ops-module-name"><?= ops_h($m['name']) ?></div>
          <div class="ops-module-value"><?= ops_h($m['value']) ?></div>
        </div>
      </a>
    <?php endforeach; ?>
  </div>

  <div class="row g-3 mb-3">
    <div class="col-xl-7">
      <section class="card shadow-sm h-100">
        <div class="card-header mmbb-card-header d-flex justify-content-between align-items-center gap-2">
          <span><i class="bi bi-shuffle me-1"></i>Runtime vs. Sollzustand</span>
          <span class="badge <?= $driftCount ? 'text-bg-warning' : 'text-bg-success' ?>"><?= $driftCount ?> Abweichung<?= $driftCount === 1 ? '' : 'en' ?></span>
        </div>
        <div class="card-body p-0">
          <div class="table-responsive">
            <table class="table table-sm table-hover align-middle mb-0 ops-drift-table">
              <thead class="table-light"><tr><th>Service</th><th>Soll</th><th>Runtime</th><th>Bewertung</th></tr></thead>
              <tbody>
              <?php if (!$serviceRows): ?>
                <tr><td colspan="4" class="text-center text-body-secondary py-4">Keine statusfähigen Services in managed_configs.json gefunden.</td></tr>
              <?php endif; ?>
              <?php foreach ($serviceRows as $row): ?>
                <?php $rowState = $row['conflict'] ? 'warning' : ($row['matches'] ? 'ok' : 'error'); ?>
                <tr>
                  <td><code><?= ops_h($row['service']) ?></code><?php if ($row['config_count'] > 1): ?><span class="badge text-bg-light border ms-1"><?= (int)$row['config_count'] ?> Configs</span><?php endif; ?></td>
                  <td><span class="badge text-bg-light border"><?= ops_h($row['desired']) ?></span></td>
                  <td><span class="badge <?= ops_badge_class($row['runtime_state']) ?>"><?= ops_h($row['runtime']) ?></span></td>
                  <td>
                    <span class="badge <?= ops_badge_class($rowState) ?>"><?= $row['conflict'] ? 'SOLL-KONFLIKT' : ($row['matches'] ? 'SYNCHRON' : 'DRIFT') ?></span>
                    <?php if ($row['error'] !== ''): ?><div class="small text-danger mt-1"><?= ops_h($row['error']) ?></div><?php endif; ?>
                  </td>
                </tr>
              <?php endforeach; ?>
              </tbody>
            </table>
          </div>
          <div class="small text-body-secondary px-3 py-2 border-top">Sollwert: <code>desired_status</code> aus managed_configs.json; für statusfähige verwaltete Services gilt ohne expliziten Wert standardmässig <code>running</code>.</div>
        </div>
      </section>
    </div>

    <div class="col-xl-5">
      <section class="card shadow-sm h-100">
        <div class="card-header mmbb-card-header"><i class="bi bi-diagram-3 me-1"></i>Health &amp; Abhängigkeiten</div>
        <div class="list-group list-group-flush ops-dependency-list">
          <?php foreach ($dependencies as $dep): ?>
            <div class="list-group-item d-flex align-items-start gap-3">
              <span class="ops-dep-dot ops-dep-<?= ops_h($dep['state']) ?>" aria-hidden="true"></span>
              <div class="flex-grow-1 min-w-0">
                <div class="d-flex justify-content-between gap-2"><strong><?= ops_h($dep['name']) ?></strong><span class="badge <?= ops_badge_class($dep['state']) ?>"><?= ops_state_label($dep['state']) ?></span></div>
                <div class="small text-body-secondary text-break mt-1"><?= ops_h($dep['detail']) ?></div>
              </div>
            </div>
          <?php endforeach; ?>
        </div>
      </section>
    </div>
  </div>

  <div class="row g-3">
    <div class="col-lg-6">
      <section class="card shadow-sm h-100">
        <div class="card-header mmbb-card-header d-flex justify-content-between align-items-center">
          <span><i class="bi bi-clock-history me-1"></i>Backup / Restore Readiness</span>
          <a class="btn btn-outline-warning btn-sm" href="index.php?server_idx=<?= (int)$serverIdx ?>">Backups &amp; Restore</a>
        </div>
        <div class="card-body">
          <div class="ops-kpi-row">
            <div><span>Abdeckung</span><strong><?= $backupCoverage ?>%</strong></div>
            <div><span>Configs mit Backup</span><strong><?= $coveredConfigs ?>/<?= $totalConfigs ?></strong></div>
            <div><span>Backups total</span><strong><?= $totalBackups ?></strong></div>
          </div>
          <div class="progress mt-3" role="progressbar" aria-label="Backup-Abdeckung" aria-valuenow="<?= $backupCoverage ?>" aria-valuemin="0" aria-valuemax="100"><div class="progress-bar" style="width:<?= $backupCoverage ?>%"></div></div>
          <div class="small text-body-secondary mt-2">Letzte erkannte Sicherung: <code><?= ops_h($latestBackup !== '' ? $latestBackup : '—') ?></code></div>
        </div>
      </section>
    </div>
    <div class="col-lg-6">
      <section class="card shadow-sm h-100">
        <div class="card-header mmbb-card-header d-flex justify-content-between align-items-center">
          <span><i class="bi bi-file-earmark-text me-1"></i>Audit-Trail</span>
          <a class="btn btn-outline-secondary btn-sm" href="auditlog.php">Audit-Log öffnen</a>
        </div>
        <div class="card-body">
          <div class="ops-kpi-row">
            <div><span>Events 24h</span><strong><?= (int)$audit['count24'] ?></strong></div>
            <div><span>Fehler 24h</span><strong class="<?= $audit['errors24'] ? 'text-danger' : '' ?>"><?= (int)$audit['errors24'] ?></strong></div>
            <div><span>Datenbank</span><strong><?= $audit['ok'] ? 'OK' : 'Fehler' ?></strong></div>
          </div>
          <div class="small text-body-secondary mt-3">Letzter Audit-Eintrag: <code><?= ops_h($audit['last'] !== '' ? $audit['last'] : '—') ?></code></div>
        </div>
      </section>
    </div>
  </div>
</div>
<?php require MMBB_UI . '/includes/js.php'; ?>
</body>
</html>
