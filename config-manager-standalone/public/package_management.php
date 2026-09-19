<?php
declare(strict_types=1);
require_once __DIR__.'/../standalone/bootstrap.php';
require_once __DIR__.'/../autoloader.php';
require_once __DIR__.'/../Repository/ConfigManagerRepository.php';
require_once __DIR__.'/../Service/ConfigManagerService.php';
require_once __DIR__.'/../Controller/ConfigManagerController.php';
require_once __DIR__.'/../lib/config_manager_runtime.php';

if (!mmbb_has_service('ConfigManager')) { http_response_code(403); echo 'Forbidden'; exit; }

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;
use ConfigManager\Controller\ConfigManagerController;

if(session_status()===PHP_SESSION_NONE)session_start();
if(empty($_SESSION['csrf_token']))$_SESSION['csrf_token']=bin2hex(random_bytes(32));
$csrf=(string)$_SESSION['csrf_token'];

function pm_json(array $x,int $s=200):never{http_response_code($s);header('Content-Type: application/json');header('Cache-Control:no-store');echo json_encode($x,JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);exit;}
function pm_ctl(array $server):ConfigManagerController{return new ConfigManagerController(new ConfigManagerService(new ConfigManagerRepository($server)));}
function pm_servers():array{$f=__DIR__.'/../config/config.php';return cm_load_config_manager_servers($f);}
function pm_public(array $s,int $i):array{return ['idx'=>$i,'name'=>(string)$s['name'],'groups'=>array_values((array)($s['groups']??[])),'labels'=>(array)($s['labels']??[])];}
function pm_server_by_name(array $servers,string $name):array{foreach($servers as $s)if(strcasecmp((string)($s['name']??''),$name)===0)return $s;throw new InvalidArgumentException('Unbekannter Server.');}
function pm_body():array{$r=file_get_contents('php://input');$x=json_decode((string)$r,true);if(!is_array($x))throw new InvalidArgumentException('Ungültiges JSON.');return $x;}
function pm_validate(array $p):array{
 $a=strtolower(trim((string)($p['action']??'check')));$pkg=trim((string)($p['package']??''));$v=trim((string)($p['version']??''));
 if(!preg_match('/^(check|install|upgrade|remove)$/',$a))throw new InvalidArgumentException('Ungültige Aktion.');
 if(!preg_match('/^[A-Za-z0-9][A-Za-z0-9+_.:@-]{0,127}$/',$pkg))throw new InvalidArgumentException('Ungültiger Paketname.');
 if($v!==''&&!preg_match('/^[A-Za-z0-9][A-Za-z0-9+_.:~@-]{0,127}$/',$v))throw new InvalidArgumentException('Ungültige Version.');
 if($a==='remove'&&$v!=='')throw new InvalidArgumentException('Remove akzeptiert keine Version.');
 return [$a,$pkg,$v];
}
try{
 $servers=pm_servers();
 if(($_GET['api']??'')==='summary'){
  $groups=[];foreach($servers as $s)foreach((array)($s['groups']??[]) as $g)$groups[$g]=1;
  pm_json(['ok'=>true,'servers'=>array_map(fn($s,$i)=>pm_public($s,$i),$servers,array_keys($servers)),'groups'=>array_keys($groups)]);
 }
 if(($_GET['api']??'')==='search'){
  $name=trim((string)($_GET['server']??''));$q=trim((string)($_GET['q']??''));
  if(!preg_match('/^[A-Za-z0-9+_.:@-]{2,64}$/',$q))throw new InvalidArgumentException('Paketsuche muss mindestens 2 gültige Zeichen enthalten.');
  $srv=pm_server_by_name($servers,$name);$r=pm_ctl($srv)->searchPackages($q,100);$resp=is_array($r['response']??null)?$r['response']:[];
  if(($r['http_code']??500)<200||($r['http_code']??500)>=300||empty($resp['ok']))throw new RuntimeException((string)($resp['error']??'Paketsuche fehlgeschlagen.'),502);
  pm_json(['ok'=>true,'server_name'=>(string)$srv['name'],'search'=>$resp]);
 }
 if(($_GET['api']??'')==='preview'){
  $name=trim((string)($_GET['server']??''));$pkg=trim((string)($_GET['package']??''));
  if(!preg_match('/^[A-Za-z0-9][A-Za-z0-9+_.:@-]{0,127}$/',$pkg))throw new InvalidArgumentException('Ungültiger Paketname.');
  $srv=pm_server_by_name($servers,$name);$r=pm_ctl($srv)->getPackagePreview($pkg);$resp=is_array($r['response']??null)?$r['response']:[];
  if(($r['http_code']??500)<200||($r['http_code']??500)>=300||empty($resp['ok']))throw new RuntimeException((string)($resp['error']??'Paketvorschau fehlgeschlagen.'),502);
  pm_json(['ok'=>true,'server_name'=>(string)$srv['name'],'preview'=>$resp]);
 }
 if(($_GET['api']??'')==='installed'){
  $name=trim((string)($_GET['server']??''));$q=trim((string)($_GET['q']??''));
  if($q!==''&&!preg_match('/^[A-Za-z0-9+_.:@-]{1,128}$/',$q))throw new InvalidArgumentException('Ungültige Paketsuche.');
  $srv=pm_server_by_name($servers,$name);$r=pm_ctl($srv)->getInstalledPackages($q,2000);$resp=is_array($r['response']??null)?$r['response']:[];
  if(($r['http_code']??500)<200||($r['http_code']??500)>=300||empty($resp['ok']))throw new RuntimeException((string)($resp['error']??'Installierte Pakete konnten nicht gelesen werden.'),502);
  pm_json(['ok'=>true,'server_name'=>(string)$srv['name'],'installed'=>$resp]);
 }
 if(($_GET['api']??'')==='fleet'){
  $pkg=trim((string)($_GET['package']??''));
  if(!preg_match('/^[A-Za-z0-9][A-Za-z0-9+_.:@-]{0,127}$/',$pkg))throw new InvalidArgumentException('Ungültiger Paketname.');
  $rows=[];
  if(function_exists('session_write_close'))session_write_close();
  foreach($servers as $srv){
   try{
    $ctl=pm_ctl($srv);$ir=$ctl->getInstalledPackages($pkg,50);$iresp=is_array($ir['response']??null)?$ir['response']:[];$exact=null;
    foreach((array)($iresp['packages']??[]) as $pr){if(strcasecmp((string)($pr['name']??''),$pkg)===0){$exact=$pr;break;}}
    $ok=(($ir['http_code']??500)>=200&&($ir['http_code']??500)<300&&!empty($iresp['ok']));$available='';$repo='';$installed=is_array($exact);$version=$installed?(string)($exact['version']??''):'';
    if($installed){$available=(string)($exact['available_version']??'');$repo=(string)($exact['repository']??'');}
    else{$pr=$ctl->getPackagePreview($pkg);$presp=is_array($pr['response']??null)?$pr['response']:[];$avail=is_array($presp['available']??null)?$presp['available']:[];$available=(string)($avail[0]['version']??'');$repo=(string)($avail[0]['repository']??'');}
    $rows[]=['server_name'=>(string)($srv['name']??''),'ok'=>$ok,'os'=>$iresp['os']??[],'installed'=>$installed,'version'=>$version,'available_version'=>$available,'repository'=>$repo,'update_available'=>$installed&&!empty($exact['update_available']),'error'=>$ok?'':(string)($iresp['error']??'Abfrage fehlgeschlagen')];
   }catch(Throwable $e){$rows[]=['server_name'=>(string)($srv['name']??''),'ok'=>false,'installed'=>false,'version'=>'','available_version'=>'','repository'=>'','update_available'=>false,'error'=>$e->getMessage()];}
  }
  pm_json(['ok'=>true,'package'=>$pkg,'rows'=>$rows]);
 }
 if($_SERVER['REQUEST_METHOD']==='POST'){
  $in=pm_body();if(!hash_equals($csrf,(string)($in['csrf_token']??'')))throw new RuntimeException('CSRF fehlgeschlagen.',403);
  [$action,$package,$version]=pm_validate($in);
  $targetNames=array_values(array_unique(array_map(fn($x)=>trim((string)$x),(array)($in['server_names']??[]))));
  if(!$targetNames)throw new InvalidArgumentException('Keine Zielserver ausgewählt.');
  if(count($targetNames)>50)throw new RuntimeException('Maximal 50 Zielserver pro Paketjob.',409);
  $byName=[]; foreach($servers as $srv){$byName[strtolower((string)$srv['name'])]=$srv;}
  $confirmRemove=!empty($in['confirm_remove']);
  if($action==='remove'&&!$confirmRemove)throw new RuntimeException('Remove erfordert explizite Bestätigung.',400);
  $results=[];
  if(function_exists('session_write_close'))session_write_close();
  foreach($targetNames as $targetName){
   $key=strtolower($targetName);
   if(!isset($byName[$key])){ $results[]=['server_name'=>$targetName,'ok'=>false,'error'=>'Unbekannter oder inzwischen entfernter Server'];continue; }
   $srv=$byName[$key];
   try{
    $r=pm_ctl($srv)->packageAction($action,$package,$version,$confirmRemove);
    $resp=is_array($r['response']??null)?$r['response']:[];
    $results[]=['server_name'=>(string)$srv['name'],'ok'=>(($r['http_code']??500)>=200&&($r['http_code']??500)<300&&!empty($resp['ok'])),'http_code'=>$r['http_code']??0,'response'=>$resp];
   }catch(Throwable $e){$results[]=['server_name'=>(string)$srv['name'],'ok'=>false,'error'=>$e->getMessage()];}
  }
  $allOk=!array_filter($results,fn($r)=>empty($r['ok']));
  mmbb_audit_write('package_'.$action,$package,['version'=>$version,'targets'=>count($targetNames),'results'=>array_map(fn($r)=>['server'=>$r['server_name']??'','ok'=>$r['ok']],$results)],'package_management.php',$allOk?'ok':'error');
  pm_json(['ok'=>true,'action'=>$action,'package'=>$package,'version'=>$version,'results'=>$results]);
 }
}catch(Throwable $e){$c=(int)$e->getCode();if($c<400||$c>599)$c=400;if(isset($_GET['api'])||$_SERVER['REQUEST_METHOD']==='POST')pm_json(['ok'=>false,'error'=>$e->getMessage()],$c);$pageError=$e->getMessage();}
?>
<!DOCTYPE html><html lang="de"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Package Management</title>
<?php require MMBB_UI.'/includes/css.php'; ?>
<style>
.pm-grid{display:grid;grid-template-columns:360px minmax(0,1fr);gap:1rem}.pm-servers{max-height:310px;overflow:auto}.pm-status{font-weight:600}.pm-ok{color:var(--bs-success)}.pm-bad{color:var(--bs-danger)}.pm-tabs{display:flex;gap:1.25rem;border-bottom:1px solid var(--bs-border-color);margin-bottom:1rem}.pm-tab{border:0;background:transparent;padding:.7rem .15rem;border-bottom:2px solid transparent;color:var(--bs-secondary-color)}.pm-tab.active{border-color:#24449b;color:#24449b;font-weight:600}.pm-panel{display:none}.pm-panel.active{display:block}.pm-selection-summary{font-size:.82rem}.pm-preview-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:1rem}.pm-kv{border:1px solid var(--bs-border-color);border-radius:.5rem;padding:1rem;min-height:86px}.pm-kv strong{font-size:1.05rem;display:block;margin-top:.2rem}.pm-kv small{display:block;color:var(--bs-secondary-color);text-transform:uppercase;font-weight:600;font-size:.68rem}.pm-installed{max-height:620px;overflow:auto}.pm-preview-main{min-height:500px}.pm-preview-main .table{font-size:.95rem}.pm-preview-main .table th,.pm-preview-main .table td{padding:.72rem .75rem;vertical-align:middle}.pm-progress-wrap{border:1px solid var(--bs-border-color);border-radius:.5rem;padding:1rem;background:var(--bs-tertiary-bg)}.pm-progress-wrap.d-none{display:none!important}.pm-progress-meta{font-size:.82rem;color:var(--bs-secondary-color)}.pm-help{background:var(--bs-tertiary-bg);border-radius:.4rem;padding:.65rem;font-size:.82rem;color:var(--bs-secondary-color)}.pm-package-wrap{position:relative}.pm-suggest{position:absolute;z-index:1080;left:0;right:0;top:100%;background:var(--bs-body-bg);border:1px solid var(--bs-border-color);border-radius:.35rem;box-shadow:0 .5rem 1rem rgba(0,0,0,.12);max-height:620px;overflow:auto}.pm-suggest.d-none{display:none!important}.pm-suggest-item{display:block;width:100%;text-align:left;border:0;border-bottom:1px solid var(--bs-border-color);background:transparent;padding:.55rem .7rem}.pm-suggest-item:hover,.pm-suggest-item:focus{background:var(--bs-tertiary-bg)}.pm-suggest-meta{font-size:.78rem;color:var(--bs-secondary-color)}.pm-search-progress{border:1px solid var(--bs-border-color);border-radius:.4rem;padding:.55rem .65rem;background:var(--bs-tertiary-bg)}.pm-search-progress.d-none{display:none!important}.pm-installed-summary{display:flex;gap:1rem;align-items:center;flex-wrap:wrap;margin-bottom:.75rem}.pm-installed-summary .badge{font-size:.78rem}.pm-inventory-cards{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.75rem;margin-bottom:1rem}.pm-inventory-card{border:1px solid var(--bs-border-color);border-radius:.5rem;padding:.75rem .9rem;background:var(--bs-body-bg)}.pm-inventory-card small{display:block;color:var(--bs-secondary-color);text-transform:uppercase;font-size:.67rem;font-weight:700}.pm-inventory-card strong{display:block;font-size:1.05rem;margin-top:.15rem}.pm-update{font-weight:600;color:var(--bs-warning-text-emphasis)}.pm-fleet-state{font-weight:600}.pm-fleet-ok{color:var(--bs-success)}.pm-fleet-warn{color:var(--bs-warning-text-emphasis)}.pm-fleet-bad{color:var(--bs-danger)}
@media(max-width:1000px){.pm-grid{grid-template-columns:1fr}.pm-preview-grid,.pm-inventory-cards{grid-template-columns:1fr 1fr}}
</style></head><body>
<?php require MMBB_UI.'/navigation.php';require MMBB_UI.'/sidebar.php';?>
<div class="container mmbb-main py-3 mmbb-page"><?php require MMBB_UI.'/module_header.php';?>
<div id="msg" class="alert d-none"></div>
<div class="pm-grid">
<section class="card shadow-sm"><div class="card-header mmbb-card-header">Paketaktion</div><div class="card-body">
<label class="form-label">Paket</label><div class="pm-package-wrap mb-2"><div class="input-group"><input id="pkg" class="form-control" autocomplete="off" placeholder="z.B. perl- oder apache"><button id="previewBtn" class="btn btn-outline-primary" type="button">Vorschau</button></div><div id="pkgSuggest" class="pm-suggest d-none"></div></div>
<div id="packageSearchProgress" class="pm-search-progress d-none mb-2"><div class="d-flex justify-content-between align-items-center mb-1"><strong id="packageSearchTitle">Pakete werden gesucht …</strong><span class="spinner-border spinner-border-sm" aria-hidden="true"></span></div><div class="progress" style="height:6px"><div class="progress-bar progress-bar-striped progress-bar-animated" style="width:100%"></div></div><div id="packageSearchText" class="small text-body-secondary mt-1">Repository-Daten des Referenzservers werden durchsucht.</div></div>
<div id="packageSearchHint" class="small text-body-secondary mb-2">Ab 2 Zeichen werden bis zu 100 passende Pakete des Referenzservers vorgeschlagen.</div>
<label class="form-label">Version</label><select id="ver" class="form-select mb-2"><option value="">Automatisch / neueste verfügbare</option></select>
<label class="form-label">Aktion</label><select id="action" class="form-select mb-3"><option value="check">Nur prüfen</option><option value="install">Installieren</option><option value="upgrade">Upgrade</option><option value="remove">Entfernen</option></select>
<hr><div class="d-flex justify-content-between align-items-center mb-2"><strong>Zielsysteme</strong><span id="selectedCount" class="badge text-bg-secondary">0 ausgewählt</span></div>
<div class="pm-help mb-2">Wähle einzelne Server oder übernimm eine Gruppe. „Nur Canary“ markiert ausschliesslich Server der Gruppe <code>canary</code>; es wird dabei noch keine Paketaktion ausgeführt.</div>
<label class="form-label">Servergruppe</label><select id="group" class="form-select mb-2"><option value="">— Gruppe wählen —</option></select>
<div class="d-flex gap-2 mb-2"><button id="selectGroup" class="btn btn-outline-secondary btn-sm">Gruppe übernehmen</button><button id="selectCanary" class="btn btn-outline-warning btn-sm">Nur Canary</button><button id="clear" class="btn btn-outline-secondary btn-sm">Auswahl leeren</button></div>
<div id="selectionNames" class="pm-selection-summary text-body-secondary mb-2">Keine Server ausgewählt.</div>
<div class="pm-servers border rounded p-2" id="servers">wird geladen…</div>
<button id="run" class="btn btn-primary w-100 mt-3">Aktion ausführen</button>
<div class="small text-body-secondary mt-2">Max. 50 Zielserver pro Paketjob. Keine freien Paketmanager-Parameter oder Shell-Kommandos.</div>
</div></section>
<section class="card shadow-sm"><div class="card-header mmbb-card-header">Paketinformationen & Ergebnis</div><div class="card-body pb-0">
<div class="pm-tabs"><button class="pm-tab active" data-tab="preview">Paketvorschau</button><button class="pm-tab" data-tab="installed">Server-Inventar <span id="installedTabCount" class="badge text-bg-secondary ms-1">—</span></button><button class="pm-tab" data-tab="fleet">Fleet-Vergleich</button><button class="pm-tab" data-tab="result">Job-Ergebnis</button></div>
<div id="panel-preview" class="pm-panel active pm-preview-main"><div class="text-body-secondary py-4" id="previewBox">Paketname eingeben, einen Referenzserver auswählen und auf <strong>Vorschau</strong> klicken.</div></div>
<div id="panel-installed" class="pm-panel"><div class="pm-installed-summary"><strong>Server-Inventar</strong><span id="installedSummary" class="badge text-bg-secondary">Noch nicht geladen</span><span class="text-body-secondary small">Inventar, Versionen und verfügbare Paketupdates eines Servers.</span></div><div class="row g-2 mb-3"><div class="col-md-4"><label class="form-label">Server</label><select id="browseServer" class="form-select"></select></div><div class="col"><label class="form-label">Pakete filtern</label><input id="installedQuery" class="form-control" placeholder="z.B. apache, podman, php oder leer für alle"></div><div class="col-auto d-flex align-items-end"><button id="installedBtn" class="btn btn-primary">Inventar laden</button></div></div><div id="installedProgress" class="pm-search-progress d-none mb-3"><div class="d-flex justify-content-between align-items-center"><strong>Server-Inventar wird geladen …</strong><span class="spinner-border spinner-border-sm"></span></div><div class="progress mt-2" style="height:6px"><div class="progress-bar progress-bar-striped progress-bar-animated" style="width:100%"></div></div></div><div class="pm-inventory-cards"><div class="pm-inventory-card"><small>Server</small><strong id="invServer">—</strong></div><div class="pm-inventory-card"><small>Betriebssystem</small><strong id="invOs">—</strong></div><div class="pm-inventory-card"><small>Installierte Pakete</small><strong id="invTotal">—</strong></div><div class="pm-inventory-card"><small>Updates verfügbar</small><strong id="invUpdates">—</strong></div></div><div class="pm-installed table-responsive"><table class="table table-sm table-hover"><thead><tr><th>Paket / Modul</th><th>Installierte Version</th><th>Architektur</th><th>Update</th><th>Repository</th><th></th></tr></thead><tbody id="installedRows"><tr><td colspan="6" class="text-body-secondary">Noch nicht geladen.</td></tr></tbody></table></div></div>
<div id="panel-fleet" class="pm-panel"><div class="pm-installed-summary"><strong>Fleet-Vergleich</strong><span id="fleetSummary" class="badge text-bg-secondary">Noch nicht geladen</span><span class="text-body-secondary small">Vergleicht ein Paket über alle registrierten Server.</span></div><div class="row g-2 mb-3"><div class="col"><label class="form-label">Paket</label><input id="fleetPackage" class="form-control" placeholder="z.B. podman, apache2 oder postfix"></div><div class="col-auto d-flex align-items-end"><button id="fleetBtn" class="btn btn-primary">Fleet vergleichen</button></div></div><div id="fleetProgress" class="pm-search-progress d-none mb-3"><div class="d-flex justify-content-between align-items-center"><strong>Server werden verglichen …</strong><span class="spinner-border spinner-border-sm"></span></div><div class="progress mt-2" style="height:6px"><div class="progress-bar progress-bar-striped progress-bar-animated" style="width:100%"></div></div></div><div class="table-responsive"><table class="table table-sm table-hover"><thead><tr><th>Server</th><th>OS / Manager</th><th>Installiert</th><th>Verfügbar</th><th>Repository</th><th>Status</th></tr></thead><tbody id="fleetRows"><tr><td colspan="6" class="text-body-secondary">Noch kein Paket verglichen.</td></tr></tbody></table></div></div>
<div id="panel-result" class="pm-panel"><div id="jobProgress" class="pm-progress-wrap d-none mb-3"><div class="d-flex justify-content-between align-items-center mb-2"><strong id="jobProgressTitle">Paketjob wird vorbereitet …</strong><span id="jobProgressPct" class="badge text-bg-primary">0%</span></div><div class="progress" role="progressbar" aria-label="Paketjob Fortschritt" aria-valuemin="0" aria-valuemax="100"><div id="jobProgressBar" class="progress-bar progress-bar-striped progress-bar-animated" style="width:0%"></div></div><div id="jobProgressText" class="pm-progress-meta mt-2">Noch nicht gestartet.</div></div><div class="table-responsive"><table class="table table-hover mb-0"><thead><tr><th>Server</th><th>OS / Manager</th><th>Vorher</th><th>Nachher</th><th>Status</th></tr></thead><tbody id="results"><tr><td colspan="5" class="text-center text-body-secondary py-4">Noch keine Aktion.</td></tr></tbody></table></div></div>
</div></section></div></div>
<script>
const CSRF=<?=json_encode($csrf)?>;let DATA={servers:[],groups:[]};const esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
async function api(u,o={}){const r=await fetch(u,{cache:'no-store',...o});let j;try{j=await r.json()}catch{throw new Error(`Ungültige Antwort (HTTP ${r.status})`)}if(!r.ok||!j.ok)throw new Error(j.error||`HTTP ${r.status}`);return j}
function msg(t,k='info'){const e=document.getElementById('msg');e.textContent=t;e.className='alert alert-'+k}
function selected(){return [...document.querySelectorAll('.pm-server:checked')].map(x=>DATA.servers[Number(x.value)].name)}
function updateSelection(){const ids=selected();document.getElementById('selectedCount').textContent=`${ids.length} ausgewählt`;document.getElementById('selectionNames').textContent=ids.length?ids.join(', '):'Keine Server ausgewählt.'}
function renderServers(){document.getElementById('servers').innerHTML=DATA.servers.map(s=>`<div class="form-check py-1"><input class="form-check-input pm-server" type="checkbox" value="${s.idx}" id="s${s.idx}"><label class="form-check-label" for="s${s.idx}"><strong>${esc(s.name)}</strong> <span class="small text-body-secondary">${esc((s.groups||[]).join(', ')||'keine Gruppe')}</span></label></div>`).join('');document.querySelectorAll('.pm-server').forEach(x=>x.onchange=updateSelection);updateSelection()}
function setTab(name){document.querySelectorAll('.pm-tab').forEach(x=>x.classList.toggle('active',x.dataset.tab===name));document.querySelectorAll('.pm-panel').forEach(x=>x.classList.remove('active'));document.getElementById('panel-'+name).classList.add('active')}
document.querySelectorAll('.pm-tab').forEach(x=>x.onclick=()=>{if(x.dataset.tab==='fleet'&&!document.getElementById('fleetPackage').value)document.getElementById('fleetPackage').value=document.getElementById('pkg').value.trim();setTab(x.dataset.tab)});

let pkgTimer=null,pkgAbort=null;
function referenceServer(){const ids=selected();return ids[0]||document.getElementById('browseServer').value||''}
function hideSuggest(){document.getElementById('pkgSuggest').classList.add('d-none')}
function fillVersions(preview){const sel=document.getElementById('ver'),vals=[];for(const a of (preview.available||[])){if(a.version&&!vals.includes(a.version))vals.push(a.version)};const iv=preview.installed?.version||'';if(iv&&!vals.includes(iv))vals.push(iv);sel.innerHTML='<option value="">Automatisch / neueste verfügbare</option>'+vals.map(v=>`<option value="${esc(v)}">${esc(v)}${v===iv?' (installiert)':''}</option>`).join('')}
async function packageSearch(){
 const input=document.getElementById('pkg'),q=input.value.trim(),server=referenceServer(),box=document.getElementById('pkgSuggest'),progress=document.getElementById('packageSearchProgress'),previewBtn=document.getElementById('previewBtn');
 if(q.length<2||!server){hideSuggest();progress.classList.add('d-none');return}
 try{
  if(pkgAbort)pkgAbort.abort();pkgAbort=new AbortController();
  input.readOnly=true;previewBtn.disabled=true;progress.classList.remove('d-none');document.getElementById('packageSearchText').textContent=`Suche „${q}“ auf ${server} …`;
  const j=await api(`package_management.php?api=search&server=${encodeURIComponent(server)}&q=${encodeURIComponent(q)}`,{signal:pkgAbort.signal});
  const rows=j.search?.packages||[],total=j.search?.count??rows.length;
  if(!rows.length){box.innerHTML='<div class="p-2 text-body-secondary">Keine passenden Pakete gefunden.</div>';box.classList.remove('d-none');document.getElementById('packageSearchHint').textContent='0 Treffer gefunden.';return}
  box.innerHTML=`<div class="px-2 py-1 small text-body-secondary border-bottom"><strong>${rows.length}</strong> Treffer angezeigt${rows.length>=100?' (Maximum 100 – Suche weiter eingrenzen)':''}</div>`+rows.map((r,i)=>`<button type="button" class="pm-suggest-item" data-i="${i}"><div><strong>${esc(r.name)}</strong>${r.installed?' <span class="badge text-bg-success ms-1">installiert</span>':''}</div><div class="pm-suggest-meta">${esc(r.version||'Version unbekannt')} · ${esc(r.repository||'Repo unbekannt')}${r.installed_version?' · installiert: '+esc(r.installed_version):''}</div></button>`).join('');
  box.classList.remove('d-none');document.getElementById('packageSearchHint').textContent=`${total} Treffer gefunden. Bis zu 100 Treffer werden angezeigt.`;
  box.querySelectorAll('.pm-suggest-item').forEach(b=>b.onclick=async()=>{const r=rows[Number(b.dataset.i)];input.value=r.name;hideSuggest();await loadPreview(r.name,server)});
 }catch(e){if(e.name!=='AbortError'){hideSuggest();msg(e.message,'danger')}}finally{input.readOnly=false;previewBtn.disabled=false;progress.classList.add('d-none');input.focus()}
}
document.getElementById('pkg').addEventListener('input',()=>{clearTimeout(pkgTimer);pkgTimer=setTimeout(packageSearch,300)});
document.getElementById('pkg').addEventListener('keydown',e=>{if(e.key==='Escape')hideSuggest()});document.addEventListener('click',e=>{if(!e.target.closest('.pm-package-wrap'))hideSuggest()});
async function loadPreview(pkg,server){const j=await api(`package_management.php?api=preview&server=${encodeURIComponent(server)}&package=${encodeURIComponent(pkg)}`);const p=j.preview,os=p.os||{},inst=p.installed||{},avail=p.available||[];fillVersions(p);document.getElementById('previewBox').innerHTML=`<div class="mb-2"><strong>${esc(pkg)}</strong> auf <strong>${esc(server)}</strong> <span class="text-body-secondary">(${esc(os.pretty_name||'')}, ${esc(os.manager||'')})</span></div><div class="pm-preview-grid"><div class="pm-kv"><small>Installiert</small><strong>${inst.installed?'Ja':'Nein'}</strong></div><div class="pm-kv"><small>Installierte Version</small><strong>${esc(inst.version||'—')}</strong></div><div class="pm-kv"><small>Verfügbar</small><strong>${avail.length?'Ja':'Nicht gefunden'}</strong></div><div class="pm-kv"><small>Neueste gefundene Version</small><strong>${esc(avail[0]?.version||'—')}</strong></div></div>${avail.length?`<div class="table-responsive mt-3"><table class="table table-sm"><thead><tr><th>Version</th><th>Arch</th><th>Repository</th><th>Status</th></tr></thead><tbody>${avail.map(a=>`<tr><td><button type="button" class="btn btn-link btn-sm p-0 pm-use-version" data-v="${esc(a.version)}">${esc(a.version)}</button></td><td>${esc(a.arch||'—')}</td><td>${esc(a.repository||'—')}</td><td>${esc(a.status||'')}</td></tr>`).join('')}</tbody></table></div>`:'<div class="alert alert-warning mt-3 mb-0">In den aktuell konfigurierten Repositories wurde keine passende Version gefunden.</div>'}`;document.querySelectorAll('.pm-use-version').forEach(b=>b.onclick=()=>{document.getElementById('ver').value=b.dataset.v});setTab('preview')}

async function load(){DATA=await api('package_management.php?api=summary');renderServers();document.getElementById('group').innerHTML='<option value="">— Gruppe wählen —</option>'+DATA.groups.sort().map(g=>`<option>${esc(g)}</option>`).join('');document.getElementById('browseServer').innerHTML=DATA.servers.map(s=>`<option>${esc(s.name)}</option>`).join('')}
document.getElementById('selectGroup').onclick=()=>{const g=document.getElementById('group').value;if(!g){msg('Bitte zuerst eine Servergruppe wählen.','warning');return}document.querySelectorAll('.pm-server').forEach((x,i)=>x.checked=DATA.servers[i].groups.includes(g));updateSelection()}
document.getElementById('selectCanary').onclick=()=>{document.querySelectorAll('.pm-server').forEach((x,i)=>x.checked=DATA.servers[i].groups.includes('canary'));updateSelection();if(!selected().length)msg('Keine Server mit Gruppe "canary" gefunden.','warning')}
document.getElementById('clear').onclick=()=>{document.querySelectorAll('.pm-server').forEach(x=>x.checked=false);updateSelection()};
document.getElementById('previewBtn').onclick=async()=>{const pkg=document.getElementById('pkg').value.trim(),server=referenceServer();if(!pkg){msg('Paketname für die Vorschau eingeben.','warning');return}if(!server){msg('Kein Referenzserver verfügbar.','warning');return}try{await loadPreview(pkg,server)}catch(e){msg(e.message,'danger')}};
document.getElementById('installedBtn').onclick=async()=>{const btn=document.getElementById('installedBtn'),server=document.getElementById('browseServer').value,q=document.getElementById('installedQuery').value.trim(),progress=document.getElementById('installedProgress');btn.disabled=true;progress.classList.remove('d-none');try{const j=await api(`package_management.php?api=installed&server=${encodeURIComponent(server)}&q=${encodeURIComponent(q)}`);const x=j.installed||{},rows=x.packages||[],os=x.os||{};document.getElementById('installedRows').innerHTML=rows.length?rows.map(r=>`<tr><td><strong>${esc(r.name)}</strong></td><td>${esc(r.version)}</td><td>${esc(r.arch||'—')}</td><td>${r.update_available?`<span class="badge text-bg-warning">${esc(r.available_version||'Update')}</span>`:'<span class="text-body-secondary">aktuell</span>'}</td><td>${esc(r.repository||'—')}</td><td><button type="button" class="btn btn-outline-secondary btn-sm pm-inv-preview" data-pkg="${esc(r.name)}">Details</button></td></tr>`).join(''):`<tr><td colspan="6" class="text-body-secondary">Keine installierten Pakete für diesen Filter gefunden.</td></tr>`;document.getElementById('invServer').textContent=server;document.getElementById('invOs').textContent=`${os.pretty_name||'—'}${os.manager?' · '+os.manager:''}`;document.getElementById('invTotal').textContent=String(x.total_installed??x.count??rows.length);document.getElementById('invUpdates').textContent=String(x.updates_available??0);document.getElementById('installedSummary').textContent=`${rows.length} angezeigt`;document.getElementById('installedTabCount').textContent=String(x.total_installed??rows.length);document.querySelectorAll('.pm-inv-preview').forEach(b=>b.onclick=async()=>{document.getElementById('pkg').value=b.dataset.pkg;await loadPreview(b.dataset.pkg,server)});setTab('installed');msg(`Inventar von ${server} geladen: ${x.total_installed??rows.length} Pakete, ${x.updates_available??0} Update(s).`,'success')}catch(e){msg(e.message,'danger')}finally{btn.disabled=false;progress.classList.add('d-none')}};
document.getElementById('installedQuery').addEventListener('keydown',e=>{if(e.key==='Enter')document.getElementById('installedBtn').click()});
document.getElementById('fleetBtn').onclick=async()=>{const btn=document.getElementById('fleetBtn'),pkg=document.getElementById('fleetPackage').value.trim(),progress=document.getElementById('fleetProgress');if(!pkg){msg('Paket für den Fleet-Vergleich eingeben.','warning');return}btn.disabled=true;progress.classList.remove('d-none');try{const j=await api(`package_management.php?api=fleet&package=${encodeURIComponent(pkg)}`),rows=j.rows||[];document.getElementById('fleetRows').innerHTML=rows.length?rows.map(r=>{const os=r.os||{},state=!r.ok?['FEHLER','pm-fleet-bad']:!r.installed?['nicht installiert','pm-fleet-warn']:(r.update_available?['Update verfügbar','pm-fleet-warn']:['OK','pm-fleet-ok']);return `<tr><td><strong>${esc(r.server_name)}</strong></td><td>${esc(os.pretty_name||'—')}<div class="small text-body-secondary">${esc(os.manager||'')}</div></td><td>${r.installed?esc(r.version||'installiert'):'—'}</td><td>${esc(r.available_version||'—')}</td><td>${esc(r.repository||'—')}</td><td class="pm-fleet-state ${state[1]}">${state[0]}${r.error?`<div class="small">${esc(r.error)}</div>`:''}</td></tr>`}).join(''):`<tr><td colspan="6" class="text-body-secondary">Keine Server gefunden.</td></tr>`;document.getElementById('fleetSummary').textContent=`${rows.length} Server`;setTab('fleet')}catch(e){msg(e.message,'danger')}finally{btn.disabled=false;progress.classList.add('d-none')}};
document.getElementById('fleetPackage').addEventListener('keydown',e=>{if(e.key==='Enter')document.getElementById('fleetBtn').click()});
let progressTimer=null;
function setJobProgress(pct,title,text,done=false){const box=document.getElementById('jobProgress'),bar=document.getElementById('jobProgressBar');box.classList.remove('d-none');document.getElementById('jobProgressPct').textContent=`${pct}%`;document.getElementById('jobProgressTitle').textContent=title;document.getElementById('jobProgressText').textContent=text;bar.style.width=`${pct}%`;bar.setAttribute('aria-valuenow',String(pct));bar.classList.toggle('progress-bar-animated',!done);bar.classList.toggle('progress-bar-striped',!done)}
function startJobProgress(action,pkg,count){clearInterval(progressTimer);let pct=8;setTab('result');setJobProgress(pct,'Paketjob wird vorbereitet …',`${pkg}: ${action} auf ${count} Zielsystem(en).`);setTimeout(()=>setJobProgress(22,'Zielsysteme werden geprüft …','Verbindung, Paketmanager und aktueller Paketstatus werden ermittelt.'),180);setTimeout(()=>setJobProgress(38,'Paketaktion gestartet …','Der Config-Agent führt die Paketaktion auf den Zielsystemen aus.'),500);progressTimer=setInterval(()=>{if(pct<88){pct=Math.min(88,pct+Math.max(1,Math.round((90-pct)/10)));setJobProgress(pct,'Paketaktion läuft …','Warte auf die Rückmeldung der Zielsysteme. Bei Repository- oder Paketoperationen kann dies etwas dauern.')}},700)}
function finishJobProgress(ok,count){clearInterval(progressTimer);setJobProgress(100,ok?'Paketjob abgeschlossen':'Paketjob mit Fehlern abgeschlossen',`${count} Zielsystem(e) verarbeitet. Ergebnis siehe Tabelle.`,true)}
document.getElementById('run').onclick=async()=>{const runBtn=document.getElementById('run'),action=document.getElementById('action').value,pkg=document.getElementById('pkg').value.trim(),ver=document.getElementById('ver').value.trim(),ids=selected();if(!pkg||!ids.length){msg('Paket und mindestens einen Zielserver auswählen.','warning');return}if(action==='remove'&&!confirm(`Paket "${pkg}" wirklich auf ${ids.length} Server(n) entfernen?`))return;if(['install','upgrade'].includes(action)&&!confirm(`${action} für "${pkg}" auf ${ids.length} Server(n) ausführen?`))return;runBtn.disabled=true;startJobProgress(action,pkg,ids.length);try{const j=await api('package_management.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action,package:pkg,version:ver,server_names:ids,confirm_remove:action==='remove'})});document.getElementById('results').innerHTML=j.results.map(r=>{const x=r.response||{},os=x.os||{},b=x.before||{},a=x.after||{};return `<tr><td><strong>${esc(r.server_name)}</strong></td><td>${esc(os.pretty_name||'—')}<div class="small text-body-secondary">${esc(os.manager||'')}</div></td><td>${b.installed?'installiert '+esc(b.version):'nicht installiert'}</td><td>${a.installed?'installiert '+esc(a.version):'nicht installiert'}</td><td class="pm-status ${r.ok?'pm-ok':'pm-bad'}">${r.ok?'OK':'FEHLER'}${x.exit_code!==undefined?` (rc ${esc(x.exit_code)})`:''}</td></tr>`}).join('');const ok=j.results.every(r=>r.ok);finishJobProgress(ok,j.results.length);msg(ok?'Paketjob abgeschlossen.':'Paketjob abgeschlossen, einzelne Ziele haben Fehler gemeldet.',ok?'success':'warning')}catch(e){clearInterval(progressTimer);setJobProgress(100,'Paketjob fehlgeschlagen',e.message,true);msg(e.message,'danger')}finally{runBtn.disabled=false}};load();
</script><?php require MMBB_UI.'/includes/js.php';?></body></html>
