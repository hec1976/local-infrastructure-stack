<?php
declare(strict_types=1);

require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../autoloader.php';
require_once __DIR__ . '/../Repository/ConfigManagerRepository.php';
require_once __DIR__ . '/../Service/ConfigManagerService.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

function configdiff_json(array $payload, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    header('X-Content-Type-Options: nosniff');
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

try {
    $configdiffServers = cm_load_config_manager_servers(__DIR__ . '/../config/config.php');
} catch (Throwable $e) {
    if (isset($_GET['api'])) {
        configdiff_json(['ok' => false, 'error' => $e->getMessage()], 500);
    }
    $configdiffServers = [];
}

if (isset($_GET['api'])) {
    $serverIdx = filter_input(INPUT_GET, 'server_idx', FILTER_VALIDATE_INT);
    if ($serverIdx === false || $serverIdx === null || !isset($configdiffServers[$serverIdx])) {
        configdiff_json(['ok' => false, 'error' => 'Ungültiger Server.'], 400);
    }

    try {
        $service = new ConfigManagerService(new ConfigManagerRepository($configdiffServers[$serverIdx]));
        $api = (string)$_GET['api'];

        if ($api === 'configs') {
            $items = [];
            foreach ($service->getAllConfigs() as $config) {
                if (!is_array($config)) {
                    continue;
                }
                $id = trim((string)($config['id'] ?? ''));
                if ($id === '') {
                    continue;
                }
                $items[] = [
                    'id' => $id,
                    'label' => (string)($config['name'] ?? $config['label'] ?? $id),
                    'category' => (string)($config['category'] ?? ''),
                ];
            }
            usort($items, static fn(array $a, array $b): int => strnatcasecmp($a['label'], $b['label']));
            configdiff_json(['ok' => true, 'configs' => $items]);
        }

        if ($api === 'content') {
            $configId = trim((string)($_GET['config_id'] ?? ''));
            if ($configId === '' || strlen($configId) > 250 || preg_match('/[\x00-\x1F\x7F]/', $configId)) {
                configdiff_json(['ok' => false, 'error' => 'Ungültige Config-ID.'], 400);
            }

            $allowed = false;
            foreach ($service->getAllConfigs() as $config) {
                if (is_array($config) && hash_equals((string)($config['id'] ?? ''), $configId)) {
                    $allowed = true;
                    break;
                }
            }
            if (!$allowed) {
                configdiff_json(['ok' => false, 'error' => 'Config-ID ist auf diesem Server nicht vorhanden.'], 404);
            }

            $content = $service->getConfigContent($configId);
            if (strlen($content) > 5 * 1024 * 1024) {
                configdiff_json(['ok' => false, 'error' => 'Datei ist grösser als 5 MiB.'], 413);
            }
            configdiff_json([
                'ok' => true,
                'content' => $content,
                'server_name' => (string)$configdiffServers[$serverIdx]['name'],
                'config_id' => $configId,
            ]);
        }

        configdiff_json(['ok' => false, 'error' => 'Unbekannte API-Aktion.'], 404);
    } catch (Throwable $e) {
        configdiff_json(['ok' => false, 'error' => $e->getMessage()], 502);
    }
}

$configdiffPublicServers = array_map(
    static fn(array $server, int $idx): array => ['idx' => $idx, 'name' => (string)$server['name']],
    $configdiffServers,
    array_keys($configdiffServers)
);
?>

<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Config Diff</title>
  <?php require MMBB_UI . '/includes/css.php'; ?>
  <link rel="stylesheet" href="assets/css/configdiff.css">
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3 configdiff-page">
  <?php require MMBB_UI . '/module_header.php'; ?>

  <noscript>
    <div class="alert alert-danger">Config Diff benötigt JavaScript.</div>
  </noscript>

  <div class="alert alert-info d-flex align-items-start gap-2 configdiff-privacy" role="status">
    <i class="bi bi-shield-check mt-1"></i>
    <div>
      <strong>Direkter Serververgleich:</strong> Die Dateiinhalte werden über die bestehenden Config-Agenten geladen. Der Vergleich selbst erfolgt ausschliesslich im Browser und wird nicht gespeichert.
    </div>
  </div>

  <section class="card shadow-sm mb-3">
    <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
      <span><i class="bi bi-input-cursor-text me-1"></i> Konfigurationen einfügen</span>
      <div class="d-flex flex-wrap gap-2">
        <button type="button" class="btn btn-outline-secondary btn-sm" id="configdiffSwap">
          <i class="bi bi-arrow-left-right me-1"></i> Tauschen
        </button>
        <button type="button" class="btn btn-outline-danger btn-sm" id="configdiffClear">
          <i class="bi bi-trash me-1"></i> Leeren
        </button>
      </div>
    </div>

    <div class="card-body">
      <div class="row g-3 configdiff-input-row">
        <div class="col-12 col-xl-6">
          <label class="form-label fw-semibold">Linke Quelle</label>
          <div class="row g-2 mb-2">
            <div class="col-md-5"><select class="form-select form-select-sm" id="configdiffLeftServer" aria-label="Linker Server"></select></div>
            <div class="col-md-5"><select class="form-select form-select-sm" id="configdiffLeftConfig" aria-label="Linke Konfiguration"><option value="">Datei wählen …</option></select></div>
            <div class="col-md-2 d-grid"><button type="button" class="btn btn-outline-primary btn-sm" id="configdiffLoadLeft">Laden</button></div>
          </div>
          <input type="text" class="form-control form-control-sm mb-2" id="configdiffLeftName"
                 value="Konfiguration A" maxlength="120" autocomplete="off">
          <textarea class="form-control font-monospace configdiff-source" id="configdiffLeft"
                    spellcheck="false" autocomplete="off"
                    placeholder="Erste Konfiguration hier einfügen …"></textarea>
          <div class="small text-body-secondary mt-1" id="configdiffLeftMeta">0 Zeilen · 0 Zeichen</div>
        </div>

        <div class="col-12 col-xl-6">
          <label class="form-label fw-semibold">Rechte Quelle</label>
          <div class="row g-2 mb-2">
            <div class="col-md-5"><select class="form-select form-select-sm" id="configdiffRightServer" aria-label="Rechter Server"></select></div>
            <div class="col-md-5"><select class="form-select form-select-sm" id="configdiffRightConfig" aria-label="Rechte Konfiguration"><option value="">Datei wählen …</option></select></div>
            <div class="col-md-2 d-grid"><button type="button" class="btn btn-outline-primary btn-sm" id="configdiffLoadRight">Laden</button></div>
          </div>
          <input type="text" class="form-control form-control-sm mb-2" id="configdiffRightName"
                 value="Konfiguration B" maxlength="120" autocomplete="off">
          <textarea class="form-control font-monospace configdiff-source" id="configdiffRight"
                    spellcheck="false" autocomplete="off"
                    placeholder="Zweite Konfiguration hier einfügen …"></textarea>
          <div class="small text-body-secondary mt-1" id="configdiffRightMeta">0 Zeilen · 0 Zeichen</div>
        </div>
      </div>
    </div>
  </section>

  <section class="card shadow-sm mb-3">
    <div class="card-header mmbb-card-header">
      <i class="bi bi-sliders me-1"></i> Vergleichsoptionen
    </div>
    <div class="card-body py-2">
      <div class="d-flex flex-wrap align-items-center gap-x-4 gap-y-2 configdiff-options">
        <div class="form-check form-switch">
          <input class="form-check-input" type="checkbox" role="switch" id="configdiffIgnoreWhitespace">
          <label class="form-check-label" for="configdiffIgnoreWhitespace">Leerzeichen und Einrückung ignorieren</label>
        </div>
        <div class="form-check form-switch">
          <input class="form-check-input" type="checkbox" role="switch" id="configdiffIgnoreBlankLines">
          <label class="form-check-label" for="configdiffIgnoreBlankLines">Leerzeilen ignorieren</label>
        </div>
        <div class="form-check form-switch">
          <input class="form-check-input" type="checkbox" role="switch" id="configdiffIgnoreCase">
          <label class="form-check-label" for="configdiffIgnoreCase">Gross-/Kleinschreibung ignorieren</label>
        </div>
        <div class="form-check form-switch">
          <input class="form-check-input" type="checkbox" role="switch" id="configdiffIgnoreComments">
          <label class="form-check-label" for="configdiffIgnoreComments">Reine Kommentarzeilen ignorieren</label>
        </div>
      </div>
      <div class="small text-body-secondary mt-2">
        LF und CRLF werden automatisch vereinheitlicht. Kommentarzeilen werden bei <code>#</code>, <code>;</code> und <code>//</code> erkannt.
      </div>
    </div>
  </section>

  <div class="d-flex flex-wrap align-items-center gap-2 mb-3 configdiff-toolbar">
    <button type="button" class="btn btn-primary btn-sm" id="configdiffCompare">
      <i class="bi bi-file-diff me-1"></i> Vergleichen
    </button>
    <button type="button" class="btn btn-outline-secondary btn-sm" id="configdiffPrevious" disabled>
      <i class="bi bi-chevron-up me-1"></i> Vorherige Änderung
    </button>
    <button type="button" class="btn btn-outline-secondary btn-sm" id="configdiffNext" disabled>
      <i class="bi bi-chevron-down me-1"></i> Nächste Änderung
    </button>
    <button type="button" class="btn btn-outline-secondary btn-sm" id="configdiffExport" disabled>
      <i class="bi bi-download me-1"></i> Unified Diff
    </button>
    <div class="btn-group btn-group-sm ms-xl-auto" role="group" aria-label="Ansicht">
      <input type="radio" class="btn-check" name="configdiffView" id="configdiffSideView" value="side" checked>
      <label class="btn btn-outline-secondary" for="configdiffSideView"><i class="bi bi-layout-split me-1"></i> Nebeneinander</label>
      <input type="radio" class="btn-check" name="configdiffView" id="configdiffUnifiedView" value="unified">
      <label class="btn btn-outline-secondary" for="configdiffUnifiedView"><i class="bi bi-list-ul me-1"></i> Unified</label>
    </div>
  </div>

  <div id="configdiffMessage" class="alert d-none" role="alert"></div>

  <section class="card shadow-sm configdiff-result-card">
    <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
      <span><i class="bi bi-file-diff me-1"></i> Unterschiede</span>
      <div class="d-flex flex-wrap gap-2 configdiff-summary" id="configdiffSummary" aria-live="polite">
        <span class="badge text-bg-light border">Noch kein Vergleich</span>
      </div>
    </div>
    <div class="card-body p-0">
      <div id="configdiffEmpty" class="configdiff-empty text-center text-body-secondary p-5">
        <i class="bi bi-file-diff display-6 d-block mb-2"></i>
        Zwei Konfigurationen einfügen und <strong>Vergleichen</strong> wählen.
      </div>

      <div id="configdiffBusy" class="configdiff-empty text-center p-5 d-none" role="status">
        <div class="spinner-border spinner-border-sm me-2" aria-hidden="true"></div>
        Vergleich wird berechnet …
      </div>

      <div id="configdiffSideContainer" class="configdiff-table-wrap d-none">
        <table class="table table-sm mb-0 configdiff-table" aria-label="Vergleich nebeneinander">
          <thead class="sticky-top">
            <tr>
              <th class="configdiff-line-number">#</th>
              <th id="configdiffLeftHeader">Konfiguration A</th>
              <th class="configdiff-marker"></th>
              <th class="configdiff-line-number">#</th>
              <th id="configdiffRightHeader">Konfiguration B</th>
            </tr>
          </thead>
          <tbody id="configdiffSideBody"></tbody>
        </table>
      </div>

      <div id="configdiffUnifiedContainer" class="configdiff-table-wrap d-none">
        <table class="table table-sm mb-0 configdiff-table configdiff-unified-table" aria-label="Unified Diff">
          <thead class="sticky-top">
            <tr>
              <th class="configdiff-line-number">A</th>
              <th class="configdiff-line-number">B</th>
              <th class="configdiff-marker"></th>
              <th>Inhalt</th>
            </tr>
          </thead>
          <tbody id="configdiffUnifiedBody"></tbody>
        </table>
      </div>
    </div>
  </section>

  <div class="small text-body-secondary mt-2">
    Schutzgrenzen: maximal 5 MiB und 20'000 berücksichtigte Zeilen pro Seite.
  </div>
</div>

<script>window.CONFIGDIFF_SERVERS = <?= json_encode($configdiffPublicServers, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;</script>
<?php require MMBB_UI . '/includes/js.php'; ?>
<script>window.CONFIGDIFF_ENDPOINT = <?= json_encode((string)($_SERVER['SCRIPT_NAME'] ?? 'configdiff.php'), JSON_UNESCAPED_SLASHES) ?>;</script>
<script src="assets/js/configdiff.js"></script>
</body>
</html>
