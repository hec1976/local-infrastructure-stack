<?php
declare(strict_types=1);

// Config Manager Portal 3.9.0 - serverweite Git-Deploy-Uebersicht
require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

if (!headers_sent()) {
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('Pragma: no-cache');
    header('Expires: 0');
}

$configFile = __DIR__ . '/../config/config.php';
try {
    $portalConfig = require $configFile;
    if (!is_array($portalConfig)) {
        throw new RuntimeException('config.php liefert keine gueltige Konfiguration.');
    }
} catch (Throwable $e) {
    http_response_code(500);
    exit('Config-Manager-Konfiguration konnte nicht geladen werden.');
}

$requiredService = trim((string)($portalConfig['git_deploy']['required_service'] ?? ''));
$requiredService = $requiredService !== '' ? $requiredService : 'ConfigManager';
if (function_exists('mmbb_has_service') && !mmbb_has_service($requiredService)) {
    http_response_code(403);
    exit('Keine Berechtigung fuer Git Deploy.');
}

$selfUrl = (string)($_SERVER['SCRIPT_NAME'] ?? 'git_deploy_overview.php');
if ($selfUrl === '' || str_contains($selfUrl, "\0")) {
    $selfUrl = 'git_deploy_overview.php';
}
?>
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Git Deploy Übersicht</title>
    <?php require MMBB_UI . '/includes/css.php'; ?>
    <link rel="stylesheet" href="assets/css/git_deploy_overview.css">
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3 git-deploy-overview-page">
    <?php require MMBB_UI . '/module_header.php'; ?>

    <noscript><div class="alert alert-danger">Diese Übersicht benötigt JavaScript.</div></noscript>
    <div id="gdoMessage" class="alert d-none" role="alert"></div>

    <section class="card shadow-sm mb-3">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-server me-1"></i> Serverweite Profilprüfung</span>
            <a class="btn btn-outline-secondary btn-sm" href="git_deploy.php">
                <i class="bi bi-git me-1"></i> Git Deploy öffnen
            </a>
        </div>
        <div class="card-body">
            <div class="row g-3 align-items-end">
                <div class="col-12 col-lg-5">
                    <label for="gdoServer" class="form-label fw-semibold">Server</label>
                    <select id="gdoServer" class="form-select form-select-sm" disabled>
                        <option value="">Server werden geladen …</option>
                    </select>
                </div>
                <div class="col-12 col-md-6 col-lg-3">
                    <label for="gdoFilter" class="form-label fw-semibold">Ansicht</label>
                    <select id="gdoFilter" class="form-select form-select-sm" disabled>
                        <option value="all">Alle Profile</option>
                        <option value="current">Aktuell</option>
                        <option value="update">Update verfügbar</option>
                        <option value="not_installed">Nicht installiert</option>
                        <option value="token_required">Token erforderlich</option>
                        <option value="error">Fehler</option>
                        <option value="disabled">Deaktiviert</option>
                    </select>
                </div>
                <div class="col-12 col-md-6 col-lg-4 d-flex flex-wrap gap-2">
                    <button type="button" class="btn btn-primary btn-sm" id="gdoCheck" disabled>
                        <i class="bi bi-arrow-repeat me-1"></i> Alle Profile prüfen
                    </button>
                    <button type="button" class="btn btn-outline-secondary btn-sm" id="gdoReload">
                        <i class="bi bi-arrow-clockwise me-1"></i> Server neu laden
                    </button>
                </div>
            </div>
            <div class="small text-body-secondary mt-3" id="gdoMeta">
                Installierter Commit und Repository-Commit werden read-only verglichen.
            </div>
        </div>
    </section>

    <section class="gdo-summary-grid mb-3" aria-label="Zusammenfassung">
        <div class="gdo-summary"><span>Profile</span><strong id="gdoTotal">—</strong></div>
        <div class="gdo-summary is-current"><span>Aktuell</span><strong id="gdoCurrent">—</strong></div>
        <div class="gdo-summary is-update"><span>Updates</span><strong id="gdoUpdate">—</strong></div>
        <div class="gdo-summary is-missing"><span>Nicht installiert</span><strong id="gdoMissing">—</strong></div>
        <div class="gdo-summary"><span>Token erforderlich</span><strong id="gdoTokenRequired">—</strong></div>
        <div class="gdo-summary is-error"><span>Fehler</span><strong id="gdoErrors">—</strong></div>
        <div class="gdo-summary is-disabled"><span>Deaktiviert</span><strong id="gdoDisabled">—</strong></div>
    </section>

    <section class="card shadow-sm">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-card-checklist me-1"></i> Deployment-Profile</span>
            <span id="gdoProgress" class="small text-body-secondary" aria-live="polite">Noch nicht geprüft</span>
        </div>
        <div class="card-body p-0">
            <div id="gdoEmpty" class="text-center text-body-secondary p-5">
                <i class="bi bi-boxes display-6 d-block mb-2"></i>
                Server auswählen und alle Profile prüfen.
            </div>
            <div id="gdoTableWrap" class="table-responsive d-none">
                <table class="table table-sm align-middle mb-0 gdo-table">
                    <thead>
                    <tr>
                        <th>Profil</th>
                        <th>Service</th>
                        <th>Installiert</th>
                        <th>Repository</th>
                        <th>Stand</th>
                        <th>Letzter Deploy</th>
                    </tr>
                    </thead>
                    <tbody id="gdoBody"></tbody>
                </table>
            </div>
        </div>
    </section>
</div>

<script>
window.GIT_DEPLOY_OVERVIEW_PAGE = <?= json_encode([
    'endpoint' => 'git_deploy.php',
    'selfUrl' => $selfUrl,
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;
</script>
<script src="assets/js/git_deploy_overview.js?v=3.24.0"></script>
<?php require MMBB_UI . '/includes/js.php'; ?>
</body>
</html>
