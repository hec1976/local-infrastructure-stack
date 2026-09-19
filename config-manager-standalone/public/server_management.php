<?php
declare(strict_types=1);
require_once __DIR__ . '/../standalone/bootstrap.php';
if (!mmbb_has_service('ConfigManager')) { http_response_code(403); echo 'Forbidden'; exit; }

$csrf=(string)($_SESSION['csrf_token'] ?? '');
$registryFile='/opt/service/config-manager/servers.json';
$writer='/usr/bin/python3 /usr/local/libexec/teko-server-registry-write.py';
$tokenManager='/usr/bin/python3 /usr/local/libexec/teko-agent-token-manager.py';

function sm_json(array $d,int $s=200): never { http_response_code($s); header('Content-Type: application/json; charset=utf-8'); echo json_encode($d,JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE); exit; }
function sm_load(string $p): array {
    if(!is_file($p)||is_link($p)||!is_readable($p)) throw new RuntimeException('Server-Registry fehlt oder ist nicht lesbar.',500);
    $j=json_decode((string)file_get_contents($p),true);
    if(!is_array($j)||!is_array($j['servers']??null)) throw new RuntimeException('Server-Registry ist ungueltig.',500);
    return $j;
}
function sm_groups(mixed $raw): array {
    $out=[]; foreach(preg_split('/[\s,]+/',trim((string)$raw),-1,PREG_SPLIT_NO_EMPTY) as $g){
        if(!preg_match('/^[A-Za-z0-9._-]{1,64}$/',$g)) throw new InvalidArgumentException('Ungueltige Gruppe: '.$g);
        $out[strtolower($g)]=$g;
    } return array_values($out);
}
function sm_labels(mixed $raw): array {
    $out=[]; foreach(preg_split('/[\r\n,]+/',trim((string)$raw),-1,PREG_SPLIT_NO_EMPTY) as $item){
        if(!str_contains($item,'=')) throw new InvalidArgumentException('Labels als key=value angeben.');
        [$k,$v]=array_map('trim',explode('=',$item,2));
        if(!preg_match('/^[A-Za-z0-9._-]{1,64}$/',$k)||!preg_match('/^[A-Za-z0-9._:@\/-]{1,128}$/',$v)) throw new InvalidArgumentException('Ungueltiges Label: '.$item);
        $out[$k]=$v;
    } return $out;
}
function sm_write(array $j): void {
    $json=json_encode($j,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)."\n";
    $desc=[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']];
    $p=proc_open(['/usr/bin/sudo','-n','/usr/bin/python3','/usr/local/libexec/teko-server-registry-write.py'],$desc,$pipes,null,null,['bypass_shell'=>true]);
    if(!is_resource($p)) throw new RuntimeException('Registry-Writer konnte nicht gestartet werden.',500);
    fwrite($pipes[0],$json); fclose($pipes[0]); $out=stream_get_contents($pipes[1]); fclose($pipes[1]); $err=stream_get_contents($pipes[2]); fclose($pipes[2]); $rc=proc_close($p);
    if($rc!==0) throw new RuntimeException('Registry konnte nicht gespeichert werden: '.trim($err?:$out),500);
}

function sm_token_manage(array $payload): array {
    $desc=[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']];
    $p=proc_open(['/usr/bin/sudo','-n','/usr/bin/python3','/usr/local/libexec/teko-agent-token-manager.py'],$desc,$pipes,null,null,['bypass_shell'=>true]);
    if(!is_resource($p)) throw new RuntimeException('Agent-Token-Manager konnte nicht gestartet werden.',500);
    $json=json_encode($payload,JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
    fwrite($pipes[0],$json); fclose($pipes[0]);
    $out=stream_get_contents($pipes[1]); fclose($pipes[1]);
    $err=stream_get_contents($pipes[2]); fclose($pipes[2]);
    $rc=proc_close($p);
    $j=json_decode((string)$out,true);
    if($rc!==0 || !is_array($j) || empty($j['ok'])) {
        $msg=is_array($j)?(string)($j['error']??'') : '';
        if($msg==='') $msg=trim($err?:$out);
        throw new RuntimeException($msg!==''?$msg:'Agent-Token-Aktion fehlgeschlagen.',400);
    }
    return $j;
}

function sm_clean_server(array $in,array $old=[]): array {
    $name=trim((string)($in['name']??'')); $url=rtrim(trim((string)($in['url']??'')),'/');
    if(!preg_match('/^[A-Za-z0-9._:-]{1,128}$/',$name)) throw new InvalidArgumentException('Servername ist ungueltig.');
    $u=parse_url($url); if(!is_array($u)||!in_array(strtolower((string)($u['scheme']??'')),['http','https'],true)||empty($u['host'])) throw new InvalidArgumentException('Server-URL ist ungueltig.');
    $srv=$old; $srv['name']=$name; $srv['url']=$url; $srv['enabled']=!array_key_exists('enabled',$in)||!empty($in['enabled']);
    $srv['groups']=sm_groups($in['groups']??''); $srv['labels']=sm_labels($in['labels']??'');
    return $srv;
}

try {
    if(isset($_GET['api'])&&$_GET['api']==='list'){
        $j=sm_load($registryFile); $safe=[];
        foreach($j['servers'] as $i=>$s){ if(!is_array($s)) continue; $safe[]=['index'=>$i,'name'=>(string)($s['name']??''),'url'=>(string)($s['url']??''),'enabled'=>!isset($s['enabled'])||$s['enabled']!==false,'groups'=>array_values((array)($s['groups']??[])),'labels'=>(array)($s['labels']??[]),'token_source'=>!empty($s['token_file'])?'Datei':'Global']; }
        sm_json(['ok'=>true,'registry_file'=>$registryFile,'servers'=>$safe]);
    }
    if($_SERVER['REQUEST_METHOD']==='POST'){
        $in=json_decode((string)file_get_contents('php://input'),true); if(!is_array($in)) throw new InvalidArgumentException('Ungueltiges JSON.');
        if(!hash_equals($csrf,(string)($in['csrf_token']??''))) throw new RuntimeException('CSRF-Pruefung fehlgeschlagen.',403);
        $action=(string)($in['action']??'save'); $j=sm_load($registryFile); $servers=array_values($j['servers']);
        if(in_array($action,['token_status','token_sync','token_rotate','agent_repair'],true)) {
            $idx=(int)($in['index']??-1); if(!isset($servers[$idx])||!is_array($servers[$idx])) throw new InvalidArgumentException('Server nicht gefunden.');
            $req=['action'=>$action==='token_status'?'status':($action==='token_sync'?'sync':($action==='agent_repair'?'repair':'rotate')),'server'=>(string)($servers[$idx]['name']??'')];
            if($action==='agent_repair') {
                $mode=(string)($in['mode']??'repair');
                if(!in_array($mode,['update','repair','reset'],true)) throw new InvalidArgumentException('Ungueltiger Agent-Lifecycle-Modus.');
                $req['force']=$mode==='reset';
                $req['lifecycle_mode']=$mode;
            }
            if($action!=='token_status') {
                $ssh=(array)($in['ssh']??[]);
                $req += ['ssh_host'=>(string)($ssh['host']??''),'ssh_port'=>(int)($ssh['port']??22),'ssh_user'=>(string)($ssh['user']??'root'),'ssh_auth'=>(string)($ssh['auth']??'password'),'ssh_password'=>(string)($ssh['password']??''),'ssh_key_file'=>(string)($ssh['key_file']??''),'use_sudo'=>!empty($ssh['use_sudo'])];
            }
            $result=sm_token_manage($req);
            mmbb_audit_write('server_token_'.$req['action'],(string)$req['server'],['api_ok'=>(bool)($result['api']['ok']??false)],'server_management.php','ok');
            sm_json($result);
        }
        if($action==='create') { $servers[]=sm_clean_server((array)($in['server']??[])); }
        elseif($action==='save') { $idx=(int)($in['index']??-1); if(!isset($servers[$idx])||!is_array($servers[$idx])) throw new InvalidArgumentException('Server nicht gefunden.'); $servers[$idx]=sm_clean_server((array)($in['server']??[]),$servers[$idx]); }
        elseif($action==='delete') { $idx=(int)($in['index']??-1); if(!isset($servers[$idx])) throw new InvalidArgumentException('Server nicht gefunden.'); array_splice($servers,$idx,1); }
        else throw new InvalidArgumentException('Unbekannte Aktion.');
        $j['schema_version']=1; $j['servers']=array_values($servers); sm_write($j);
        mmbb_audit_write('server_registry_'.$action,(string)($in['server']['name']??$in['index']??''),['server_count'=>count($servers)],'server_management.php','ok');
        sm_json(['ok'=>true]);
    }
} catch(Throwable $e){ $c=(int)$e->getCode(); if($c<400||$c>599)$c=400; if(isset($_GET['api'])||$_SERVER['REQUEST_METHOD']==='POST') sm_json(['ok'=>false,'error'=>$e->getMessage()],$c); $pageError=$e->getMessage(); }
?>
<!DOCTYPE html><html lang="de"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Managed Hosts – Registry</title><?php require MMBB_UI.'/includes/css.php'; ?>
<style>
.sm-summary{display:grid;grid-template-columns:repeat(4,minmax(150px,1fr));gap:.75rem;margin-bottom:1rem}
.sm-summary-card{background:#fff;border:1px solid var(--mmbb-border);border-radius:var(--mmbb-radius-lg);padding:.8rem 1rem;box-shadow:0 1px 2px rgba(16,24,40,.05)}
.sm-summary-label{font-size:.7rem;text-transform:uppercase;letter-spacing:.045em;color:var(--mmbb-text-muted);font-weight:700}
.sm-summary-value{font-size:1.35rem;line-height:1.25;font-weight:700;margin-top:.15rem}
.sm-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(520px,1fr));gap:1rem}
.sm-card{overflow:hidden}.sm-card.off{opacity:.7}.sm-card .card-header{padding:.75rem 1rem;background:#fff}
.sm-server-title{display:flex;align-items:center;gap:.65rem;min-width:0}.sm-server-icon{width:2rem;height:2rem;display:inline-flex;align-items:center;justify-content:center;border-radius:.4rem;background:var(--mmbb-primary-soft);color:var(--mmbb-primary);flex:0 0 2rem}
.sm-server-name{font-weight:700}.sm-url{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.78rem;color:var(--mmbb-text-muted);overflow-wrap:anywhere;margin-top:.12rem}
.sm-card-body{display:grid;grid-template-columns:minmax(140px,.8fr) minmax(220px,1.3fr) minmax(150px,.7fr);gap:1rem;padding:1rem}
.sm-meta-title{font-size:.7rem;text-transform:uppercase;letter-spacing:.045em;color:var(--mmbb-text-muted);font-weight:700;margin-bottom:.45rem}
.sm-tags{display:flex;gap:.35rem;flex-wrap:wrap}.sm-tag{display:inline-flex;align-items:center;min-height:1.55rem;padding:.18rem .5rem;border-radius:.35rem;font-size:.75rem;font-weight:600;border:1px solid #cbd5e1;background:#f8fafc;color:#334155}.sm-tag.group{background:#eef2ff;border-color:#c7d2fe;color:#3730a3}.sm-tag.label{background:#ecfeff;border-color:#a5f3fc;color:#155e75}
.sm-auth{display:flex;align-items:center;gap:.45rem;color:var(--mmbb-text-muted);font-size:.82rem}.sm-auth-actions{display:flex;gap:.4rem;flex-wrap:wrap;margin-top:.65rem}.sm-token-state{font-size:.76rem;margin-top:.45rem}.sm-token-ok{color:#047857}.sm-token-bad{color:#b91c1c}.sm-card-footer{display:flex;align-items:center;justify-content:flex-end;padding:.65rem 1rem;background:#fafbfc;border-top:1px solid var(--mmbb-border)}
.sm-registry{display:inline-flex;align-items:center;gap:.4rem;font-size:.76rem;color:var(--mmbb-text-muted)}.sm-registry code{font-size:.75rem;color:#6b7280;background:#fff;border:1px solid #d8dde6;padding:.2rem .4rem;border-radius:.25rem}
@media(max-width:900px){.sm-summary{grid-template-columns:repeat(2,1fr)}.sm-grid{grid-template-columns:1fr}.sm-card-body{grid-template-columns:1fr}}
@media(max-width:520px){.sm-summary{grid-template-columns:1fr}}
</style></head><body>
<?php require MMBB_UI.'/navigation.php'; require MMBB_UI.'/sidebar.php'; ?>
<div class="container mmbb-main py-3 mmbb-page"><?php require MMBB_UI.'/module_header.php'; ?>
<?php require __DIR__.'/../standalone/layout/managed_hosts_tabs.php'; ?>
<div class="mmbb-page-toolbar mb-3"><div class="sm-registry"><i class="bi bi-database"></i><span>Registry</span><code>/opt/service/config-manager/servers.json</code></div><div class="mmbb-page-toolbar-spacer"></div><button class="btn btn-primary btn-sm" id="newBtn"><i class="bi bi-plus-lg me-1"></i>Server hinzufügen</button><button class="btn btn-outline-secondary btn-sm" id="refresh"><i class="bi bi-arrow-clockwise me-1"></i>Neu laden</button></div>
<div id="msg" class="alert d-none"></div>
<div class="sm-summary" id="summary"></div>
<div id="cards" class="sm-grid"></div></div>
<div class="modal fade" id="editModal" tabindex="-1"><div class="modal-dialog modal-lg"><div class="modal-content"><div class="modal-header"><h5 class="modal-title" id="modalTitle">Server bearbeiten</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div><div class="modal-body"><input type="hidden" id="idx"><div class="row g-3"><div class="col-md-5"><label class="form-label">Name</label><input id="name" class="form-control" placeholder="mail01"></div><div class="col-md-7"><label class="form-label">Agent URL</label><input id="url" class="form-control" placeholder="https://mail01:5008"></div><div class="col-12"><div class="form-check"><input class="form-check-input" type="checkbox" id="enabled" checked><label class="form-check-label" for="enabled">Server aktiv</label></div></div><div class="col-md-6"><label class="form-label">Gruppen</label><input id="groups" class="form-control" placeholder="mail, prod"><div class="form-text">Kommagetrennt, z. B. local, mail</div></div><div class="col-md-6"><label class="form-label">Labels</label><textarea id="labels" class="form-control" rows="3" placeholder="env=prod&#10;role=mailrelay"></textarea><div class="form-text">Ein key=value pro Zeile oder kommagetrennt.</div></div></div></div><div class="modal-footer"><button class="btn btn-outline-danger me-auto d-none" id="deleteBtn">Löschen</button><button class="btn btn-secondary" data-bs-dismiss="modal">Abbrechen</button><button class="btn btn-primary" id="saveBtn">Speichern</button></div></div></div></div>

<div class="modal fade" id="tokenModal" tabindex="-1"><div class="modal-dialog modal-lg"><div class="modal-content">
<div class="modal-header"><div><h5 class="modal-title">Agent Auth / Token</h5><div class="text-secondary small" id="tmServer"></div></div><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
<div class="modal-body"><input type="hidden" id="tmIdx">
<div class="alert alert-secondary py-2" id="tmStatus">Tokenstatus noch nicht geprüft.</div>
<div class="row g-3"><div class="col-md-6"><label class="form-label">SSH Host / IP</label><input id="tmHost" class="form-control"></div><div class="col-md-2"><label class="form-label">Port</label><input id="tmPort" type="number" class="form-control" value="22"></div><div class="col-md-4"><label class="form-label">SSH Benutzer</label><input id="tmUser" class="form-control" value="root"></div>
<div class="col-12"><label class="form-label d-block">SSH Authentifizierung</label><div class="btn-group" role="group"><input class="btn-check" type="radio" name="tmAuth" id="tmAuthPassword" value="password" checked><label class="btn btn-outline-primary" for="tmAuthPassword">Passwort</label><input class="btn-check" type="radio" name="tmAuth" id="tmAuthKey" value="key"><label class="btn btn-outline-primary" for="tmAuthKey">SSH-Key</label></div></div>
<div class="col-md-8" id="tmPasswordWrap"><label class="form-label">SSH-Passwort</label><input id="tmPassword" type="password" class="form-control" autocomplete="new-password"><div class="form-text">Nur für diese Aktion; wird nicht gespeichert oder protokolliert.</div></div>
<div class="col-md-8 d-none" id="tmKeyWrap"><label class="form-label">Private Key auf dem Manager</label><input id="tmKeyFile" class="form-control" value="/root/.ssh/id_ed25519"><div class="form-text">Root-lesbare Key-Datei auf dem Config-Manager.</div></div>
<div class="col-md-4 d-flex align-items-end"><div class="form-check mb-2"><input class="form-check-input" type="checkbox" id="tmSudo"><label class="form-check-label" for="tmSudo">sudo -n verwenden</label></div></div></div>
<div class="mt-3 p-3 border rounded bg-light"><strong>Hinweis</strong><div class="small text-secondary mt-1">Dieser Dialog verwaltet nur Authentisierung und Token. Agent-Update, Reparatur und Reset befinden sich bewusst getrennt unter <strong>Agent Lifecycle</strong>.</div></div>
</div><div class="modal-footer"><button class="btn btn-secondary" data-bs-dismiss="modal">Schliessen</button><button class="btn btn-outline-secondary" id="tmCheck"><i class="bi bi-heart-pulse me-1"></i>Prüfen</button><button class="btn btn-outline-primary" id="tmSync"><i class="bi bi-arrow-repeat me-1"></i>Via SSH synchronisieren</button><button class="btn btn-danger" id="tmRotate"><i class="bi bi-key-fill me-1"></i>Token rotieren</button></div>
</div></div></div>


<div class="modal fade" id="lifecycleModal" tabindex="-1" aria-hidden="true"><div class="modal-dialog modal-lg modal-dialog-centered"><div class="modal-content">
<div class="modal-header"><div><h5 class="modal-title">Agent Lifecycle</h5><div class="text-secondary small" id="lcServer"></div></div><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
<div class="modal-body"><input type="hidden" id="lcIdx"><div id="lcStatus" class="alert alert-secondary py-2">Aktion auswählen.</div>
<div class="row g-3"><div class="col-md-6"><label class="form-label">SSH Host / IP</label><input class="form-control" id="lcHost"></div><div class="col-md-2"><label class="form-label">Port</label><input class="form-control" id="lcPort" type="number" min="1" max="65535" value="22"></div><div class="col-md-4"><label class="form-label">SSH Benutzer</label><input class="form-control" id="lcUser" value="root"></div></div>
<div class="mt-3"><label class="form-label d-block">SSH Authentisierung</label><div class="btn-group" role="group"><input type="radio" class="btn-check" name="lcAuth" id="lcAuthPassword" value="password" checked><label class="btn btn-outline-primary" for="lcAuthPassword">Passwort</label><input type="radio" class="btn-check" name="lcAuth" id="lcAuthKey" value="key"><label class="btn btn-outline-primary" for="lcAuthKey">SSH-Key</label></div></div>
<div class="mt-3" id="lcPasswordWrap"><label class="form-label">SSH-Passwort</label><input type="password" class="form-control" id="lcPassword" autocomplete="new-password"><div class="form-text">Nur für diese Aktion; wird nicht gespeichert oder protokolliert.</div></div>
<div class="mt-3 d-none" id="lcKeyWrap"><label class="form-label">SSH-Key-Datei auf dem Config Manager</label><input class="form-control" id="lcKeyFile" placeholder="/opt/service/env/enrollment/id_ed25519"></div>
<div class="form-check mt-3"><input class="form-check-input" type="checkbox" id="lcSudo"><label class="form-check-label" for="lcSudo">sudo -n verwenden</label></div>
<hr class="my-4">
<div class="row g-3">
<div class="col-md-4"><div class="border rounded p-3 h-100"><div class="fw-semibold mb-1"><i class="bi bi-arrow-up-circle me-1"></i>Agent aktualisieren</div><div class="small text-secondary mb-3">Agent-Code neu ausrollen. Host-ID, Token, Registry, Gruppen, Labels und vorhandene Remote-Einstellungen bleiben erhalten.</div><button class="btn btn-outline-primary w-100" id="lcUpdate">Aktualisieren</button></div></div>
<div class="col-md-4"><div class="border rounded p-3 h-100"><div class="fw-semibold mb-1"><i class="bi bi-wrench-adjustable me-1"></i>Agent reparieren</div><div class="small text-secondary mb-3">Agent-Dateien und Service erneut ausrollen, Rechte/TLS/Defaults prüfen. Lokale Konfiguration wird soweit möglich beibehalten.</div><button class="btn btn-warning w-100" id="lcRepair">Reparieren</button></div></div>
<div class="col-md-4"><div class="border border-danger rounded p-3 h-100 bg-danger-subtle"><div class="fw-semibold text-danger mb-1"><i class="bi bi-arrow-counterclockwise me-1"></i>Auf Defaults zurücksetzen</div><div class="small mb-3">Ersetzt die Remote-Agent-Konfiguration durch die aktuellen zentralen Defaults. <code>managed_configs.json</code> wird auf den Remote-Default zurückgesetzt.</div><button class="btn btn-danger w-100" id="lcReset">Defaults zurücksetzen</button></div></div>
</div></div>
<div class="modal-footer"><button class="btn btn-secondary" data-bs-dismiss="modal">Schliessen</button></div>
</div></div></div>

<script>window.SM_CSRF=<?=json_encode($csrf)?>;</script><?php require MMBB_UI.'/includes/js.php'; ?>
<script>
const $=id=>document.getElementById(id); let data=[]; const modal=new bootstrap.Modal($('editModal')); const tokenModal=new bootstrap.Modal($('tokenModal')); const lifecycleModal=new bootstrap.Modal($('lifecycleModal'));
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function notify(t,ok=true){const m=$('msg');m.textContent=t;m.className='alert '+(ok?'alert-success':'alert-danger');setTimeout(()=>m.classList.add('d-none'),4500);}
async function api(url,opt={}){const r=await fetch(url,{credentials:'same-origin',...opt});const j=await r.json().catch(()=>({ok:false,error:'Ungueltige Antwort'}));if(!r.ok||!j.ok)throw new Error(j.error||('HTTP '+r.status));return j;}
function tags(a,kind='group'){return (a||[]).map(x=>`<span class="sm-tag ${kind}">${esc(x)}</span>`).join(' ')}
function renderSummary(){const active=data.filter(s=>s.enabled).length;const groups=new Set(data.flatMap(s=>s.groups||[]));const labels=new Set(data.flatMap(s=>Object.keys(s.labels||{})));$('summary').innerHTML=`<div class="sm-summary-card"><div class="sm-summary-label">Server gesamt</div><div class="sm-summary-value">${data.length}</div></div><div class="sm-summary-card"><div class="sm-summary-label">Aktiv</div><div class="sm-summary-value text-success">${active}</div></div><div class="sm-summary-card"><div class="sm-summary-label">Gruppen</div><div class="sm-summary-value">${groups.size}</div></div><div class="sm-summary-card"><div class="sm-summary-label">Label-Schlüssel</div><div class="sm-summary-value">${labels.size}</div></div>`;}
function render(){renderSummary();const c=$('cards');if(!data.length){c.innerHTML='<div class="alert alert-secondary">Keine Server registriert.</div>';return;}c.innerHTML=data.map((s,i)=>`<section class="card sm-card ${s.enabled?'':'off'}"><div class="card-header d-flex align-items-center gap-3"><div class="sm-server-title"><span class="sm-server-icon"><i class="bi bi-server"></i></span><div><div class="sm-server-name">${esc(s.name)}</div><div class="sm-url">${esc(s.url)}</div></div></div><span class="ms-auto badge ${s.enabled?'text-bg-success':'text-bg-secondary'}">${s.enabled?'aktiv':'inaktiv'}</span></div><div class="sm-card-body"><div><div class="sm-meta-title">Gruppen</div><div class="sm-tags">${tags(s.groups,'group')||'<span class="text-secondary small">Keine Gruppen</span>'}</div></div><div><div class="sm-meta-title">Labels</div><div class="sm-tags">${tags(Object.entries(s.labels||{}).map(([k,v])=>k+'='+v),'label')||'<span class="text-secondary small">Keine Labels</span>'}</div></div><div><div class="sm-meta-title">Authentifizierung</div><div class="sm-auth"><i class="bi bi-shield-lock"></i><span>Token: ${esc(s.token_source)}</span></div><div class="sm-auth-actions"><button class="btn btn-outline-secondary btn-sm" onclick="checkToken(${i})"><i class="bi bi-heart-pulse me-1"></i>Token prüfen</button><button class="btn btn-outline-primary btn-sm" onclick="tokenManage(${i})"><i class="bi bi-key me-1"></i>Token / SSH</button><button class="btn btn-outline-warning btn-sm" onclick="lifecycleManage(${i})"><i class="bi bi-arrow-repeat me-1"></i>Agent Lifecycle</button></div><div class="sm-token-state" id="tokenState${i}"></div></div></div><div class="sm-card-footer"><button class="btn btn-outline-primary btn-sm" onclick="edit(${i})"><i class="bi bi-pencil me-1"></i>Bearbeiten</button></div></section>`).join('');}
async function load(){try{const j=await api('server_management.php?api=list');data=j.servers||[];render();}catch(e){notify(e.message,false)}}
function edit(i){const s=data[i];$('idx').value=i;$('name').value=s.name;$('url').value=s.url;$('enabled').checked=!!s.enabled;$('groups').value=(s.groups||[]).join(', ');$('labels').value=Object.entries(s.labels||{}).map(([k,v])=>k+'='+v).join('\n');$('modalTitle').textContent='Server bearbeiten';$('deleteBtn').classList.remove('d-none');modal.show();}
function create(){ $('idx').value='';$('name').value='';$('url').value='';$('enabled').checked=true;$('groups').value='';$('labels').value='';$('modalTitle').textContent='Server hinzufügen';$('deleteBtn').classList.add('d-none');modal.show();}
async function save(){const idx=$('idx').value;const body={csrf_token:SM_CSRF,action:idx===''?'create':'save',server:{name:$('name').value,url:$('url').value,enabled:$('enabled').checked,groups:$('groups').value,labels:$('labels').value}};if(idx!=='')body.index=Number(idx);try{await api('server_management.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});modal.hide();notify('Server-Registry gespeichert.');await load();}catch(e){notify(e.message,false)}}
async function del(){const idx=$('idx').value;if(idx===''||!confirm('Server wirklich aus der Registry löschen?'))return;try{await api('server_management.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:SM_CSRF,action:'delete',index:Number(idx)})});modal.hide();notify('Server entfernt.');await load();}catch(e){notify(e.message,false)}}

function tokenHealthErrors(a){try{const b=JSON.parse(a.body||'{}');return Array.isArray(b.errors)?b.errors:[]}catch(e){return []}}
function tokenStatusText(j){const t=j.token||{},a=j.api||{};const bits=[];bits.push(t.exists?'Datei vorhanden':'Datei fehlt');if(t.mode)bits.push(t.owner+':'+t.group+' '+t.mode);if(t.fingerprint)bits.push('FP '+t.fingerprint);if(a.ok||a.authenticated===true)bits.push('Auth OK');else if(a.authenticated===false)bits.push('Auth FEHLER');else bits.push('Auth nicht verifiziert');if(a.ok)bits.push('Health OK');else if(a.authenticated===true)bits.push('Health FEHLER'+(a.http_status?' ('+a.http_status+')':''));else if(a.http_status)bits.push('API HTTP '+a.http_status);else bits.push('API nicht verifiziert');return bits.join(' · ')}
function tokenStatusHtml(j){const a=j.api||{};const errs=tokenHealthErrors(a);let h='<div>'+esc(tokenStatusText(j))+'</div>';if(errs.length)h+='<div class=\"mt-2 small\"><strong>Agent Health:</strong><ul class=\"mb-0 mt-1\">'+errs.map(e=>'<li>'+esc(e)+'</li>').join('')+'</ul></div>';return h}
async function checkToken(i){const el=$('tokenState'+i);if(el){el.className='sm-token-state';el.textContent='Prüfe ...';}try{const j=await api('server_management.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:SM_CSRF,action:'token_status',index:i})});if(el){el.className='sm-token-state '+((j.api||{}).ok?'sm-token-ok':'sm-token-bad');el.textContent=tokenStatusText(j);}return j;}catch(e){if(el){el.className='sm-token-state sm-token-bad';el.textContent=e.message;}throw e;}}
function tokenManage(i){const s=data[i];$('tmIdx').value=i;$('tmServer').textContent=s.name+' · '+s.url;try{const u=new URL(s.url);$('tmHost').value=u.hostname;}catch(e){$('tmHost').value='';}$('tmPort').value=22;$('tmUser').value='root';$('tmPassword').value='';$('tmStatus').className='alert alert-secondary py-2';$('tmStatus').textContent='Tokenstatus wird geprüft ...';tokenModal.show();tokenAction('token_status',false);}
function tmSsh(){const auth=document.querySelector('input[name="tmAuth"]:checked')?.value||'password';return{host:$('tmHost').value,port:Number($('tmPort').value||22),user:$('tmUser').value,auth,password:$('tmPassword').value,key_file:$('tmKeyFile').value,use_sudo:$('tmSudo').checked};}
async function tokenAction(action,withSsh){const idx=Number($('tmIdx').value);const body={csrf_token:SM_CSRF,action,index:idx};if(withSsh)body.ssh=tmSsh();const box=$('tmStatus');box.className='alert alert-info py-2';box.textContent=action==='token_rotate'?'Token wird rotiert ...':action==='token_sync'?'Token wird via SSH synchronisiert ...':'Token wird geprüft ...';try{const j=await api('server_management.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});box.className='alert '+((j.api||{}).ok?'alert-success':'alert-warning')+' py-2';box.innerHTML=(j.message?'<div class="fw-semibold mb-1">'+esc(j.message)+'</div>':'')+tokenStatusHtml(j);const st=$('tokenState'+idx);if(st){st.className='sm-token-state '+((j.api||{}).ok?'sm-token-ok':'sm-token-bad');st.textContent=tokenStatusText(j);}return j;}catch(e){box.className='alert alert-danger py-2';box.textContent=e.message;}}
function lifecycleManage(i){const s=data[i];$('lcIdx').value=i;$('lcServer').textContent=s.name+' · '+s.url;try{const u=new URL(s.url);$('lcHost').value=u.hostname;}catch(e){$('lcHost').value='';}$('lcPort').value=22;$('lcUser').value='root';$('lcPassword').value='';$('lcStatus').className='alert alert-secondary py-2';$('lcStatus').textContent='Agent Lifecycle für '+s.name+'.';lifecycleModal.show();}
function lcSsh(){const auth=document.querySelector('input[name="lcAuth"]:checked')?.value||'password';return{host:$('lcHost').value,port:Number($('lcPort').value||22),user:$('lcUser').value,auth,password:$('lcPassword').value,key_file:$('lcKeyFile').value,use_sudo:$('lcSudo').checked};}
function toggleLcAuth(){const a=document.querySelector('input[name="lcAuth"]:checked')?.value||'password';$('lcPasswordWrap').classList.toggle('d-none',a!=='password');$('lcKeyWrap').classList.toggle('d-none',a!=='key');}
async function lifecycleAction(mode){const idx=Number($('lcIdx').value);const box=$('lcStatus');const labels={update:'Agent wird aktualisiert; Host-Identität und Remote-Einstellungen bleiben erhalten ...',repair:'Agent wird repariert und erneut ausgerollt; Remote-Einstellungen bleiben soweit möglich erhalten ...',reset:'Agent wird auf die aktuellen zentralen Defaults zurückgesetzt ...'};box.className='alert alert-info py-2';box.textContent=labels[mode]||'Agent-Aktion läuft ...';const body={csrf_token:SM_CSRF,action:'agent_repair',mode,index:idx,ssh:lcSsh()};try{const j=await api('server_management.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});box.className='alert '+((j.api||{}).ok?'alert-success':'alert-warning')+' py-2';box.innerHTML=(j.message?'<div class="fw-semibold mb-1">'+esc(j.message)+'</div>':'')+tokenStatusHtml(j);const st=$('tokenState'+idx);if(st){st.className='sm-token-state '+((j.api||{}).ok?'sm-token-ok':'sm-token-bad');st.textContent=tokenStatusText(j);}return j;}catch(e){box.className='alert alert-danger py-2';box.textContent=e.message;}}
function toggleTmAuth(){const a=document.querySelector('input[name="tmAuth"]:checked')?.value||'password';$('tmPasswordWrap').classList.toggle('d-none',a!=='password');$('tmKeyWrap').classList.toggle('d-none',a!=='key');}

$('newBtn').onclick=create;$('refresh').onclick=load;$('saveBtn').onclick=save;$('deleteBtn').onclick=del;$('tmCheck').onclick=()=>tokenAction('token_status',false);$('tmSync').onclick=()=>tokenAction('token_sync',true);$('tmRotate').onclick=()=>{if(confirm('Agent-Token wirklich rotieren? Der Agent wird neu gestartet.'))tokenAction('token_rotate',true)};$('lcUpdate').onclick=()=>{if(confirm('Agent aktualisieren? Agent-Code wird neu ausgerollt; Host-ID, Token und Remote-Einstellungen bleiben erhalten.'))lifecycleAction('update')};$('lcRepair').onclick=()=>{if(confirm('Agent reparieren? Agent-Dateien und Service werden erneut ausgerollt; Remote-Einstellungen bleiben soweit möglich erhalten.'))lifecycleAction('repair')};$('lcReset').onclick=()=>{if(confirm('ACHTUNG: Agent wirklich auf zentrale Defaults zurücksetzen? Remote-Agent-Konfiguration und managed_configs.json werden bewusst zurückgesetzt.'))lifecycleAction('reset')};document.querySelectorAll('input[name="tmAuth"]').forEach(x=>x.addEventListener('change',toggleTmAuth));document.querySelectorAll('input[name="lcAuth"]').forEach(x=>x.addEventListener('change',toggleLcAuth));load();
</script></body></html>
