<?php
declare(strict_types=1);
require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';
if (!mmbb_has_service('ConfigManager')) { http_response_code(403); echo 'Forbidden'; exit; }

$servers = [];
$pageError = '';
try {
    $servers = cm_load_config_manager_servers(__DIR__.'/../config/config.php');
} catch (Throwable $e) {
    $pageError = $e->getMessage();
}
$groups = [];
foreach ($servers as $s) foreach ((array)($s['groups'] ?? []) as $g) $groups[(string)$g] = true;
?>
<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Managed Hosts</title>
<?php require MMBB_UI.'/includes/css.php'; ?>
<style>
.mh-kpis{display:grid;grid-template-columns:repeat(4,minmax(140px,1fr));gap:.8rem}.mh-kpi{border:1px solid var(--bs-border-color);border-radius:.6rem;background:var(--bs-body-bg);padding:.85rem 1rem}.mh-kpi small{display:block;color:var(--bs-secondary-color);text-transform:uppercase;font-size:.7rem;font-weight:700}.mh-kpi strong{font-size:1.45rem}.mh-host{border:1px solid var(--bs-border-color);border-radius:.65rem;background:var(--bs-body-bg);padding:1rem}.mh-host-grid{display:grid;grid-template-columns:minmax(180px,1.1fr) minmax(180px,1fr) minmax(180px,1fr) auto;gap:1rem;align-items:center}.mh-url{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.78rem;color:var(--bs-secondary-color);overflow-wrap:anywhere}.mh-tags{display:flex;gap:.3rem;flex-wrap:wrap}.mh-actions{display:flex;gap:.4rem;flex-wrap:wrap;justify-content:flex-end}.mh-flow{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.75rem}.mh-step{border:1px solid var(--bs-border-color);border-radius:.6rem;padding:.8rem;background:var(--bs-tertiary-bg)}.mh-step-num{width:1.7rem;height:1.7rem;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;background:var(--bs-primary);color:#fff;font-weight:700;font-size:.8rem;margin-right:.35rem}@media(max-width:1000px){.mh-kpis,.mh-flow{grid-template-columns:repeat(2,1fr)}.mh-host-grid{grid-template-columns:1fr}.mh-actions{justify-content:flex-start}}@media(max-width:560px){.mh-kpis,.mh-flow{grid-template-columns:1fr}}
</style></head><body>
<?php require MMBB_UI.'/navigation.php'; require MMBB_UI.'/sidebar.php'; ?>
<div class="container mmbb-main py-3 mmbb-page"><?php require MMBB_UI.'/module_header.php'; ?>
<?php require __DIR__.'/../standalone/layout/managed_hosts_tabs.php'; ?>
<?php if($pageError!==''): ?><div class="alert alert-danger"><?=htmlspecialchars($pageError,ENT_QUOTES,'UTF-8')?></div><?php endif; ?>
<div class="mh-kpis mb-3">
 <div class="mh-kpi"><small>Registrierte Hosts</small><strong><?=count($servers)?></strong></div>
 <div class="mh-kpi"><small>Aktive Hosts</small><strong><?=count(array_filter($servers,fn($s)=>!isset($s['enabled'])||$s['enabled']!==false))?></strong></div>
 <div class="mh-kpi"><small>Gruppen</small><strong><?=count($groups)?></strong></div>
 <div class="mh-kpi"><small>Baseline</small><strong>Agent + Monit + Alloy</strong></div>
</div>
<div class="card mb-3"><div class="card-header fw-semibold">Host-Lifecycle</div><div class="card-body"><div class="mh-flow">
 <div class="mh-step"><span class="mh-step-num">1</span><strong>Enrollment</strong><div class="small text-body-secondary mt-2">Agent installieren und Host sicher registrieren.</div></div>
 <div class="mh-step"><span class="mh-step-num">2</span><strong>Baseline</strong><div class="small text-body-secondary mt-2">Config Agent, Monit und Grafana Alloy bereitstellen.</div></div>
 <div class="mh-step"><span class="mh-step-num">3</span><strong>Konfiguration</strong><div class="small text-body-secondary mt-2">Git-/Managed-Configs, Packages und Rollen anwenden.</div></div>
 <div class="mh-step"><span class="mh-step-num">4</span><strong>Server Health</strong><div class="small text-body-secondary mt-2">Zustand zentral überwachen; Monit bleibt lokal hinter dem Agent.</div></div>
</div></div></div>
<div class="d-flex justify-content-between align-items-center mb-2"><h5 class="mb-0">Registrierte Hosts</h5><a class="btn btn-primary btn-sm" href="agent_enrollment.php"><i class="bi bi-plus-lg me-1"></i>Host aufnehmen</a></div>
<div class="d-grid gap-2">
<?php if(!$servers): ?><div class="alert alert-secondary">Noch keine Hosts registriert.</div><?php endif; ?>
<?php foreach($servers as $s): $name=(string)($s['name']??''); $url=(string)($s['url']??''); $enabled=!isset($s['enabled'])||$s['enabled']!==false; ?>
<section class="mh-host"><div class="mh-host-grid">
 <div><div class="fw-bold"><i class="bi bi-server me-2"></i><?=htmlspecialchars($name,ENT_QUOTES,'UTF-8')?> <span class="badge <?=$enabled?'text-bg-success':'text-bg-secondary'?> ms-1"><?=$enabled?'aktiv':'inaktiv'?></span></div><div class="mh-url mt-1"><?=htmlspecialchars($url,ENT_QUOTES,'UTF-8')?></div></div>
 <div><div class="small fw-semibold mb-1">Gruppen</div><div class="mh-tags"><?php foreach((array)($s['groups']??[]) as $g): ?><span class="badge text-bg-light border"><?=htmlspecialchars((string)$g,ENT_QUOTES,'UTF-8')?></span><?php endforeach; ?><?php if(empty($s['groups'])): ?><span class="small text-body-secondary">Keine</span><?php endif; ?></div></div>
 <div><div class="small fw-semibold mb-1">Managementpfad</div><div class="small text-body-secondary">Config Manager → Config Agent → lokaler Dienst</div></div>
 <div class="mh-actions"><a class="btn btn-outline-primary btn-sm" href="client_baseline.php?server=<?=rawurlencode($name)?>"><i class="bi bi-layers me-1"></i>Baseline</a><a class="btn btn-outline-secondary btn-sm" href="server_management.php"><i class="bi bi-gear me-1"></i>Registry</a><a class="btn btn-outline-success btn-sm" href="monit_status.php"><i class="bi bi-activity me-1"></i>Health</a></div>
</div></section>
<?php endforeach; ?>
</div>
</div><?php require MMBB_UI.'/includes/js.php'; ?></body></html>
