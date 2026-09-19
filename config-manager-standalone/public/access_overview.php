<?php
declare(strict_types=1);
require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';
if (!mmbb_has_service('ConfigManager')) { http_response_code(403); echo 'Forbidden'; exit; }

function ao_h(mixed $v): string { return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function ao_file(string $path, string $purpose, string $management, string $scope, string $type, string $why, bool $sensitive=true): array {
    $exists = is_file($path);
    $perms = $exists ? substr(sprintf('%o', fileperms($path)), -4) : '—';
    $owner = '—';
    if ($exists && function_exists('posix_getpwuid')) { $pw=@posix_getpwuid((int)fileowner($path)); $owner=is_array($pw)?(string)($pw['name']??'—'):'—'; }
    return compact('path','purpose','management','scope','type','why','sensitive','exists','perms','owner');
}
function ao_virtual(string $path,string $purpose,string $management,string $scope,string $type,string $why,bool $exists=true): array {
    return ['path'=>$path,'purpose'=>$purpose,'management'=>$management,'scope'=>$scope,'type'=>$type,'why'=>$why,'sensitive'=>true,'exists'=>$exists,'perms'=>'—','owner'=>'—'];
}

$rows=[];
$usersPath = function_exists('standalone_users_path') ? standalone_users_path() : (__DIR__.'/../standalone/data/users.json');
$rows[] = ao_file($usersPath, 'Config-Manager Web-Login', 'Passwort ändern', 'Management-Server', 'Passwort-Hash', 'Authentisiert Administratoren am Config Manager. Klartext wird nicht gespeichert.');
$rows[] = ao_file('/opt/service/env/config-manager-admin.env', 'Initial-/Setup-Zugang Config Manager', 'Setup / danach Web-GUI', 'Management-Server', 'Bootstrap-Credential', 'Nur für Greenfield/Erstinstallation. Nach Passwortänderung kann der gespeicherte Klartext veraltet sein.');
$rows[] = ao_file('/opt/service/env/forgejo-admin.env', 'Forgejo Administrator', 'Forgejo / Setup', 'Management-Server', 'Benutzer/Passwort', 'Administrativer Zugriff auf Forgejo.');
$rows[] = ao_file('/opt/service/env/forgejo-api.token', 'Forgejo Service-Zugriff', 'Forgejo Token-Rotation', 'Management-Server', 'API Token', 'Machine-to-Machine Zugriff für Repository-/Deploy-Funktionen.');
$rows[] = ao_file('/opt/service/env/grafana.env', 'Grafana Administrator', 'Grafana', 'Management-Server', 'Benutzer/Passwort', 'Administrativer Zugriff auf Grafana.');
$rows[] = ao_file('/opt/service/env/loki-export.token', 'Loki Audit-/Exportzugriff', 'Token-Rotation', 'Management-Server', 'API Token', 'Authentisiert definierte Log-/Audit-Exportpfade.');
$rows[] = ao_file('/opt/service/env/config-agent.env', 'Lokaler Config-Agent API-Zugriff', 'Managed Hosts / Enrollment', 'lokaler Management-Host', 'API Token', 'Authentisiert den Config Manager gegenüber dem lokalen Config Agent.');
$rows[] = ao_file('/etc/apache2/ssl/config-manager.key', 'HTTPS Private Key', 'Zertifikatsverwaltung', 'Management-Server', 'TLS Private Key', 'Schützt HTTPS für den Management-Zugang.');
$rows[] = ao_file('/etc/apache2/ssl/config-manager.crt', 'HTTPS Zertifikat', 'Zertifikatsverwaltung', 'Management-Server', 'TLS Zertifikat', 'Serveridentität für HTTPS.');

try {
    $servers = cm_load_config_manager_servers(__DIR__.'/../config/config.php');
    foreach ($servers as $srv) {
        $name=(string)($srv['name']??'Host'); $tf=trim((string)($srv['token_file']??''));
        if ($tf!=='') $rows[] = ao_file($tf, 'Config-Agent Token: '.$name, 'Managed Hosts / Enrollment', $name, 'API Token', 'Host-spezifische Authentisierung Config Manager → Config Agent.');
        else $rows[] = ao_virtual('global/fallback', 'Config-Agent Token: '.$name, 'Managed Hosts / Enrollment', $name, 'API Token', 'Dieser Host verwendet derzeit den globalen Manager-Token bzw. keinen host-spezifischen Token.', !empty($srv['token']));
    }
} catch (Throwable $e) { /* inventory remains usable */ }

$total=count($rows); $present=count(array_filter($rows,fn($r)=>$r['exists'])); $missing=$total-$present;
?>
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Zugänge & Secrets</title>
<?php require MMBB_UI.'/includes/css.php'; ?>
<style>
.ao-kpis{display:grid;grid-template-columns:repeat(3,minmax(150px,1fr));gap:.8rem}.ao-kpi{border:1px solid var(--bs-border-color);border-radius:.65rem;background:var(--bs-body-bg);padding:.85rem 1rem}.ao-kpi small{display:block;color:var(--bs-secondary-color);text-transform:uppercase;font-weight:700;font-size:.7rem}.ao-kpi strong{font-size:1.45rem}.ao-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:.8rem}.ao-card{border:1px solid var(--bs-border-color);border-radius:.65rem;background:var(--bs-body-bg);padding:1rem}.ao-path{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.78rem;overflow-wrap:anywhere}.ao-meta{display:grid;grid-template-columns:120px 1fr;gap:.35rem .8rem;font-size:.88rem}.ao-ok{color:var(--bs-success)}.ao-miss{color:var(--bs-secondary-color)}@media(max-width:1000px){.ao-grid{grid-template-columns:1fr}}@media(max-width:600px){.ao-kpis{grid-template-columns:1fr}.ao-meta{grid-template-columns:1fr}}
</style></head><body>
<?php require MMBB_UI.'/navigation.php'; require MMBB_UI.'/sidebar.php'; ?>
<div class="container mmbb-main py-3 mmbb-page">
<?php $moduleHeaderTitle='Zugänge & Secrets';$moduleHeaderSubtitle='Inventar: welcher Zugang existiert, wofür er verwendet wird, wo er liegt und wie er verwaltet wird. Secrets werden nicht im Klartext angezeigt.';$moduleHeaderIcon='bi bi-key-fill';require MMBB_UI.'/module_header.php'; ?>
<div class="alert alert-info"><strong>Prinzip:</strong> Diese Seite ist ein Inventar, kein Passwort-Safe. Klartext-Secrets werden hier bewusst nicht angezeigt und gehören niemals nach Git. Für eine kontrollierte lokale Einmalausgabe bleibt <code>sudo bin/teko-access-summary.sh --show-secrets</code> vorgesehen.</div>
<div class="ao-kpis mb-3"><div class="ao-kpi"><small>Inventar-Einträge</small><strong><?= $total ?></strong></div><div class="ao-kpi"><small>Vorhanden</small><strong class="ao-ok"><?= $present ?></strong></div><div class="ao-kpi"><small>Nicht gefunden / extern</small><strong><?= $missing ?></strong></div></div>
<div class="d-flex flex-wrap gap-2 mb-3"><a class="btn btn-primary btn-sm" href="password_change.php"><i class="bi bi-key me-1"></i>Config-Manager-Passwort ändern</a><a class="btn btn-outline-primary btn-sm" href="managed_hosts.php"><i class="bi bi-hdd-rack me-1"></i>Managed Hosts</a><a class="btn btn-outline-secondary btn-sm" href="auditlog.php"><i class="bi bi-file-earmark-text me-1"></i>Audit-Log</a></div>
<div class="ao-grid">
<?php foreach($rows as $r): ?>
<section class="ao-card">
 <div class="d-flex justify-content-between gap-2 align-items-start mb-2"><div><div class="fw-bold"><?=ao_h($r['purpose'])?></div><div class="small text-body-secondary"><?=ao_h($r['type'])?> · <?=ao_h($r['scope'])?></div></div><span class="badge <?=$r['exists']?'text-bg-success':'text-bg-secondary'?>"><?=$r['exists']?'vorhanden':'nicht gefunden'?></span></div>
 <div class="ao-meta"><div class="fw-semibold">Warum</div><div><?=ao_h($r['why'])?></div><div class="fw-semibold">Verwaltung</div><div><?=ao_h($r['management'])?></div><div class="fw-semibold">Speicherort</div><div class="ao-path"><?=ao_h($r['path'])?></div><div class="fw-semibold">Rechte / Owner</div><div><?=ao_h($r['perms'])?> / <?=ao_h($r['owner'])?></div><div class="fw-semibold">Git</div><div><span class="badge text-bg-danger">NEIN</span> <span class="small text-body-secondary">Secret/Key nie versionieren</span></div></div>
</section>
<?php endforeach; ?>
</div>
<div class="card mt-3"><div class="card-header fw-semibold">Wo setze oder rotiere ich welches Passwort?</div><div class="card-body"><div class="table-responsive"><table class="table table-sm align-middle mb-0"><thead><tr><th>Zugang</th><th>Setzen / Rotieren</th><th>Hinweis</th></tr></thead><tbody><tr><td>Config Manager</td><td><a href="password_change.php">Administration → Passwort ändern</a></td><td>Web-Login; nur Hash wird gespeichert.</td></tr><tr><td>Monit pro Server</td><td><a href="client_baseline.php">Managed Hosts → Baseline → Passwort setzen / rotieren</a></td><td>Secret liegt nur auf dem Zielserver unter <code>/var/lib/service/config-agent/secrets/monit-status.env</code>; danach Verbindung testen.</td></tr><tr><td>Config Agent</td><td><a href="agent_enrollment.php">Managed Hosts → Enrollment</a></td><td>Machine-to-Machine Token pro Host.</td></tr><tr><td>Alloy → Loki/Prometheus</td><td><a href="client_baseline.php">Managed Hosts → Baseline</a></td><td>Kein zusaetzliches Passwort: der host-spezifische Config-Agent-Token authentisiert auch den Observability-Ingest.</td></tr><tr><td>Forgejo / Grafana</td><td>jeweilige Anwendung bzw. Setup/Rotation</td><td>Inventar zeigt Speicherort; keine Klartextanzeige im Browser.</td></tr></tbody></table></div></div></div>
<div class="card mt-3"><div class="card-header fw-semibold">Secret-Lifecycle</div><div class="card-body"><div class="row g-3"><div class="col-md"><strong>1. Erzeugen</strong><div class="small text-body-secondary">Setup, Enrollment oder jeweilige Anwendung.</div></div><div class="col-md"><strong>2. Speichern</strong><div class="small text-body-secondary">Restriktive lokale Datei bzw. Hash; nicht Git.</div></div><div class="col-md"><strong>3. Verwenden</strong><div class="small text-body-secondary">Nur durch den vorgesehenen Dienst/Managementpfad.</div></div><div class="col-md"><strong>4. Rotieren</strong><div class="small text-body-secondary">Über zuständige Verwaltungsfunktion; Audit-Eintrag.</div></div><div class="col-md"><strong>5. Widerrufen</strong><div class="small text-body-secondary">Bei Host-Removal, Benutzerwechsel oder Verdacht.</div></div></div></div></div>
</div><?php require MMBB_UI.'/includes/js.php'; ?></body></html>
