<?php
declare(strict_types=1);

require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../standalone/audit.php';

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

if (!headers_sent()) {
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: no-store');
}

if (!mmbb_audit_load_env()) {
    http_response_code(500);
    die('Log-DB nicht verfuegbar. MMBB_ENV_PHP oder LOG_DB_DSN prüfen.');
}

try {
    ensure_log_schema();
} catch (Throwable $e) {
    http_response_code(500);
    die('Log-DB Schema Fehler: ' . htmlspecialchars($e->getMessage(), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'));
}

/* ===========================================================================
   Helpers
   =========================================================================== */

function h(mixed $s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function validate_date(string $s): string
{
    if ($s === '') {
        return '';
    }
    $dt = DateTime::createFromFormat('Y-m-d', $s);
    return ($dt && $dt->format('Y-m-d') === $s) ? $s : '';
}

function audit_action_badge(string $action, string $result): string
{
    if (in_array(strtolower($result), ['error', 'failed', 'failure'], true)) {
        return 'text-bg-danger';
    }

    $danger  = ['delete', 'drop', 'purge', 'remove', 'destroy'];
    $warning = ['update', 'save', 'write', 'set', 'change', 'import', 'sync'];
    $success = ['create', 'add', 'enable', 'register', 'insert', 'login_success', 'login_fallback'];

    $a = strtolower($action);
    foreach ($danger as $k) {
        if (str_contains($a, $k)) {
            return 'text-bg-danger';
        }
    }
    foreach ($warning as $k) {
        if (str_contains($a, $k)) {
            return 'text-bg-warning';
        }
    }
    foreach ($success as $k) {
        if (str_contains($a, $k)) {
            return 'text-bg-success';
        }
    }
    return 'text-bg-secondary';
}

function audit_result_badge(string $result): string
{
    return match (strtolower($result)) {
        'error', 'failed', 'failure' => 'text-bg-danger',
        'warn', 'warning'  => 'text-bg-warning',
        default => 'text-bg-success',
    };
}

function pretty_json(mixed $raw): string
{
    if (!is_string($raw) || trim($raw) === '') {
        return '';
    }

    $decoded = json_decode($raw, true);
    if (json_last_error() !== JSON_ERROR_NONE) {
        return $raw;
    }

    return json_encode($decoded, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT) ?: $raw;
}

/* ===========================================================================
   Kontext
   =========================================================================== */

$currentUser = mmbb_audit_current_user();
$moduleKey   = mmbb_audit_module_key();
$isAdmin     = function_exists('mmbb_has_service') && mmbb_has_service('AdminPortal');

/* ===========================================================================
   Filter
   =========================================================================== */

$filterUser     = trim((string)($_GET['user'] ?? ''));
$filterAction   = trim((string)($_GET['action'] ?? ''));
$filterIdentity = trim((string)($_GET['identity'] ?? ''));
$filterFrom     = validate_date(trim((string)($_GET['from'] ?? '')));
$filterTo       = validate_date(trim((string)($_GET['to'] ?? '')));
$limit          = min(50000, max(25, (int)($_GET['limit'] ?? 100)));

if ($filterFrom !== '' && $filterTo !== '' && $filterTo < $filterFrom) {
    [$filterFrom, $filterTo] = [$filterTo, $filterFrom];
}

/* ===========================================================================
   Einträge laden
   =========================================================================== */

$entries    = [];
$totalShown = 0;
$queryError = '';

try {
    $where  = ['module = ?'];
    $params = [$moduleKey];

    if ($filterUser !== '') {
        $where[]  = 'user LIKE ?';
        $params[] = '%' . $filterUser . '%';
    }
    if ($filterAction !== '') {
        $where[]  = 'action LIKE ?';
        $params[] = '%' . $filterAction . '%';
    }
    if ($filterIdentity !== '') {
        $where[]  = 'identity LIKE ?';
        $params[] = '%' . $filterIdentity . '%';
    }
    if ($filterFrom !== '') {
        $where[]  = 'substr(ts, 1, 10) >= ?';
        $params[] = $filterFrom;
    }
    if ($filterTo !== '') {
        $where[]  = 'substr(ts, 1, 10) <= ?';
        $params[] = $filterTo;
    }

    $sql = 'SELECT * FROM audit_log WHERE ' . implode(' AND ', $where) . ' ORDER BY id DESC LIMIT ?';
    $params[] = $limit;

    $st = log_db()->prepare($sql);
    $st->execute($params);
    $entries    = $st->fetchAll() ?: [];
    $totalShown = count($entries);
} catch (Throwable $e) {
    $queryError = $e->getMessage();
}

/* ===========================================================================
   Statistiken
   =========================================================================== */

$stats = [];
try {
    $pdo = log_db();
    $st = $pdo->prepare('SELECT COUNT(*) FROM audit_log WHERE module = ?');
    $st->execute([$moduleKey]);
    $stats['total'] = (int)$st->fetchColumn();

    $since24 = gmdate('Y-m-d\TH:i:s\Z', time() - 86400);
    $since7d = gmdate('Y-m-d\TH:i:s\Z', time() - 7 * 86400);

    $st = $pdo->prepare("SELECT COUNT(*) FROM audit_log WHERE module = ? AND ts >= ? AND action NOT LIKE 'login_%' AND action <> 'logout'");
    $st->execute([$moduleKey, $since24]);
    $stats['last24'] = (int)$st->fetchColumn();

    $st = $pdo->prepare("SELECT COUNT(*) FROM audit_log WHERE module = ? AND ts >= ? AND lower(result) IN ('error','failed','failure')");
    $st->execute([$moduleKey, $since24]);
    $stats['errors24'] = (int)$st->fetchColumn();

    $st = $pdo->prepare("SELECT action, COUNT(*) AS c FROM audit_log WHERE module = ? AND ts >= ? AND action NOT LIKE 'login_%' AND action <> 'logout' GROUP BY action ORDER BY c DESC, action ASC LIMIT 1");
    $st->execute([$moduleKey, $since7d]);
    $topAction = $st->fetch() ?: [];
    $stats['top_action'] = (string)($topAction['action'] ?? '');
    $stats['top_action_count'] = (int)($topAction['c'] ?? 0);

    $st = $pdo->prepare('SELECT identity, COUNT(*) AS c FROM audit_log WHERE module = ? AND ts >= ? AND identity <> ? GROUP BY identity ORDER BY c DESC, identity ASC LIMIT 1');
    $st->execute([$moduleKey, $since7d, '']);
    $topIdentity = $st->fetch() ?: [];
    $stats['top_identity'] = (string)($topIdentity['identity'] ?? '');
    $stats['top_identity_count'] = (int)($topIdentity['c'] ?? 0);
} catch (Throwable $e) {
    $stats = [];
}

?>
<!DOCTYPE html>
<html lang="de" data-bs-theme="auto">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Config Manager Audit Log</title>
    <?php require MMBB_UI . '/includes/css.php'; ?>
    <link rel="stylesheet" href="assets/css/auditlog.css?v=3.0.14">
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3 audit-log-page">
    <?php require MMBB_UI . '/module_header.php'; ?>

    <section class="card shadow-sm mb-3 audit-log-overview-card">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-clock-history me-1"></i> Audit-Log</span>
            <span class="small text-body-secondary">Angezeigt: <strong><?= $totalShown ?></strong><?php if ($totalShown >= $limit): ?> <span class="badge text-bg-warning ms-1">Limit <?= $limit ?></span><?php endif; ?></span>
        </div>
        <div class="card-body">
            <div class="audit-log-summary-grid mmbb-stat-grid">
                <div>
                    <span>Modul</span>
                    <strong><code><?= h($moduleKey) ?></code></strong>
                </div>
                <div>
                    <span>Quelle</span>
                    <strong><code>audit_log</code></strong>
                </div>
                <div>
                    <span>Gesamteinträge</span>
                    <strong><?= $stats ? number_format($stats['total']) : '–' ?></strong>
                </div>
                <div>
                    <span>Mutationen / 24h</span>
                    <strong><?= $stats ? number_format((int)($stats['last24'] ?? 0)) : '–' ?></strong>
                </div>
                <div>
                    <span>Fehler / 24h</span>
                    <strong class="<?= !empty($stats['errors24']) ? 'text-danger' : '' ?>"><?= $stats ? number_format((int)($stats['errors24'] ?? 0)) : '–' ?></strong>
                </div>
                <div>
                    <span>Top Aktion / 7 Tage</span>
                    <strong><?= h(($stats['top_action'] ?? '') !== '' ? $stats['top_action'] . ' (' . $stats['top_action_count'] . ')' : '–') ?></strong>
                </div>
                <div>
                    <span>Top Ziel / 7 Tage</span>
                    <strong title="<?= h($stats['top_identity'] ?? '') ?>"><?= h(($stats['top_identity'] ?? '') !== '' ? $stats['top_identity'] . ' (' . $stats['top_identity_count'] . ')' : '–') ?></strong>
                </div>
                <div>
                    <span>Aktueller Benutzer</span>
                    <strong><?= h($currentUser !== '' ? $currentUser : '–') ?></strong>
                </div>
            </div>
        </div>
    </section>

    <?php if ($queryError !== ''): ?>
        <div class="alert alert-danger py-2"><?= h($queryError) ?></div>
    <?php endif; ?>

    <section class="card shadow-sm mb-3 mmbb-audit-filter-card">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-funnel me-1"></i> Filter</span>
            <a class="btn btn-outline-secondary btn-sm" href="auditlog.php"><i class="bi bi-arrow-counterclockwise me-1"></i> Zurücksetzen</a>
        </div>
        <div class="card-body">
            <form method="get" class="mmbb-audit-filter-grid">
                <div class="mmbb-audit-filter-field">
                    <label class="form-label small fw-semibold">Von</label>
                    <input type="date" class="form-control form-control-sm" name="from" value="<?= h($filterFrom) ?>">
                </div>
                <div class="mmbb-audit-filter-field">
                    <label class="form-label small fw-semibold">Bis</label>
                    <input type="date" class="form-control form-control-sm" name="to" value="<?= h($filterTo) ?>">
                </div>
                <div class="mmbb-audit-filter-field">
                    <label class="form-label small fw-semibold">User</label>
                    <input type="text" class="form-control form-control-sm" name="user" value="<?= h($filterUser) ?>" autocomplete="off" placeholder="z.B. admin">
                </div>
                <div class="mmbb-audit-filter-field">
                    <label class="form-label small fw-semibold">Action</label>
                    <input type="text" class="form-control form-control-sm" name="action" value="<?= h($filterAction) ?>" autocomplete="off" placeholder="z.B. update">
                </div>
                <div class="mmbb-audit-filter-field">
                    <label class="form-label small fw-semibold">Identity</label>
                    <input type="text" class="form-control form-control-sm" name="identity" value="<?= h($filterIdentity) ?>" autocomplete="off" placeholder="DN / Ziel">
                </div>
                <div class="mmbb-audit-filter-field">
                    <label class="form-label small fw-semibold">Limit</label>
                    <select name="limit" class="form-select form-select-sm">
                        <?php foreach ([25, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 50000] as $l): ?>
                            <option value="<?= $l ?>" <?= $limit === $l ? 'selected' : '' ?>><?= $l ?></option>
                        <?php endforeach; ?>
                    </select>
                </div>
                <div class="mmbb-audit-filter-actions">
                    <button type="submit" class="btn btn-secondary btn-sm mmbb-btn mmbb-btn-secondary mmbb-action-search">
                        <i class="bi bi-funnel"></i> Filtern
                    </button>
                </div>
            </form>
        </div>
    </section>

    <section class="card shadow-sm audit-log-table-card">
        <div class="card-header mmbb-card-header d-flex flex-wrap align-items-center justify-content-between gap-2">
            <span><i class="bi bi-list-ul me-1"></i> Audit-Einträge</span>
            <span class="small text-body-secondary"><?= $totalShown ?> Treffer geladen</span>
        </div>
        <div class="card-body p-0">
            <div class="table-responsive">
                <table id="auditTable" class="table table-sm table-hover align-middle mb-0 mmbb-audit-table-standard">
            <thead class="table-light">
                <tr>
                    <th style="white-space:nowrap">Zeit</th>
                    <th>Modul</th>
                    <th>User</th>
                    <th>Funktion</th>
                    <th>Action</th>
                    <th>Identity / Ziel</th>
                    <th>Result</th>
                    <th>IP</th>
                    <th>URI</th>
                    <th>Data</th>
                </tr>
            </thead>
            <tbody>
            <?php if (!$entries): ?>
                <tr><td colspan="10" class="text-muted text-center py-4">Keine Einträge gefunden.</td></tr>
            <?php endif; ?>
            <?php foreach ($entries as $e):
                $ts       = str_replace('T', ' ', substr((string)($e['ts'] ?? ''), 0, 19));
                $module   = (string)($e['module']   ?? '');
                $user     = (string)($e['user']     ?? '');
                $function = (string)($e['function'] ?? '');
                $action   = (string)($e['action']   ?? '');
                $identity = (string)($e['identity'] ?? '');
                $result   = (string)($e['result']   ?? 'ok');
                $ip       = (string)($e['ip']       ?? '');
                $uri      = (string)($e['uri']      ?? '');
                $dataRaw  = (string)($e['data_json'] ?? '');
                if (trim($dataRaw) === '') { $dataRaw = (string)($e['payload'] ?? ''); }
                $dataFmt  = pretty_json($dataRaw);
                $dataShort = $dataFmt !== '' ? substr(str_replace(["\r", "\n", "\t"], ' ', $dataFmt), 0, 70) . '...' : '';
            ?>
                <tr>
                    <td class="mono small" style="white-space:nowrap"><?= h($ts) ?></td>
                    <td><code class="small"><?= h($module) ?></code></td>
                    <td class="small"><?= h($user) ?></td>
                    <td class="small"><?= h($function) ?></td>
                    <td>
                        <span class="badge <?= h(audit_action_badge($action, $result)) ?>"><?= h($action) ?></span>
                    </td>
                    <td class="identity-cell mono small" title="<?= h($identity) ?>"><?= h($identity) ?></td>
                    <td>
                        <span class="badge <?= h(audit_result_badge($result)) ?>"><?= h($result) ?></span>
                    </td>
                    <td class="mono small"><?= h($ip) ?></td>
                    <td class="uri-cell mono small" title="<?= h($uri) ?>"><?= h($uri) ?></td>
                    <td class="mmbb-audit-data-col">
                        <?php if ($dataFmt !== ''): ?>
                            <button type="button"
                                    class="btn btn-sm btn-outline-secondary mmbb-btn mmbb-audit-detail-btn"
                                    data-detail="<?= h($dataFmt) ?>"
                                    onclick="showDetail(this)"
                                    title="Data Details anzeigen">
                                <i class="bi bi-braces"></i> Details
                            </button>
                        <?php else: ?>
                            <span class="text-muted small">-</span>
                        <?php endif; ?>
                    </td>
                </tr>
            <?php endforeach; ?>
            </tbody>
                </table>
            </div>
        </div>
    </section>
</div>

<div class="modal fade audit-log-detail-modal" id="detailModal" tabindex="-1" aria-hidden="true">
    <div class="modal-dialog modal-lg modal-dialog-scrollable">
        <div class="modal-content">
            <div class="modal-header py-2">
                <h6 class="modal-title"><i class="bi bi-braces me-1"></i>Data Details</h6>
                <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
            </div>
            <div class="modal-body">
                <pre id="detailContent" class="audit-modal-pre rounded p-3"></pre>
            </div>
        </div>
    </div>
</div>

<?php require MMBB_UI . '/includes/js.php'; ?>
<script>
document.addEventListener('DOMContentLoaded', function () {
    if (window.jQuery && jQuery.fn && jQuery.fn.DataTable) {
        jQuery('#auditTable').DataTable({
            paging: true,
            pagingType: 'first_last_numbers',
            searching: true,
            order: [[0, 'desc']],
            pageLength: 25,
            lengthMenu: [[10, 25, 50, 100, 200, 500, 1000, 5000, 10000, 50000], [10, 25, 50, 100, 200, 500, 1000, 5000, 10000, 50000]],
            columnDefs: [{ orderable: false, targets: [-1] }]
        });
    }
});

function showDetail(el) {
    document.getElementById('detailContent').textContent = el.getAttribute('data-detail') || '';
    new bootstrap.Modal(document.getElementById('detailModal')).show();
}
</script>
</body>
</html>
