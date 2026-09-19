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
function f2_json(array $x,int $s=200):never{http_response_code($s);header('Content-Type: application/json; charset=utf-8');header('Cache-Control:no-store');echo json_encode($x,JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);exit;}
function f2_servers():array{return cm_load_config_manager_servers(__DIR__.'/../config/config.php');}
function f2_ctl(array $server):ConfigManagerController{return new ConfigManagerController(new ConfigManagerService(new ConfigManagerRepository($server)));}
function f2_body():array{$x=json_decode((string)file_get_contents('php://input'),true);if(!is_array($x))throw new InvalidArgumentException('Ungültiges JSON.');return $x;}
function f2_find(array $servers,string $name):array{foreach($servers as $s)if(strcasecmp((string)($s['name']??''),$name)===0)return $s;throw new RuntimeException('Unbekannter Server.',404);}
function f2_unwrap(array $r):array{$c=(int)($r['http_code']??500);$x=is_array($r['response']??null)?$r['response']:[];if($c<200||$c>=300||empty($x['ok']))throw new RuntimeException((string)($x['error']??('Agent HTTP '.$c)),$c>=400&&$c<=599?$c:502);return $x;}
try{
 $servers=[]; if((string)($_GET['api']??'')!=='' || $_SERVER['REQUEST_METHOD']==='POST') $servers=f2_servers();
 if(($_GET['api']??'')==='summary')f2_json(['ok'=>true,'servers'=>array_map(fn($s)=>['name'=>(string)($s['name']??'')],$servers)]);
 if(($_GET['api']??'')==='load'){$name=trim((string)($_GET['server']??''));$srv=f2_find($servers,$name);f2_json(['ok'=>true,'info'=>f2_unwrap(f2_ctl($srv)->getFail2BanInfo())]);}
 if($_SERVER['REQUEST_METHOD']==='POST'){
   $in=f2_body();if(!hash_equals($csrf,(string)($in['csrf_token']??'')))throw new RuntimeException('CSRF fehlgeschlagen.',403);$srv=f2_find($servers,trim((string)($in['server_name']??'')));$ctl=f2_ctl($srv);$action=(string)($in['action']??'');
   if($action==='install'){mmbb_audit_write('fail2ban_install',(string)$srv['name'],['server'=>(string)$srv['name']],'fail2ban.php','ok');f2_json(['ok'=>true,'result'=>f2_unwrap($ctl->installFail2Ban())]);}
   if($action==='save'){$cfg=is_array($in['config']??null)?$in['config']:[];$r=f2_unwrap($ctl->saveFail2BanConfig($cfg));mmbb_audit_write('fail2ban_config',(string)$srv['name'],['server'=>(string)$srv['name'],'jails'=>array_map(fn($j)=>(string)($j['name']??''),(array)($cfg['jails']??[]))],'fail2ban.php','ok');f2_json(['ok'=>true,'result'=>$r]);}
   if($action==='unban'){$jail=trim((string)($in['jail']??''));$ip=trim((string)($in['ip']??''));$r=f2_unwrap($ctl->unbanFail2Ban($jail,$ip));mmbb_audit_write('fail2ban_unban',$ip,['server'=>(string)$srv['name'],'jail'=>$jail],'fail2ban.php','ok');f2_json(['ok'=>true,'result'=>$r]);}
   throw new RuntimeException('Unbekannte Aktion.',400);
 }
}catch(Throwable $e){$c=(int)$e->getCode();f2_json(['ok'=>false,'error'=>$e->getMessage()],$c>=400&&$c<=599?$c:500);}
?>
<!DOCTYPE html><html lang="de"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Fail2ban</title>
<?php require MMBB_UI.'/includes/css.php';?>
<style>
.f2-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.75rem}.f2-stat{border:1px solid var(--bs-border-color);border-radius:.55rem;padding:.85rem;background:var(--bs-body-bg)}.f2-stat small{display:block;text-transform:uppercase;color:var(--bs-secondary-color);font-weight:700;font-size:.72rem}.f2-stat strong{font-size:1.25rem}.f2-jail-row{border:1px solid var(--bs-border-color);border-radius:.55rem;padding:.8rem;margin-bottom:.65rem;background:var(--bs-body-bg)}.f2-jail-grid{display:grid;grid-template-columns:1.15fr .9fr .8fr .9fr .9fr .9fr;gap:.6rem}.f2-filter-grid{display:grid;grid-template-columns:1fr 1fr;gap:.75rem}.f2-empty{padding:2rem;text-align:center;color:var(--bs-secondary-color)}@media(max-width:1100px){.f2-grid{grid-template-columns:repeat(2,1fr)}.f2-jail-grid,.f2-filter-grid{grid-template-columns:1fr 1fr}}@media(max-width:700px){.f2-grid,.f2-jail-grid,.f2-filter-grid{grid-template-columns:1fr}}
</style></head><body>
<?php require __DIR__.'/../standalone/layout/sidebar.php';?>
<main class="main-content"><div class="container-fluid py-3">
<?php $moduleHeaderTitle='Fail2ban';$moduleHeaderSubtitle='Fail2ban pro Server generisch verwalten: Jails, Filter, Bans und globale Einstellungen.';$moduleHeaderIcon='bi bi-shield-shaded';require __DIR__.'/../standalone/layout/module_header.php'; ?>
<div id="msg"></div>
<div class="card mb-3"><div class="card-body d-flex flex-wrap gap-2 align-items-end">
 <div><label class="form-label small fw-semibold">Zielserver</label><select id="server" class="form-select" style="min-width:260px"></select></div>
 <button id="reload" class="btn btn-outline-secondary"><i class="bi bi-arrow-clockwise me-1"></i>Status laden</button>
 <button id="install" class="btn btn-primary"><i class="bi bi-download me-1"></i>Fail2ban installieren</button>
 <div class="ms-auto small text-body-secondary">Änderungen werden mit <code>fail2ban-client -t</code> geprüft und bei Fehler zurückgerollt.</div>
</div></div>
<div class="f2-grid mb-3">
 <div class="f2-stat"><small>Installiert</small><strong id="installed">—</strong></div>
 <div class="f2-stat"><small>Dienst</small><strong id="service">—</strong></div>
 <div class="f2-stat"><small>Aktive Jails</small><strong id="jailCount">—</strong></div>
 <div class="f2-stat"><small>Aktuell gebannt</small><strong id="banCount">—</strong></div>
</div>
<div class="card" id="configCard">
 <div class="card-header p-0"><ul class="nav nav-tabs border-0 px-3 pt-2" role="tablist">
  <li class="nav-item"><button class="nav-link active" data-bs-toggle="tab" data-bs-target="#tabJails" type="button">Jails</button></li>
  <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#tabFilters" type="button">Filter</button></li>
  <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#tabBans" type="button">Gebannte IPs</button></li>
  <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#tabGlobal" type="button">Globale Einstellungen</button></li>
 </ul></div>
 <div class="card-body tab-content">
  <div class="tab-pane fade show active" id="tabJails">
   <div class="d-flex flex-wrap gap-2 align-items-end mb-3">
    <div><label class="form-label small fw-semibold">Vorlage</label><select id="template" class="form-select" style="min-width:220px"></select></div>
    <button id="addJail" class="btn btn-primary"><i class="bi bi-plus-lg me-1"></i>Jail hinzufügen</button>
    <span class="small text-body-secondary ms-auto">SSH, Apache/Nginx, Postfix, Dovecot, Recidive, ModSecurity oder eigene Anwendungen.</span>
   </div>
   <div id="jails"></div>
  </div>
  <div class="tab-pane fade" id="tabFilters">
   <div class="alert alert-info py-2 small">Eigene Filter werden pro Jail verwaltet. Sobald eine <strong>Failregex</strong> gesetzt ist, erzeugt der Agent einen geschützten <code>cm-managed-*</code>-Filter. <code>&lt;HOST&gt;</code> ist Pflicht.</div>
   <div id="filters"></div>
  </div>
  <div class="tab-pane fade" id="tabBans">
   <div class="d-flex justify-content-end mb-2"><button id="refreshBans" class="btn btn-sm btn-outline-secondary">Neu laden</button></div>
   <div class="table-responsive"><table class="table table-hover align-middle"><thead><tr><th>Jail</th><th>IP</th><th>Aktuell</th><th>Gesamt</th><th></th></tr></thead><tbody id="bans"></tbody></table></div>
  </div>
  <div class="tab-pane fade" id="tabGlobal">
   <label class="form-label fw-semibold">Allowlist / ignoreip</label><input id="ignoreip" class="form-control" placeholder="127.0.0.1/8 ::1 192.168.121.0/24"><div class="form-text">Nur vertrauenswürdige Adressen und Netze eintragen. Gilt für alle von diesem Modul verwalteten Jails.</div>
  </div>
 </div>
 <div class="card-footer d-flex gap-2 align-items-center"><button id="save" class="btn btn-success"><i class="bi bi-check-circle me-1"></i>Prüfen, speichern & aktivieren</button><span class="small text-body-secondary">Configtest → Service aktivieren → Reload → bei Fehler Rollback</span></div>
</div>
</div></main>
<script>
const CSRF=<?=json_encode($csrf)?>;let DATA=null,JAILS=[],TEMPLATES=[];
const $=id=>document.getElementById(id),esc=s=>String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
function msg(t,k='info'){$('msg').innerHTML=`<div class="alert alert-${k} py-2">${esc(t)}</div>`}
async function api(url,opt={}){const r=await fetch(url,opt),j=await r.json().catch(()=>({}));if(!r.ok||j.ok===false)throw new Error(j.error||`HTTP ${r.status}`);return j}
function clone(o){return JSON.parse(JSON.stringify(o))}
function normalizeJail(j={}){return {name:j.name||'',enabled:!!j.enabled,filter:j.filter||j.name||'',backend:j.backend||'auto',port:j.port||'all',logpath:j.logpath||'',action:j.action||'',maxretry:Number(j.maxretry||5),findtime:Number(j.findtime||600),bantime:Number(j.bantime||1800),failregex:j.failregex||'',ignoreregex:j.ignoreregex||''}}
function field(i,k,v,type='text',extra=''){return `<input class="form-control form-control-sm jail-field" data-i="${i}" data-k="${k}" type="${type}" value="${esc(v)}" ${extra}>`}
function renderJails(){
 if(!JAILS.length){$('jails').innerHTML='<div class="f2-empty">Noch keine verwalteten Jails. Eine Vorlage auswählen und hinzufügen.</div>';renderFilters();return;}
 $('jails').innerHTML=JAILS.map((j,i)=>`<div class="f2-jail-row"><div class="d-flex justify-content-between gap-2 mb-2"><div><strong>${esc(j.name||'Neue Jail')}</strong><span class="badge text-bg-light ms-2">${esc(j.filter||'kein Filter')}</span></div><div class="d-flex gap-2"><div class="form-check form-switch"><input class="form-check-input jail-enabled" data-i="${i}" type="checkbox" ${j.enabled?'checked':''}><label class="form-check-label small">aktiv</label></div><button class="btn btn-sm btn-outline-danger jail-remove" data-i="${i}"><i class="bi bi-trash"></i></button></div></div>
 <div class="f2-jail-grid">
  <div><label class="form-label small">Jail-Name</label>${field(i,'name',j.name)}</div>
  <div><label class="form-label small">Filter</label>${field(i,'filter',j.filter)}</div>
  <div><label class="form-label small">Backend</label><select class="form-select form-select-sm jail-field" data-i="${i}" data-k="backend">${['auto','systemd','polling','pyinotify','gamin'].map(x=>`<option ${x===j.backend?'selected':''}>${x}</option>`).join('')}</select></div>
  <div><label class="form-label small">Port</label>${field(i,'port',j.port)}</div>
  <div><label class="form-label small">MaxRetry</label>${field(i,'maxretry',j.maxretry,'number','min="1" max="1000"')}</div>
  <div><label class="form-label small">FindTime (s)</label>${field(i,'findtime',j.findtime,'number','min="1"')}</div>
  <div><label class="form-label small">BanTime (s)</label>${field(i,'bantime',j.bantime,'number','min="1"')}</div>
  <div style="grid-column:span 2"><label class="form-label small">Logpath <span class="text-body-secondary">(optional bei systemd)</span></label>${field(i,'logpath',j.logpath)}</div>
  <div style="grid-column:span 3"><label class="form-label small">Action <span class="text-body-secondary">(optional)</span></label>${field(i,'action',j.action)}</div>
 </div></div>`).join('');
 document.querySelectorAll('.jail-field').forEach(x=>x.onchange=()=>{const i=Number(x.dataset.i),k=x.dataset.k;JAILS[i][k]=x.type==='number'?Number(x.value):x.value.trim();if(k==='name'&&!JAILS[i].filter)JAILS[i].filter=JAILS[i].name;renderFilters()});
 document.querySelectorAll('.jail-enabled').forEach(x=>x.onchange=()=>JAILS[Number(x.dataset.i)].enabled=x.checked);
 document.querySelectorAll('.jail-remove').forEach(x=>x.onclick=()=>{if(confirm(`Jail ${JAILS[Number(x.dataset.i)].name} entfernen?`)){JAILS.splice(Number(x.dataset.i),1);renderJails();}});
 renderFilters();
}
function renderFilters(){
 if(!JAILS.length){$('filters').innerHTML='<div class="f2-empty">Keine Jails vorhanden.</div>';return;}
 $('filters').innerHTML=JAILS.map((j,i)=>`<div class="f2-jail-row"><div class="d-flex justify-content-between mb-2"><strong>${esc(j.name||'Neue Jail')}</strong><span class="small text-body-secondary">${j.failregex?'eigener Filter':'Standardfilter: '+esc(j.filter||'—')}</span></div><div class="f2-filter-grid"><div><label class="form-label small">Failregex</label><input class="form-control form-control-sm regex-field" data-i="${i}" data-k="failregex" value="${esc(j.failregex)}" placeholder="Leer = vorhandenen Fail2ban-Filter verwenden"><div class="form-text">Bei eigener Regex muss <code>&lt;HOST&gt;</code> enthalten sein.</div></div><div><label class="form-label small">Ignoreregex</label><input class="form-control form-control-sm regex-field" data-i="${i}" data-k="ignoreregex" value="${esc(j.ignoreregex)}" placeholder="optional"></div></div></div>`).join('');
 document.querySelectorAll('.regex-field').forEach(x=>x.onchange=()=>{JAILS[Number(x.dataset.i)][x.dataset.k]=x.value.trim()});
}
function addTemplate(){const id=$('template').value,t=TEMPLATES.find(x=>x.id===id)||TEMPLATES[0];if(!t)return;let j=normalizeJail(t);let base=id==='custom'?'custom':id,n=base,c=2;while(JAILS.some(x=>x.name===n))n=base+'-'+c++;j.name=n;if(id==='modsecurity'){j.failregex='^.*\\[client <HOST>(?::\\d+)?\\].*ModSecurity: Access denied.*$';j.filter='cm-managed-'+n}if(id==='web-scanner'){j.failregex='^.*?<HOST>\\s+.*"(?:GET|POST|HEAD) /(?:\\.env|\\.git|wp-admin|wp-login\\.php|phpmyadmin|server-status|vendor/phpunit).*".*$';j.filter='cm-managed-'+n}if(id==='custom'){j.filter=n;j.enabled=false}JAILS.push(j);renderJails()}
function getConfig(){return {ignoreip:$('ignoreip').value.trim(),jails:JAILS.map(normalizeJail)}}
function renderBans(status){const rows=[];for(const j of status?.jails||[]){if(!(j.banned_ips||[]).length)rows.push(`<tr><td><strong>${esc(j.name)}</strong></td><td class="text-body-secondary">—</td><td>${esc(j.current_banned)}</td><td>${esc(j.total_banned)}</td><td></td></tr>`);for(const ip of j.banned_ips||[])rows.push(`<tr><td><strong>${esc(j.name)}</strong></td><td><code>${esc(ip)}</code></td><td>${esc(j.current_banned)}</td><td>${esc(j.total_banned)}</td><td class="text-end"><button class="btn btn-sm btn-outline-danger unban" data-jail="${esc(j.name)}" data-ip="${esc(ip)}">Entsperren</button></td></tr>`)}$('bans').innerHTML=rows.join('')||'<tr><td colspan="5" class="text-body-secondary p-3">Keine aktiven Jails oder Bans.</td></tr>';document.querySelectorAll('.unban').forEach(b=>b.onclick=async()=>{if(!confirm(`${b.dataset.ip} aus ${b.dataset.jail} entsperren?`))return;try{await api('fail2ban.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'unban',server_name:$('server').value,jail:b.dataset.jail,ip:b.dataset.ip})});msg('IP entsperrt.','success');await load()}catch(e){msg(e.message,'danger')}})}
async function load(){const started=performance.now();msg('Fail2ban-Status wird geladen …','info');$('reload').disabled=true;const slowTimer=setTimeout(()=>msg('Fail2ban-Abfrage dauert länger als erwartet …','warning'),2000);try{const j=await api('fail2ban.php?api=load&server='+encodeURIComponent($('server').value));DATA=j.info;TEMPLATES=DATA.templates||[];JAILS=(DATA.config?.jails||[]).map(normalizeJail);$('installed').textContent=DATA.installed?'Ja':'Nein';$('service').textContent=DATA.service?.active?'aktiv':(DATA.installed?'inaktiv':'nicht installiert');$('jailCount').textContent=(DATA.status?.jails||[]).length;const bc=(DATA.status?.jails||[]).reduce((n,x)=>n+Number(x.current_banned||0),0);$('banCount').textContent=bc;$('ignoreip').value=DATA.config?.ignoreip||'127.0.0.1/8 ::1';$('template').innerHTML=TEMPLATES.map(t=>`<option value="${esc(t.id)}">${esc(t.label)}</option>`).join('');renderJails();renderBans(DATA.status||{});document.querySelectorAll('#configCard input,#configCard select,#configCard button').forEach(x=>x.disabled=!DATA.installed);$('reload').disabled=false;$('server').disabled=false;const available=DATA.install?.available!==false;$('install').disabled=!!DATA.installed||(!DATA.installed&&!available);$('install').innerHTML=DATA.installed?'<i class="bi bi-check-circle me-1"></i>Fail2ban installiert':(available?'<i class="bi bi-download me-1"></i>Fail2ban installieren':'<i class="bi bi-exclamation-triangle me-1"></i>Paket nicht verfügbar');const elapsed=Math.round(performance.now()-started);msg(DATA.installed?`Fail2ban-Status geladen (${elapsed} ms).`:`Fail2ban ist auf diesem Server noch nicht installiert. (${elapsed} ms)`,DATA.installed?'success':'warning')}catch(e){msg(e.message,'danger')}finally{clearTimeout(slowTimer);$('reload').disabled=false;$('server').disabled=false}}
async function init(){const j=await api('fail2ban.php?api=summary');$('server').innerHTML=j.servers.map(s=>`<option>${esc(s.name)}</option>`).join('');const requested=new URLSearchParams(location.search).get('server');if(requested&&[...$('server').options].some(o=>o.value===requested))$('server').value=requested;if(j.servers.length)await load()}
$('reload').onclick=load;$('refreshBans').onclick=load;$('server').onchange=load;$('addJail').onclick=addTemplate;$('install').onclick=async()=>{if(!confirm('Fail2ban auf dem ausgewählten Server installieren?'))return;try{$('install').disabled=true;await api('fail2ban.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'install',server_name:$('server').value})});msg('Fail2ban installiert.','success');await load()}catch(e){msg(e.message,'danger');$('install').disabled=false}};$('save').onclick=async()=>{try{await api('fail2ban.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'save',server_name:$('server').value,config:getConfig()})});msg('Fail2ban-Konfiguration geprüft, gespeichert und aktiviert.','success');await load()}catch(e){msg(e.message,'danger')}};init();
</script><?php require MMBB_UI.'/includes/js.php';?></body></html>
