<?php
declare(strict_types=1);
require_once __DIR__.'/../standalone/bootstrap.php';
require_once __DIR__.'/../autoloader.php';
require_once __DIR__.'/../Repository/ConfigManagerRepository.php';
require_once __DIR__.'/../Service/ConfigManagerService.php';
require_once __DIR__.'/../lib/config_manager_runtime.php';

if (!mmbb_has_service('ConfigManager')) { http_response_code(403); echo 'Forbidden'; exit; }

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;

function ms_json(array $x, int $status=200): never {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($x, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
    exit;
}
function ms_servers(): array { return cm_load_config_manager_servers(__DIR__.'/../config/config.php'); }
function ms_public(array $s): array {
    return [
        'name'=>(string)($s['name']??''),
        'groups'=>array_values((array)($s['groups']??[])),
        'labels'=>(array)($s['labels']??[]),
    ];
}
function ms_find(array $servers, string $name): array {
    foreach ($servers as $srv) if (strcasecmp((string)($srv['name']??''), $name)===0) return $srv;
    throw new InvalidArgumentException('Unbekannter Server.');
}
try {
    $servers=ms_servers();
    $api=(string)($_GET['api']??'');
    if ($api==='servers') {
        ms_json(['ok'=>true,'servers'=>array_map('ms_public',$servers)]);
    }
    if ($api==='server') {
        $name=trim((string)($_GET['server']??''));
        if ($name==='' || strlen($name)>128) throw new InvalidArgumentException('Ungültiger Servername.');
        $srv=ms_find($servers,$name);
        $svc=new ConfigManagerService(new ConfigManagerRepository($srv));
        $started=microtime(true);
        $resp=$svc->getMonitStatus();
        ms_json(['ok'=>true,'server'=>ms_public($srv),'latency_ms'=>(int)round((microtime(true)-$started)*1000),'monit'=>$resp]);
    }
} catch (Throwable $e) {
    if (isset($_GET['api'])) ms_json(['ok'=>false,'error'=>$e->getMessage()],502);
    $pageError=$e->getMessage();
}
?>
<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Server Health</title>
<?php require MMBB_UI.'/includes/css.php'; ?>
<style>
.ms-cards{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:.8rem}.ms-kpi{border:1px solid var(--bs-border-color);border-radius:.55rem;padding:.9rem 1rem;background:var(--bs-body-bg)}.ms-kpi small{display:block;color:var(--bs-secondary-color);font-size:.72rem;text-transform:uppercase;font-weight:700}.ms-kpi strong{font-size:1.55rem}.ms-server{border:1px solid var(--bs-border-color);border-radius:.6rem;margin-bottom:.8rem;overflow:hidden}.ms-server-head{display:grid;grid-template-columns:minmax(170px,1.3fr) 100px 120px 120px minmax(160px,1fr) 90px;gap:.7rem;align-items:center;padding:.8rem 1rem;background:var(--bs-tertiary-bg);cursor:pointer}.ms-server-body{padding:.8rem 1rem}.ms-badge{display:inline-block;border-radius:999px;padding:.2rem .55rem;font-size:.75rem;font-weight:700}.ms-ok{background:rgba(25,135,84,.12);color:var(--bs-success)}.ms-warn{background:rgba(255,193,7,.16);color:#8a6500}.ms-bad{background:rgba(220,53,69,.12);color:var(--bs-danger)}.ms-off{background:rgba(108,117,125,.13);color:var(--bs-secondary-color)}.ms-services{font-size:.88rem}.ms-services td,.ms-services th{vertical-align:middle}.ms-meter{height:7px;background:var(--bs-secondary-bg);border-radius:6px;overflow:hidden}.ms-meter>span{display:block;height:100%;background:currentColor}.ms-toolbar{display:flex;gap:.65rem;align-items:end;flex-wrap:wrap}.ms-toolbar .form-label{font-size:.72rem;margin-bottom:.25rem}.ms-system{display:flex;gap:1rem;flex-wrap:wrap;font-size:.82rem;color:var(--bs-secondary-color)}.ms-empty{padding:2rem;text-align:center;color:var(--bs-secondary-color)}.ms-all-services{font-size:.86rem}.ms-all-services td,.ms-all-services th{vertical-align:middle}.ms-all-services-wrap{max-height:58vh;overflow:auto}.ms-sticky-head thead th{position:sticky;top:0;z-index:2;background:var(--bs-body-bg)}
@media(max-width:1050px){.ms-cards{grid-template-columns:repeat(2,1fr)}.ms-server-head{grid-template-columns:1fr 90px 100px}.ms-hide-small{display:none}}
</style></head><body>
<?php require MMBB_UI.'/navigation.php'; require MMBB_UI.'/sidebar.php'; ?>
<div class="container mmbb-main py-3 mmbb-page"><?php require MMBB_UI.'/module_header.php'; ?>
<?php if(!empty($pageError)): ?><div class="alert alert-danger"><?=htmlspecialchars($pageError)?></div><?php endif; ?>
<div class="d-flex justify-content-end align-items-center gap-2 flex-wrap mb-3"><button id="refreshBtn" class="btn btn-primary btn-sm">Aktualisieren</button><div class="form-check form-switch mt-1"><input class="form-check-input" type="checkbox" id="autoRefresh" checked><label class="form-check-label small" for="autoRefresh">Auto 30s</label></div></div>
<div class="ms-cards mb-3"><div class="ms-kpi"><small>Server</small><strong id="kServers">0</strong></div><div class="ms-kpi"><small>Online</small><strong id="kOnline">0</strong></div><div class="ms-kpi"><small>Fehlerhafte Server</small><strong id="kFailed">0</strong></div><div class="ms-kpi"><small>Services gesamt</small><strong id="kSvcTotal">0</strong></div><div class="ms-kpi"><small>Services OK</small><strong id="kSvcOk">0</strong></div><div class="ms-kpi"><small>Services Fehler</small><strong id="kSvcBad">0</strong></div></div>
<div class="card shadow-sm mb-3"><div class="card-body py-2"><div class="ms-toolbar"><div><label class="form-label">Suche</label><input id="search" class="form-control form-control-sm" placeholder="Server oder Service"></div><div><label class="form-label">Gruppe</label><select id="groupFilter" class="form-select form-select-sm"><option value="">Alle</option></select></div><div><label class="form-label">Status</label><select id="statusFilter" class="form-select form-select-sm"><option value="">Alle</option><option value="ok">OK</option><option value="failed">Fehler</option><option value="warning">Warnung</option><option value="offline">Offline</option></select></div><div class="ms-system" id="lastUpdate"></div></div></div></div>
<div class="d-flex justify-content-between align-items-center mb-2"><h5 class="mb-0">Server-Details</h5><span class="small text-body-secondary">Server aufklappen: überwachte Services und Systemstatus anzeigen.</span></div>
<div id="servers"><div class="ms-empty">Server-Health wird geladen …</div></div>
<div class="card shadow-sm mb-3"><div class="card-header d-flex justify-content-between align-items-center"><div><strong>Überwachte Services</strong><div class="small text-body-secondary">Die Daten werden über den Config Agent vom lokalen Monit gelesen; Port 2812 muss nicht zentral erreichbar sein.</div></div><span id="allServiceCount" class="badge text-bg-secondary">0</span></div><div class="card-body py-2"><div class="ms-toolbar"><div><label class="form-label">Server</label><select id="serviceServerFilter" class="form-select form-select-sm"><option value="">Alle Server</option></select></div><div><label class="form-label">Service-Typ</label><select id="serviceTypeFilter" class="form-select form-select-sm"><option value="">Alle Typen</option></select></div><div><label class="form-label">Service-Status</label><select id="serviceStatusFilter" class="form-select form-select-sm"><option value="">Alle</option><option value="ok">OK</option><option value="failed">Fehler</option><option value="unmonitored">Nicht überwacht</option></select></div></div></div><div class="table-responsive ms-all-services-wrap"><table class="table table-sm table-hover mb-0 ms-all-services ms-sticky-head"><thead><tr><th>Status</th><th>Server</th><th>Service</th><th>Typ</th><th>Code</th><th>Monitor</th><th>Details</th></tr></thead><tbody id="allServicesBody"><tr><td colspan="7" class="ms-empty">Services werden geladen …</td></tr></tbody></table></div></div>
</div>
<script>
const state={servers:[],results:new Map(),timer:null};
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
const fmtPct=v=>v===null||v===undefined?'–':Number(v).toFixed(1)+'%';
const fmtUptime=s=>{s=Number(s||0);if(!s)return '–';const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);return (d?d+'d ':'')+(h?h+'h ':'')+m+'m'};
const badge=(text,kind)=>`<span class="ms-badge ms-${kind}">${esc(text)}</span>`;
function overall(r){if(!r||!r.ok)return 'offline';const s=r.monit?.summary?.overall||'warning';return s==='ok'?'ok':(s==='failed'?'failed':'warning')}
function serviceExtra(s){if(s.system){return `Load ${s.system.load_1??'–'} / RAM ${fmtPct(s.system.memory_percent)} / Swap ${fmtPct(s.system.swap_percent)}`};if(s.process){return `PID ${s.process.pid??'–'} · CPU ${fmtPct(s.process.cpu_percent)} · RAM ${fmtPct(s.process.memory_percent)}`};if(s.filesystem){return `Disk ${fmtPct(s.filesystem.block_percent)} · Inodes ${fmtPct(s.filesystem.inode_percent)}`};if(s.program){return `Exit ${s.program.status??'–'} · ${esc(s.program.output||'')}`};if(s.network){return `${s.network.speed??'–'} Mbit · RX err ${s.network.rx_errors??0} · TX err ${s.network.tx_errors??0}`};return ''}
function serviceState(s){if(Number(s.monitor)===0)return 'unmonitored';return Number(s.status)===0?'ok':'failed'}
function serviceBadge(s){const st=serviceState(s);return st==='ok'?badge('OK','ok'):(st==='failed'?badge('Fehler','bad'):badge('nicht überwacht','warn'))}
function renderAllServices(){
 const sf=document.querySelector('#serviceServerFilter').value,tf=document.querySelector('#serviceTypeFilter').value,stf=document.querySelector('#serviceStatusFilter').value,q=document.querySelector('#search').value.toLowerCase();
 let rows=[],types=new Set();
 for(const srv of state.servers){const r=state.results.get(srv.name);if(!r?.ok)continue;for(const svc of (r.monit?.services||[])){types.add(String(svc.type||'unknown'));const st=serviceState(svc);if(sf&&srv.name!==sf)continue;if(tf&&String(svc.type)!==tf)continue;if(stf&&st!==stf)continue;if(q&&!srv.name.toLowerCase().includes(q)&&!String(svc.name||'').toLowerCase().includes(q))continue;rows.push({srv,svc,st})}}
 rows.sort((a,b)=>a.srv.name.localeCompare(b.srv.name)||String(a.svc.type).localeCompare(String(b.svc.type))||String(a.svc.name).localeCompare(String(b.svc.name)));
 document.querySelector('#allServiceCount').textContent=rows.length;
 document.querySelector('#allServicesBody').innerHTML=rows.length?rows.map(({srv,svc})=>`<tr><td>${serviceBadge(svc)}</td><td><strong>${esc(srv.name)}</strong></td><td><strong>${esc(svc.name||'(ohne Namen)')}</strong></td><td>${esc(svc.type||'unknown')}</td><td>${svc.status??'–'}</td><td>${Number(svc.monitor)===0?'aus':'an'}</td><td>${serviceExtra(svc)||'<span class="text-body-secondary">–</span>'}</td></tr>`).join(''):'<tr><td colspan="7" class="ms-empty">Keine Services entsprechen den Filtern.</td></tr>';
 const typeSel=document.querySelector('#serviceTypeFilter'),oldType=typeSel.value;typeSel.innerHTML='<option value="">Alle Typen</option>'+[...types].sort().map(t=>`<option value="${esc(t)}">${esc(t)}</option>`).join('');typeSel.value=oldType;
}
function render(){let online=0,failServers=0,svcTotal=0,svcOk=0,svcBad=0;for(const srv of state.servers){const r=state.results.get(srv.name);if(r?.ok){online++;svcTotal+=Number(r.monit?.summary?.total||0);svcOk+=Number(r.monit?.summary?.healthy||0);svcBad+=Number(r.monit?.summary?.failed||0);if(overall(r)!=='ok')failServers++}else if(r)failServers++}document.querySelector('#kServers').textContent=state.servers.length;document.querySelector('#kOnline').textContent=online;document.querySelector('#kFailed').textContent=failServers;document.querySelector('#kSvcTotal').textContent=svcTotal;document.querySelector('#kSvcOk').textContent=svcOk;document.querySelector('#kSvcBad').textContent=svcBad;
 const q=document.querySelector('#search').value.toLowerCase(),g=document.querySelector('#groupFilter').value,st=document.querySelector('#statusFilter').value;let html='';
 for(const srv of state.servers){const r=state.results.get(srv.name);const os=overall(r);const svcs=r?.monit?.services||[];if(g&&!srv.groups.includes(g))continue;if(st&&os!==st)continue;if(q&&!(srv.name.toLowerCase().includes(q)||svcs.some(x=>String(x.name).toLowerCase().includes(q))))continue;
   if(!r){html+=`<div class="ms-server"><div class="ms-server-head"><strong>${esc(srv.name)}</strong>${badge('lädt…','off')}<span>–</span><span>–</span><span class="ms-hide-small">${esc(srv.groups.join(', '))}</span><span>–</span></div></div>`;continue}
   if(!r.ok){html+=`<div class="ms-server"><div class="ms-server-head"><strong>${esc(srv.name)}</strong>${badge('offline','bad')}<span>–</span><span>–</span><span class="ms-hide-small text-danger">${esc(r.error||'nicht erreichbar')}</span><span>${r.http_code||0}</span></div></div>`;continue}
   const m=r.monit,sum=m.summary||{},sys=m.system||{};const b=os==='ok'?badge('OK','ok'):(os==='failed'?badge('Fehler','bad'):badge('Warnung','warn'));const id='srv_'+srv.name.replace(/[^A-Za-z0-9_-]/g,'_');
   let rows='';for(const s of svcs){rows+=`<tr><td>${serviceBadge(s)}</td><td><strong>${esc(s.name)}</strong></td><td>${esc(s.type)}</td><td>${s.status}</td><td>${serviceExtra(s)}</td></tr>`}
   html+=`<div class="ms-server"><div class="ms-server-head" data-bs-toggle="collapse" data-bs-target="#${id}"><strong>${esc(srv.name)}</strong>${b}<span>${sum.healthy||0}/${sum.total||0}</span><span>${m.server?.version?'Monit '+esc(m.server.version):'–'}</span><span class="ms-hide-small">${esc(srv.groups.join(', '))}</span><span>${r.latency_ms||0} ms</span></div><div id="${id}" class="collapse ms-server-body"><div class="ms-system mb-2"><span>Host: <strong>${esc(m.server?.hostname||srv.name)}</strong></span><span>Uptime: <strong>${fmtUptime(m.server?.uptime)}</strong></span><span>Load: <strong>${sys.load_1??'–'} / ${sys.load_5??'–'} / ${sys.load_15??'–'}</strong></span><span>RAM: <strong>${fmtPct(sys.memory_percent)}</strong></span><span>CPU User/System: <strong>${fmtPct(sys.cpu_user)} / ${fmtPct(sys.cpu_system)}</strong></span></div><div class="table-responsive"><table class="table table-sm table-hover ms-services mb-0"><thead><tr><th>Status</th><th>Service</th><th>Typ</th><th>Code</th><th>Details</th></tr></thead><tbody>${rows}</tbody></table></div></div></div>`;
 }
 document.querySelector('#servers').innerHTML=html||'<div class="ms-empty">Keine Server entsprechen den Filtern.</div>';renderAllServices();}
async function loadOne(s){try{const res=await fetch(`monit_status.php?api=server&server=${encodeURIComponent(s.name)}`,{cache:'no-store'});const j=await res.json();state.results.set(s.name,j)}catch(e){state.results.set(s.name,{ok:false,error:e.message})}render()}
async function refresh(){document.querySelector('#refreshBtn').disabled=true;try{const r=await fetch('monit_status.php?api=servers',{cache:'no-store'});const j=await r.json();if(!j.ok)throw new Error(j.error||'Serverliste fehlgeschlagen');state.servers=j.servers||[];const serverSel=document.querySelector('#serviceServerFilter'),oldServer=serverSel.value;serverSel.innerHTML='<option value="">Alle Server</option>'+state.servers.map(s=>`<option value="${esc(s.name)}">${esc(s.name)}</option>`).join('');serverSel.value=oldServer;const groups=[...new Set(state.servers.flatMap(s=>s.groups||[]))].sort();const sel=document.querySelector('#groupFilter'),old=sel.value;sel.innerHTML='<option value="">Alle</option>'+groups.map(g=>`<option>${esc(g)}</option>`).join('');sel.value=old;render();await Promise.allSettled(state.servers.map(loadOne));document.querySelector('#lastUpdate').textContent='Letzte Aktualisierung: '+new Date().toLocaleTimeString()}catch(e){document.querySelector('#servers').innerHTML=`<div class="alert alert-danger">${esc(e.message)}</div>`}finally{document.querySelector('#refreshBtn').disabled=false}}
for(const id of ['search','groupFilter','statusFilter'])document.querySelector('#'+id).addEventListener(id==='search'?'input':'change',render);for(const id of ['serviceServerFilter','serviceTypeFilter','serviceStatusFilter'])document.querySelector('#'+id).addEventListener('change',renderAllServices);document.querySelector('#refreshBtn').addEventListener('click',refresh);document.querySelector('#autoRefresh').addEventListener('change',e=>{clearInterval(state.timer);if(e.target.checked)state.timer=setInterval(refresh,30000)});state.timer=setInterval(refresh,30000);refresh();
</script></body></html>
