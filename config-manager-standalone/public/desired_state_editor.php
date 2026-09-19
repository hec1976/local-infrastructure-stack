<?php
declare(strict_types=1);
require_once __DIR__ . '/../standalone/bootstrap.php';
require_once __DIR__ . '/../autoloader.php';
require_once __DIR__ . '/../Repository/ConfigManagerRepository.php';
require_once __DIR__ . '/../Service/ConfigManagerService.php';
require_once __DIR__ . '/../Controller/ConfigManagerController.php';
require_once __DIR__ . '/../lib/config_manager_runtime.php';

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Service\ConfigManagerService;
use ConfigManager\Controller\ConfigManagerController;

if (session_status() === PHP_SESSION_NONE) session_start();
if (empty($_SESSION['csrf_token'])) $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
$csrfToken = (string)$_SESSION['csrf_token'];
if (!headers_sent()) {
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: no-store, no-cache, must-revalidate');
}

$cfgFile = __DIR__ . '/../config/config.php';
$cfg = require $cfgFile;
$requiredService = trim((string)($cfg['git_deploy']['required_service'] ?? 'ConfigManager')) ?: 'ConfigManager';
if (function_exists('mmbb_has_service') && !mmbb_has_service($requiredService)) {
    http_response_code(403); exit('Keine Berechtigung fuer Desired State Editor.');
}
?>
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Desired State – Baselines</title>
<?php require MMBB_UI . '/includes/css.php'; ?>
<style>
.dse-layout{display:grid;grid-template-columns:minmax(250px,320px) minmax(0,1fr);gap:1rem;align-items:start}
.dse-list{max-height:70vh;overflow:auto}.dse-policy{cursor:pointer;border:1px solid var(--bs-border-color);border-radius:.55rem;padding:.75rem;margin-bottom:.55rem;background:var(--bs-body-bg)}
.dse-policy:hover{background:var(--bs-tertiary-bg)}.dse-policy.active{border-color:var(--bs-primary);box-shadow:0 0 0 .12rem rgba(13,110,253,.12)}
.dse-policy-title{font-weight:650}.dse-muted{color:var(--bs-secondary-color);font-size:.8rem}.dse-section{border-top:1px solid var(--bs-border-color);padding-top:1rem;margin-top:1rem}
.dse-label-row{display:grid;grid-template-columns:1fr 1fr auto;gap:.5rem;margin-bottom:.5rem}.dse-group-row{display:flex;gap:.45rem;align-items:center;margin-bottom:.45rem}.dse-match-mode{max-width:220px}
.dse-targets{max-height:230px;overflow:auto}.dse-json{min-height:360px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.8rem}
.dse-choicebar{display:flex;gap:.5rem;flex-wrap:wrap}.dse-choicebar .btn{min-width:125px}.dse-choicebar .btn.active{background:var(--bs-primary);border-color:var(--bs-primary);color:#fff}
.dse-chip-grid{display:flex;gap:.45rem;flex-wrap:wrap}.dse-chip{border:1px solid var(--bs-border-color);background:var(--bs-body-bg);border-radius:999px;padding:.42rem .7rem;font-size:.82rem;cursor:pointer;user-select:none}.dse-chip:hover{border-color:var(--bs-primary)}.dse-chip.active{background:rgba(13,110,253,.1);border-color:var(--bs-primary);color:var(--bs-primary);font-weight:650}
.dse-target-card{display:flex;justify-content:space-between;gap:1rem;align-items:flex-start;padding:.65rem .75rem;border-bottom:1px solid var(--bs-border-color)}.dse-target-card:last-child{border-bottom:0}.dse-target-meta{font-size:.75rem;color:var(--bs-secondary-color)}
.dse-advanced-box{border:1px dashed var(--bs-border-color);border-radius:.6rem;padding:.8rem;background:var(--bs-tertiary-bg)}
.dse-sticky{position:sticky;top:1rem}.dse-badge{font-size:.7rem}.dse-help{font-size:.78rem;color:var(--bs-secondary-color)}
@media(max-width:990px){.dse-layout{grid-template-columns:1fr}.dse-sticky{position:static}.dse-list{max-height:none}}
</style>
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>
<div class="container mmbb-main py-3 mmbb-page">
<?php require MMBB_UI . '/module_header.php'; ?>
<div class="d-flex flex-wrap gap-2 mb-3" role="navigation" aria-label="Desired State Bereiche">
  <a class="btn btn-outline-primary btn-sm" href="desired_state.php"><i class="bi bi-speedometer2 me-1"></i>Übersicht & Abweichungen</a>
  <a class="btn btn-primary btn-sm" href="desired_state_editor.php"><i class="bi bi-layers me-1"></i>Baselines verwalten</a>
  <span class="small text-body-secondary align-self-center ms-1">1 Sollzustand → 2 Zuweisung → 3 Abweichungen</span>
</div>
<div id="dseMsg" class="alert d-none"></div>
<div class="dse-layout">
  <aside class="card shadow-sm dse-sticky">
    <div class="card-header mmbb-card-header d-flex justify-content-between align-items-center">
      <span><i class="bi bi-layers me-1"></i>Baselines</span>
      <button class="btn btn-primary btn-sm" id="dseNew"><i class="bi bi-plus-lg"></i> Neue Baseline</button>
    </div>
    <div class="card-body">
      <input class="form-control form-control-sm mb-2" id="dseSearch" placeholder="Policy suchen …">
      <div class="dse-list" id="dseList"></div>
    </div>
  </aside>

  <main class="card shadow-sm">
    <div class="card-header mmbb-card-header d-flex justify-content-between align-items-center">
      <span><i class="bi bi-ui-checks-grid me-1"></i>Baseline bearbeiten</span>
      <div class="d-flex gap-2">
        <button class="btn btn-outline-secondary btn-sm" id="dseClone" disabled><i class="bi bi-copy"></i> Kopieren</button>
        <button class="btn btn-outline-danger btn-sm" id="dseDelete" disabled><i class="bi bi-trash"></i> Löschen</button>
      </div>
    </div>
    <div class="card-body" id="dseFormWrap">
      <div id="dseEmpty" class="text-center text-body-secondary py-5">Baseline auswählen oder eine neue Baseline anlegen.</div>
      <form id="dseForm" class="d-none" onsubmit="return false">
        <div class="row g-3">
          <div class="col-lg-4"><label class="form-label">Baseline-ID</label><input class="form-control" id="fId" required pattern="[A-Za-z0-9._-]+"><div class="dse-help">Eindeutiger technischer Name, z. B. <code>postfix-prod</code>.</div></div>
          <div class="col-lg-6"><label class="form-label">Beschreibung</label><input class="form-control" id="fDescription" maxlength="500"></div>
          <div class="col-lg-2 d-flex align-items-end"><div class="form-check form-switch mb-2"><input class="form-check-input" type="checkbox" id="fEnabled"><label class="form-check-label" for="fEnabled">Aktiv</label></div></div>
        </div>

        <div class="dse-section">
          <h6>1. Sollzustand</h6><div class="dse-help mb-2">Lege fest, welches verwaltete Objekt oder Deployment auf den Zielservern erwartet wird.</div>
          <div class="row g-3">
            <div class="col-md-4"><label class="form-label">Sollzustand basiert auf</label><select class="form-select" id="fSourceType"><option value="git">Git-Deploy-Profil</option><option value="config_manager">Verwalteter Konfiguration</option></select></div>
          </div>
          <div id="gitFields" class="row g-3 mt-0">
            <div class="col-lg-5"><label class="form-label">Deployment</label><select class="form-select" id="fDeployment"></select><div class="dse-help">Wird aus den vorhandenen Git-Deploy-Profilen geladen.</div></div>
            <div class="col-lg-3"><label class="form-label">Solltyp</label><select class="form-select" id="fDesiredType"><option value="allowed_ref">Aktueller freigegebener Ref</option><option value="tag">Tag</option><option value="commit">Commit</option></select></div>
            <div class="col-lg-4"><label class="form-label">Version / Ref</label><input class="form-control" id="fDesiredValue" placeholder="z. B. v1.3.0"><div class="dse-help" id="desiredHelp"></div></div>
          </div>
          <div id="cmFields" class="mt-0 d-none">
            <div class="row g-3">
              <div class="col-lg-4"><label class="form-label">Von Server übernehmen</label><select class="form-select" id="fRefServer"></select><div class="dse-help">Dieser Server liefert den Referenzinhalt für die Baseline.</div></div>
              <div class="col-lg-4"><label class="form-label">Konfiguration</label><select class="form-select" id="fSourceConfig"></select><div class="dse-help" id="sourceConfigHelp">Aus den Managed Configs des Referenzservers.</div></div>
              <div class="col-lg-4" id="targetMappingWrap"><label class="form-label">Abweichende Ziel-ID</label><select class="form-select" id="fTargetConfig"></select><div class="dse-help" id="targetConfigHelp">Nur nötig, wenn Quelle und Ziel bewusst unterschiedliche Config-IDs verwenden.</div></div>
            </div>
            <div class="form-check mt-2">
              <input class="form-check-input" type="checkbox" id="fSameTarget" checked>
              <label class="form-check-label" for="fSameTarget">Gleiche Config-ID auf den Zielservern verwenden (empfohlen)</label>
            </div>
            <div class="alert alert-light border mt-3 mb-0 py-2" id="cmObjectInfo">Config-Objekt auswählen. Pfad, Service und Verfügbarkeit werden automatisch angezeigt.</div>
          </div>
        </div>

        <div class="dse-section">
          <div class="d-flex justify-content-between align-items-start gap-3 flex-wrap mb-3">
            <div><h6 class="mb-1">2. Zuweisung</h6><div class="dse-help">Wähle, für welche Server diese Baseline gilt. Die Treffer werden sofort angezeigt.</div></div>
            <span class="badge text-bg-primary" id="targetCount">0 Server</span>
          </div>

          <div class="dse-choicebar mb-3" id="selectorModeBar">
            <button class="btn btn-outline-primary btn-sm" type="button" data-mode="all"><i class="bi bi-hdd-stack me-1"></i>Alle Server</button>
            <button class="btn btn-outline-primary btn-sm" type="button" data-mode="groups"><i class="bi bi-collection me-1"></i>Nach Gruppen</button>
            <button class="btn btn-outline-primary btn-sm" type="button" data-mode="labels"><i class="bi bi-tags me-1"></i>Nach Labels</button>
            <button class="btn btn-outline-secondary btn-sm" type="button" data-mode="advanced"><i class="bi bi-sliders me-1"></i>Erweitert</button>
          </div>

          <div id="simpleGroupBox" class="d-none mb-3">
            <label class="form-label">Gruppen auswählen</label>
            <div class="dse-help mb-2">Mehrere Gruppen bedeuten standardmässig <strong>ODER</strong>: Server aus mindestens einer gewählten Gruppe werden genommen.</div>
            <div class="dse-chip-grid" id="groupChips"></div>
          </div>

          <div id="simpleLabelBox" class="d-none mb-3">
            <label class="form-label">Labels auswählen</label>
            <div class="dse-help mb-2">Mehrere Labels müssen gemeinsam auf einen Server passen.</div>
            <div class="dse-chip-grid" id="labelChips"></div>
          </div>

          <div id="advancedSelectorBox" class="d-none dse-advanced-box mb-3">
            <div class="d-flex justify-content-between align-items-center gap-2 mb-2"><strong>Erweiterte Auswahl</strong><span class="dse-help">Nur nötig für komplexe Kombinationen.</span></div>
            <div class="row g-3">
              <div class="col-lg-6">
                <div class="d-flex justify-content-between align-items-center gap-2 mb-2"><label class="form-label mb-0">Gruppen</label><select class="form-select form-select-sm dse-match-mode" id="fGroupMatch"><option value="any">Mindestens eine Gruppe</option><option value="all">Alle Gruppen</option></select></div>
                <div id="groupRows"></div><button class="btn btn-outline-secondary btn-sm" type="button" id="addGroup"><i class="bi bi-plus"></i> Gruppe hinzufügen</button>
              </div>
              <div class="col-lg-6">
                <label class="form-label">Labels / Kategorien</label>
                <div id="labelRows"></div><button class="btn btn-outline-secondary btn-sm" type="button" id="addLabel"><i class="bi bi-plus"></i> Label hinzufügen</button>
              </div>
            </div>
          </div>

          <div class="p-3 bg-body-tertiary rounded border">
            <div class="d-flex justify-content-between align-items-center gap-2"><strong>Passende Server</strong><span class="small text-body-secondary" id="selectorSummary"></span></div>
            <div class="dse-targets mt-2" id="targetPreview"></div>
          </div>
        </div>

        <div class="dse-section">
          <h6>3. Abweichungen</h6><div class="dse-help mb-2">Standard ist nur prüfen. Eine Korrektur wird weiterhin bewusst und manuell gestartet.</div>
          <div class="row g-3">
            <div class="col-md-6"><label class="form-label">Bei Drift</label><select class="form-select" id="fEnforcement"><option value="check_only">Nur erkennen</option><option value="manual">Manuelle Behebung erlauben</option></select></div>
          </div>
          <details class="mt-3">
            <summary class="small fw-semibold text-body-secondary">Erweiterte Rollout-Einstellungen</summary>
            <div class="row g-3 mt-1">
              <div class="col-md-4"><label class="form-label">Max. Zielserver</label><input type="number" class="form-control" id="fMaxTargets" min="1" max="100" value="20"></div>
              <div class="col-md-5"><label class="form-label">Rollout</label><select class="form-select" id="fRollout"><option value="all">Alle Zielserver</option><option value="canary">Canary zuerst</option></select></div>
            </div>
          <div id="canaryFields" class="row g-3 mt-0 d-none">
            <div class="col-md-4"><label class="form-label">Canary-Gruppe</label><input class="form-control" id="fCanaryGroup" placeholder="z. B. canary"></div>
            <div class="col-md-4"><label class="form-label">Max. Canary-Ziele</label><input type="number" class="form-control" id="fMaxCanary" min="1" max="20" value="2"></div>
            <div class="col-md-4 d-flex align-items-end"><div class="form-check mb-2"><input class="form-check-input" type="checkbox" id="fRequireCanary" checked><label class="form-check-label" for="fRequireCanary">Canary muss compliant sein</label></div></div>
          </div>
          </details>
        </div>

        <div class="dse-section d-flex justify-content-between align-items-center flex-wrap gap-2">
          <button class="btn btn-outline-secondary" type="button" id="toggleJson"><i class="bi bi-braces"></i> Erweitert: JSON</button>
          <div class="d-flex gap-2"><button class="btn btn-outline-primary" type="button" id="dseValidate"><i class="bi bi-check2-circle"></i> Prüfen</button><button class="btn btn-primary" type="button" id="dseSave"><i class="bi bi-save"></i> Speichern</button></div>
        </div>
        <div id="jsonArea" class="d-none mt-3"><textarea class="form-control dse-json" id="rawJson" spellcheck="false"></textarea><div class="dse-help mt-1">Advanced: Änderungen hier werden beim Speichern übernommen, wenn du zuerst „JSON → Formular“ klickst.</div><button class="btn btn-outline-secondary btn-sm mt-2" id="jsonToForm" type="button">JSON → Formular</button></div>
      </form>
    </div>
  </main>
</div>
</div>
<script>
const DSE={csrf:<?= json_encode($csrfToken) ?>,doc:{schema_version:1,policies:{}},summary:null,current:null,deployments:[],configCatalog:{}};
const $=id=>document.getElementById(id); const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(url,opt={}){const r=await fetch(url,{cache:'no-store',credentials:'same-origin',...opt});const t=await r.text();let j;try{j=JSON.parse(t)}catch{throw new Error(`HTTP ${r.status}: ${t.slice(0,250)}`)}if(!r.ok||j.ok===false)throw new Error(j.error||`HTTP ${r.status}`);return j}
function msg(text,type='success'){const e=$('dseMsg');e.textContent=text;e.className=`alert alert-${type}`;e.classList.remove('d-none');clearTimeout(msg.t);msg.t=setTimeout(()=>e.classList.add('d-none'),6000)}
function blankPolicy(){return {enabled:false,description:'',source:{type:'git',deployment:'',desired:{type:'allowed_ref',value:''}},selector:{groups:[],labels:{},group_match:'any'},enforcement:'check_only',max_targets:20,rollout:{strategy:'all'}}}
function normalizedPolicy(p){p=structuredClone(p||blankPolicy());p.source=p.source||{type:'git'};p.selector=p.selector||{groups:[],labels:{}};p.selector.groups=p.selector.groups||[];p.selector.labels=p.selector.labels||{};p.selector.group_match=p.selector.group_match||'all';p.rollout=p.rollout||{strategy:'all'};if(p.source.type==='git'){p.source.deployment=p.source.deployment||p.deployment||'';p.source.desired=p.source.desired||p.desired||{type:'allowed_ref',value:''}}return p}
function renderList(){const q=$('dseSearch').value.trim().toLowerCase();const items=Object.entries(DSE.doc.policies||{}).filter(([id,p])=>`${id} ${p.description||''}`.toLowerCase().includes(q));$('dseList').innerHTML=items.length?items.map(([id,p])=>`<div class="dse-policy ${id===DSE.current?'active':''}" data-id="${esc(id)}"><div class="d-flex justify-content-between"><span class="dse-policy-title">${esc(id)}</span><span class="badge ${p.enabled?'text-bg-success':'text-bg-secondary'} dse-badge">${p.enabled?'aktiv':'aus'}</span></div><div class="dse-muted mt-1">${esc(p.description||'Keine Beschreibung')}</div></div>`).join(''):'<div class="text-body-secondary small py-3">Keine Policies.</div>'}
function options(values,selected=''){return [...new Set(values.filter(Boolean))].sort().map(v=>`<option value="${esc(v)}" ${v===selected?'selected':''}>${esc(v)}</option>`).join('')}
function groupValues(){return [...new Set((DSE.summary?.servers||[]).flatMap(s=>s.groups||[]).map(String))].sort()}
function labelKeys(){return [...new Set((DSE.summary?.servers||[]).flatMap(s=>Object.keys(s.labels||{})))].sort()}
function labelValues(key){return [...new Set((DSE.summary?.servers||[]).map(s=>(s.labels||{})[key]).filter(v=>v!==undefined).map(String))].sort()}
function labelPairs(){const out=[];for(const s of DSE.summary?.servers||[])for(const [k,v] of Object.entries(s.labels||{})){const pair=`${k}=${String(v)}`;if(!out.includes(pair))out.push(pair)}return out.sort()}
function addGroupRow(value=''){const row=document.createElement('div');row.className='dse-group-row';row.innerHTML=`<select class="form-select form-select-sm group-value"><option value="">Gruppe wählen …</option>${options(groupValues(),value)}</select><button type="button" class="btn btn-outline-danger btn-sm remove-row"><i class="bi bi-x"></i></button>`;$('groupRows').append(row);row.querySelector('.remove-row').onclick=()=>{row.remove();previewTargets()};row.querySelector('select').onchange=previewTargets}
function addLabelRow(key='',value=''){const row=document.createElement('div');row.className='dse-label-row';row.innerHTML=`<select class="form-select form-select-sm label-key"><option value="">Label …</option>${options(labelKeys(),key)}</select><select class="form-select form-select-sm label-value"><option value="">Wert …</option>${options(labelValues(key),value)}</select><button type="button" class="btn btn-outline-danger btn-sm remove-row"><i class="bi bi-x"></i></button>`;$('labelRows').append(row);const k=row.querySelector('.label-key'),v=row.querySelector('.label-value');k.onchange=()=>{v.innerHTML='<option value="">Wert …</option>'+options(labelValues(k.value));previewTargets()};v.onchange=previewTargets;row.querySelector('.remove-row').onclick=()=>{row.remove();previewTargets()}}
function renderSimpleSelector(){
 const groups=currentSelector().groups, labels=currentSelector().labels;
 $('groupChips').innerHTML=groupValues().length?groupValues().map(g=>`<button type="button" class="dse-chip ${groups.includes(g)?'active':''}" data-group="${esc(g)}">${esc(g)}</button>`).join(''):'<span class="dse-help">Keine Gruppen vorhanden.</span>';
 $('labelChips').innerHTML=labelPairs().length?labelPairs().map(pair=>{const [k,...rest]=pair.split('=');const v=rest.join('=');return `<button type="button" class="dse-chip ${String(labels[k]??'')===v?'active':''}" data-label-key="${esc(k)}" data-label-value="${esc(v)}">${esc(pair)}</button>`}).join(''):'<span class="dse-help">Keine Labels vorhanden.</span>';
}
function inferSelectorMode(sel){const g=sel.groups||[], l=Object.keys(sel.labels||{});if(!g.length&&!l.length)return 'all';if(g.length&&!l.length&&(sel.group_match||'any')==='any')return 'groups';if(!g.length&&l.length)return 'labels';return 'advanced'}
function setSelectorMode(mode,clear=false){DSE.selectorMode=mode;for(const b of document.querySelectorAll('#selectorModeBar [data-mode]'))b.classList.toggle('active',b.dataset.mode===mode);$('simpleGroupBox').classList.toggle('d-none',mode!=='groups');$('simpleLabelBox').classList.toggle('d-none',mode!=='labels');$('advancedSelectorBox').classList.toggle('d-none',mode!=='advanced');if(clear){$('groupRows').innerHTML='';$('labelRows').innerHTML='';$('fGroupMatch').value='any'}renderSimpleSelector();previewTargets()}
function currentSelector(){const groups=[...document.querySelectorAll('.group-value')].map(e=>e.value).filter(Boolean);const labels={};for(const row of document.querySelectorAll('.dse-label-row')){const k=row.querySelector('.label-key').value,v=row.querySelector('.label-value').value;if(k&&v)labels[k]=v}return {groups,labels,group_match:$('fGroupMatch').value||'any'}}
function selectedServers(sel){return (DSE.summary?.servers||[]).filter(s=>{const sg=(s.groups||[]).map(String);const groupsOk=!sel.groups.length||(sel.group_match==='any'?sel.groups.some(g=>sg.includes(g)):sel.groups.every(g=>sg.includes(g)));const labelsOk=Object.entries(sel.labels).every(([k,v])=>String((s.labels||{})[k]??'')===String(v));return groupsOk&&labelsOk})}
function previewTargets(){const sel=currentSelector();const servers=selectedServers(sel);$('targetCount').textContent=`${servers.length} Server`;let summary='Alle Server';if(sel.groups.length)summary=`Gruppen: ${sel.group_match==='any'?'eine von':'alle'} ${sel.groups.join(', ')}`;if(Object.keys(sel.labels).length)summary+=(sel.groups.length?' · ':'')+`Labels: ${Object.entries(sel.labels).map(([k,v])=>`${k}=${v}`).join(', ')}`;$('selectorSummary').textContent=summary;$('targetPreview').innerHTML=servers.length?servers.map(s=>`<div class="dse-target-card"><div><strong>${esc(s.name)}</strong><div class="dse-target-meta">${esc(s.url)}</div></div><div class="text-end">${(s.groups||[]).map(g=>`<span class="badge text-bg-primary me-1">${esc(g)}</span>`).join('')}${Object.entries(s.labels||{}).map(([k,v])=>`<span class="badge text-bg-secondary me-1">${esc(k)}=${esc(v)}</span>`).join('')}</div></div>`).join(''):'<div class="alert alert-warning py-2 mb-0"><strong>Keine Server gefunden.</strong> Entferne einen Filter oder wähle „Alle Server“.</div>';renderSimpleSelector();if($('fSourceType').value==='config_manager')refreshConfigSelectors($('fSourceConfig').value,$('fTargetConfig').value)}
function refreshSource(){const git=$('fSourceType').value==='git';$('gitFields').classList.toggle('d-none',!git);$('cmFields').classList.toggle('d-none',git);if(!git){serverOptions($('fRefServer').value);refreshConfigSelectors($('fSourceConfig').value,$('fTargetConfig').value)}}
function refreshDesired(){const t=$('fDesiredType').value;$('fDesiredValue').disabled=t==='allowed_ref';if(t==='allowed_ref')$('fDesiredValue').value='';$('desiredHelp').textContent=t==='allowed_ref'?'Verwendet den aktuellen Commit des freigegebenen Refs.':t==='tag'?'Beispiel: v1.3.0':'40/64-stelliger Commit-Hash.'}
function refreshRollout(){$('canaryFields').classList.toggle('d-none',$('fRollout').value!=='canary')}
function deploymentOptions(selected=''){const vals=DSE.deployments.map(x=>x.id||x);if(selected&&!vals.includes(selected))vals.push(selected);$('fDeployment').innerHTML=vals.length?options(vals,selected):`<option value="${esc(selected)}">${esc(selected||'Keine Deployments verfügbar')}</option>`}
function serverOptions(selected=''){const vals=(DSE.summary?.servers||[]).map(s=>s.name);if(selected&&!vals.includes(selected))vals.push(selected);$('fRefServer').innerHTML=options(vals,selected)}
function serverConfigIds(serverName){return Object.keys(DSE.configCatalog?.[serverName]?.configs||{}).sort()}
function configMeta(serverName,id){return DSE.configCatalog?.[serverName]?.configs?.[id]||null}
function configOptionHtml(ids,selected=''){return ids.map(id=>{const meta=configMeta($('fRefServer').value,id);const suffix=meta?.path?` — ${meta.path}`:'';return `<option value="${esc(id)}" ${id===selected?'selected':''}>${esc(id+suffix)}</option>`}).join('')}
function targetConfigIds(){const servers=selectedServers(currentSelector());const set=new Set();for(const srv of servers){for(const id of Object.keys(DSE.configCatalog?.[srv.name]?.configs||{}))set.add(id)}return [...set].sort()}
function refreshConfigObjectInfo(){if($('fSourceType').value!=='config_manager')return;const ref=$('fRefServer').value,src=$('fSourceConfig').value,tgt=$('fTargetConfig').value;const meta=configMeta(ref,src);const targets=selectedServers(currentSelector());let have=0;for(const srv of targets)if(DSE.configCatalog?.[srv.name]?.configs?.[tgt])have++;let html='';if(meta){html=`<strong>${esc(src)}</strong> · ${esc(meta.path||'kein Pfad')}${meta.service?` · Service: ${esc(meta.service)}`:''}`;}else{html='<strong>Quellobjekt nicht im Katalog gefunden.</strong>';}html+=`<br><span class="text-body-secondary">Ziel-ID <code>${esc(tgt||'—')}</code>: auf ${have} von ${targets.length} ausgewählten Servern vorhanden.</span>`;$('cmObjectInfo').innerHTML=html}
function refreshConfigSelectors(sourceSelected='',targetSelected=''){const ref=$('fRefServer').value;$('targetMappingWrap')?.classList.toggle('d-none',$('fSameTarget').checked);let sourceIds=serverConfigIds(ref);if(sourceSelected&&!sourceIds.includes(sourceSelected))sourceIds.push(sourceSelected);sourceIds.sort();$('fSourceConfig').innerHTML=sourceIds.length?configOptionHtml(sourceIds,sourceSelected):'<option value="">Keine Managed Configs verfügbar</option>';if(sourceSelected&&sourceIds.includes(sourceSelected))$('fSourceConfig').value=sourceSelected;const same=$('fSameTarget').checked;let target=targetSelected||$('fSourceConfig').value;if(same)target=$('fSourceConfig').value;let targetIds=targetConfigIds();if(target&&!targetIds.includes(target))targetIds.push(target);targetIds.sort();$('fTargetConfig').innerHTML=targetIds.length?targetIds.map(id=>`<option value="${esc(id)}" ${id===target?'selected':''}>${esc(id)}</option>`).join(''):'<option value="">Keine Ziel-Konfiguration verfügbar</option>';$('fTargetConfig').disabled=same;if(target)$('fTargetConfig').value=target;refreshConfigObjectInfo()}
function loadForm(id){DSE.current=id;renderList();const p=normalizedPolicy(DSE.doc.policies[id]);$('dseEmpty').classList.add('d-none');$('dseForm').classList.remove('d-none');$('dseClone').disabled=false;$('dseDelete').disabled=false;$('fId').value=id;$('fDescription').value=p.description||'';$('fEnabled').checked=!!p.enabled;$('fSourceType').value=p.source.type||'git';
 if((p.source.type||'git')==='git'){const dep=p.source.deployment||p.deployment||'';deploymentOptions(dep);const d=p.source.desired||p.desired||{type:'allowed_ref',value:''};$('fDesiredType').value=d.type||'allowed_ref';$('fDesiredValue').value=d.value||''}else{serverOptions(p.source.reference_server||'');const src=p.source.source_config||'',tgt=p.source.target_config||src;$('fSameTarget').checked=!tgt||tgt===src;refreshConfigSelectors(src,tgt)}
 $('fGroupMatch').value=p.selector.group_match||'any';$('groupRows').innerHTML='';for(const g of p.selector.groups||[])addGroupRow(g);$('labelRows').innerHTML='';for(const [k,v] of Object.entries(p.selector.labels||{}))addLabelRow(k,String(v));DSE.selectorMode=inferSelectorMode(p.selector);$('fEnforcement').value=p.enforcement||'check_only';$('fMaxTargets').value=p.max_targets||20;$('fRollout').value=p.rollout.strategy||'all';$('fCanaryGroup').value=(p.rollout.canary_selector?.groups||[])[0]||'';$('fMaxCanary').value=p.rollout.max_canary_targets||2;$('fRequireCanary').checked=p.rollout.require_canary_compliant!==false;refreshSource();refreshDesired();refreshRollout();setSelectorMode(DSE.selectorMode||'all',false);previewTargets();syncRaw()}
function formPolicy(){const type=$('fSourceType').value;const p={enabled:$('fEnabled').checked,description:$('fDescription').value.trim(),selector:currentSelector(),enforcement:$('fEnforcement').value,max_targets:Number($('fMaxTargets').value||20),rollout:{strategy:$('fRollout').value}};if(type==='git')p.source={type:'git',deployment:$('fDeployment').value,desired:{type:$('fDesiredType').value,value:$('fDesiredValue').value.trim()}};else p.source={type:'config_manager',reference_server:$('fRefServer').value,source_config:$('fSourceConfig').value.trim(),target_config:$('fTargetConfig').value.trim()};if(p.rollout.strategy==='canary')p.rollout={strategy:'canary',canary_selector:{groups:$('fCanaryGroup').value.trim()?[$('fCanaryGroup').value.trim()]:[],labels:{}},max_canary_targets:Number($('fMaxCanary').value||2),require_canary_compliant:$('fRequireCanary').checked};return p}
function applyFormToDoc(){if(!DSE.current)return;const newId=$('fId').value.trim();if(!/^[A-Za-z0-9._-]{1,80}$/.test(newId))throw new Error('Baseline-ID ist ungültig.');if(newId!==DSE.current&&DSE.doc.policies[newId])throw new Error('Baseline-ID existiert bereits.');const p=formPolicy();delete DSE.doc.policies[DSE.current];DSE.doc.policies[newId]=p;DSE.current=newId;renderList();syncRaw()}
function syncRaw(){$('rawJson').value=JSON.stringify(DSE.doc,null,2)}
async function saveOrValidate(action){try{applyFormToDoc();const j=await api('desired_state.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,content:JSON.stringify(DSE.doc),csrf_token:DSE.csrf})});DSE.doc=j.document||DSE.doc;renderList();if(action==='save')msg('Baselines atomar gespeichert.');else msg('Baseline-Konfiguration ist gültig.');}catch(e){msg(e.message,'danger')}}
async function loadAll(){try{const [s,d]=await Promise.all([api('desired_state.php?api=summary'),api('desired_state.php?api=document')]);DSE.summary=s;DSE.doc=JSON.parse(d.content||'{"schema_version":1,"policies":{}}');try{const r=await api('desired_state.php?api=editor_catalog');DSE.deployments=r.deployments||[];DSE.configCatalog=r.config_catalog||{}}catch{DSE.deployments=[]}renderList();if(Object.keys(DSE.doc.policies||{}).length)loadForm(Object.keys(DSE.doc.policies)[0]);}catch(e){msg(e.message,'danger')}}
$('dseList').onclick=e=>{const p=e.target.closest('[data-id]');if(p)loadForm(p.dataset.id)};$('dseSearch').oninput=renderList;$('dseNew').onclick=()=>{let id='new-policy',n=1;while(DSE.doc.policies[id])id=`new-policy-${++n}`;DSE.doc.policies[id]=blankPolicy();loadForm(id)};$('dseClone').onclick=()=>{if(!DSE.current)return;applyFormToDoc();let id=`${DSE.current}-copy`,n=1;while(DSE.doc.policies[id])id=`${DSE.current}-copy-${++n}`;DSE.doc.policies[id]=structuredClone(DSE.doc.policies[DSE.current]);loadForm(id)};$('dseDelete').onclick=()=>{if(!DSE.current||!confirm(`Baseline ${DSE.current} löschen?`))return;delete DSE.doc.policies[DSE.current];DSE.current=null;renderList();$('dseForm').classList.add('d-none');$('dseEmpty').classList.remove('d-none');$('dseClone').disabled=$('dseDelete').disabled=true};$('addGroup').onclick=()=>addGroupRow();$('addLabel').onclick=()=>addLabelRow();$('fGroupMatch').onchange=previewTargets;$('selectorModeBar').onclick=e=>{const b=e.target.closest('[data-mode]');if(!b)return;setSelectorMode(b.dataset.mode,true)};$('groupChips').onclick=e=>{const b=e.target.closest('[data-group]');if(!b)return;const g=b.dataset.group;const selected=[...document.querySelectorAll('.group-value')].map(x=>x.value).filter(Boolean);$('groupRows').innerHTML='';for(const x of (selected.includes(g)?selected.filter(v=>v!==g):[...selected,g]))addGroupRow(x);$('fGroupMatch').value='any';previewTargets()};$('labelChips').onclick=e=>{const b=e.target.closest('[data-label-key]');if(!b)return;const key=b.dataset.labelKey,val=b.dataset.labelValue;const labels=currentSelector().labels;$('labelRows').innerHTML='';if(String(labels[key]??'')===val)delete labels[key];else labels[key]=val;for(const [k,v] of Object.entries(labels))addLabelRow(k,v);previewTargets()};$('fSourceType').onchange=refreshSource;$('fRefServer').onchange=()=>refreshConfigSelectors();$('fSourceConfig').onchange=()=>{if($('fSameTarget').checked)$('fTargetConfig').value=$('fSourceConfig').value;refreshConfigSelectors($('fSourceConfig').value,$('fTargetConfig').value)};$('fTargetConfig').onchange=refreshConfigObjectInfo;$('fSameTarget').onchange=()=>refreshConfigSelectors($('fSourceConfig').value,$('fTargetConfig').value);$('fDesiredType').onchange=refreshDesired;$('fRollout').onchange=refreshRollout;$('dseValidate').onclick=()=>saveOrValidate('validate');$('dseSave').onclick=()=>saveOrValidate('save');$('toggleJson').onclick=()=>{applyFormToDoc();$('jsonArea').classList.toggle('d-none');syncRaw()};$('jsonToForm').onclick=()=>{try{const d=JSON.parse($('rawJson').value);if(!d||typeof d!=='object'||!d.policies)throw new Error('Ungültiges Desired-State-Dokument.');DSE.doc=d;renderList();const id=DSE.current&&d.policies[DSE.current]?DSE.current:Object.keys(d.policies)[0];if(id)loadForm(id);msg('JSON in Formular übernommen.','info')}catch(e){msg(e.message,'danger')}};
for(const id of ['fId','fDescription','fEnabled','fDeployment','fDesiredValue','fRefServer','fSourceConfig','fTargetConfig','fSameTarget','fEnforcement','fMaxTargets','fCanaryGroup','fMaxCanary','fRequireCanary'])$(id).addEventListener('change',()=>{try{if(DSE.current){const p=formPolicy();previewTargets()}}catch{}});
loadAll();
</script>
<?php require MMBB_UI . '/includes/js.php'; ?>
</body></html>
