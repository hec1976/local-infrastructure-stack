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

function ms_json(array $x,int $s=200):never{http_response_code($s);header('Content-Type: application/json; charset=utf-8');header('Cache-Control:no-store');echo json_encode($x,JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);exit;}
function ms_servers():array{return cm_load_config_manager_servers(__DIR__.'/../config/config.php');}
function ms_ctl(array $server):ConfigManagerController{return new ConfigManagerController(new ConfigManagerService(new ConfigManagerRepository($server)));}
function ms_body():array{$x=json_decode((string)file_get_contents('php://input'),true);if(!is_array($x))throw new InvalidArgumentException('Ungültiges JSON.');return $x;}
function ms_find(array $servers,string $name):array{foreach($servers as $s)if(strcasecmp((string)$s['name'],$name)===0)return $s;throw new RuntimeException('Unbekannter oder inzwischen entfernter Server.',404);}
function ms_unwrap(array $r):array{$code=(int)($r['http_code']??500);$x=is_array($r['response']??null)?$r['response']:[];if($code<200||$code>=300||empty($x['ok']))throw new RuntimeException((string)($x['error']??('Agent HTTP '.$code)),$code>=400&&$code<=599?$code:502);return $x;}
function ms_loki_get(string $path,array $params=[]):array{
 $base=rtrim((string)(getenv('TEKO_LOKI_QUERY_URL')?:'http://127.0.0.1:3100'),'/');
 $url=$base.$path.($params?('?'.http_build_query($params,'','&',PHP_QUERY_RFC3986)):'');
 $raw=false;$status=0;
 if(function_exists('curl_init')){
  $ch=curl_init($url);curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_CONNECTTIMEOUT=>2,CURLOPT_TIMEOUT=>8,CURLOPT_HTTPHEADER=>['Accept: application/json']]);
  $raw=curl_exec($ch);$status=(int)curl_getinfo($ch,CURLINFO_HTTP_CODE);$err=curl_error($ch);curl_close($ch);
  if($raw===false)throw new RuntimeException('Loki nicht erreichbar: '.$err,502);
 }else{
  $ctx=stream_context_create(['http'=>['method'=>'GET','timeout'=>8,'ignore_errors'=>true,'header'=>"Accept: application/json\r\n"]]);
  $raw=@file_get_contents($url,false,$ctx);
  foreach(($http_response_header??[]) as $h)if(preg_match('~^HTTP/\\S+\\s+(\\d+)~',$h,$m)){$status=(int)$m[1];break;}
  if($raw===false)throw new RuntimeException('Loki nicht erreichbar.',502);
 }
 if($status<200||$status>=300)throw new RuntimeException('Loki HTTP '.$status.'.',502);
 $j=json_decode((string)$raw,true);if(!is_array($j)||($j['status']??'')!=='success')throw new RuntimeException('Ungültige Loki-Antwort.',502);return $j;
}
function ms_bracket(string $line,string $key):string{
 if(preg_match('/\\['.preg_quote($key,'/').' "((?:\\\\.|[^"])*)"\\]/',$line,$m))return stripcslashes($m[1]);return '';
}
function ms_parse_event_line(string $line,string $ts):?array{
 $rid=ms_bracket($line,'id');if($rid===''||!preg_match('/^\\d{5,7}$/',$rid))return null;
 $msg=ms_bracket($line,'msg');$severity=strtoupper(ms_bracket($line,'severity'));$host=ms_bracket($line,'hostname');$uri=ms_bracket($line,'uri');$uid=ms_bracket($line,'unique_id');$data=ms_bracket($line,'data');
 $target='';if(preg_match('/\\bat\\s+([A-Z][A-Z0-9_]*(?:\\\\?:[A-Za-z0-9_.-]+)?)\\.?/',$line,$m))$target=rtrim(str_replace('\\\\:',':',$m[1]),'.');
 $attack='';if(preg_match('/\\[tag "attack-([a-z0-9_-]+)"\\]/i',$line,$m))$attack=strtolower($m[1]);
 $sec=(int)substr($ts,0,10);$ns=(int)$ts;$ms=(int)(($ns%1000000000)/1000000);
 return ['timestamp_ns'=>$ts,'time'=>date('Y-m-d H:i:s',$sec).sprintf('.%03d',$ms),'epoch'=>$sec,'rule_id'=>$rid,'message'=>$msg,'severity'=>$severity?:'UNKNOWN','host'=>$host,'uri'=>$uri,'target'=>$target,'attack_type'=>$attack,'data'=>$data,'unique_id'=>$uid,'raw'=>$line];
}
function ms_custom_next_id(string $content):int{
 preg_match_all("/\\bid\\s*:\s*['\"]?(10\\d{5,6})/",$content,$m);
 $used=array_map('intval',$m[1]??[]);$id=1001000;
 while(in_array($id,$used,true)&&$id<=1009999)$id++;
 if($id>1009999)throw new RuntimeException('Keine freie Custom Rule-ID im Bereich 1001000-1009999.',409);
 return $id;
}
function ms_generate_exclusion(array $e,string $custom):array{
 $rid=trim((string)($e['rule_id']??''));$host=trim((string)($e['host']??''));$uri=trim((string)($e['uri']??''));
 $method=strtoupper(trim((string)($e['method']??'')));$target=trim((string)($e['target']??''));$comment=trim((string)($e['message']??'False Positive'));
 if(!preg_match('/^\\d{5,7}$/',$rid))throw new InvalidArgumentException('Ungültige CRS Rule-ID.');
 if($host===''||!preg_match('/^[A-Za-z0-9._:-]+$/',$host))throw new InvalidArgumentException('Host fehlt oder ist ungültig.');
 if($uri===''||$uri[0]!=='/'||preg_match('/[\\r\\n\"]/', $uri))throw new InvalidArgumentException('URI fehlt oder ist ungültig.');
 if($method!==''&&!in_array($method,['GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS'],true))throw new InvalidArgumentException('HTTP-Methode ist ungültig.');
 $targetOk=$target!==''&&preg_match('/^(?:ARGS|ARGS_NAMES|REQUEST_HEADERS|REQUEST_COOKIES)(?::[A-Za-z0-9_.-]+)?$|^(?:REQUEST_FILENAME|REQUEST_URI|REQUEST_BASENAME)$/',$target);
 $strategy=$targetOk?'target':'endpoint';
 $risk=$targetOk?'LOW':'MEDIUM';
 $id=ms_custom_next_id($custom);
 $cleanHost=preg_replace('/:\\d+$/','',$host);$hostRx='^'.preg_quote((string)$cleanHost,'/').'(?::[0-9]+)?$';
 $comment=preg_replace('/[\\r\\n#]+/',' ', $comment)?:'False Positive';
 $lines=[
  '# ------------------------------------------------------------------',
  '# CM-FP: '.$comment,
  '# CRS '.$rid.' | '.$host.' | '.$uri.($targetOk?' | '.$target:''),
  '# Strategy: '.$strategy.' | Risk: '.$risk,
  '# CM-FP-STATUS: active',
  '# CM-FP-VALIDATED: yes',
  '# CM-FP-CREATED: '.gmdate('Y-m-d\TH:i:s\Z'),
  '# CM-FP-MATCH: rule='.$rid.' | host='.$host.' | uri='.$uri.' | method='.($method!==''?$method:'*').' | target='.($targetOk?$target:'*'),
  '# ------------------------------------------------------------------',
  'SecRule REQUEST_HEADERS:Host "@rx '.$hostRx.'" \\',
  '    "id:'.$id.',phase:1,pass,nolog,chain"',
  '    SecRule REQUEST_URI "@streq '.str_replace('"','\\"',$uri).'" \\',
 ];
 $ctl=$targetOk?'ctl:ruleRemoveTargetById='.$rid.';'.$target:'ctl:ruleRemoveById='.$rid;
 if($method!==''){$lines[]='        "chain"';$lines[]='        SecRule REQUEST_METHOD "@streq '.$method.'" \\';$lines[]='            "'.$ctl.'"';}
 else{$lines[]='        "'.$ctl.'"';}
 return ['rule'=>implode("\n",$lines),'custom_id'=>$id,'strategy'=>$strategy,'risk'=>$risk,'scope'=>['rule_id'=>$rid,'host'=>$host,'uri'=>$uri,'method'=>$method,'target'=>$targetOk?$target:'','target_supported'=>(bool)$targetOk]];
}
function ms_is_meta_rule(string $rid):bool{
 // CRS correlation / anomaly summary rules must never be tuned directly.
 // The concrete detecting rule in the same transaction is the actionable one.
 return in_array($rid,['949110','959100','980130','980140','980170','980180'],true);
}
function ms_root_priority(array $e):int{
 $rid=(string)($e['rule_id']??'');
 if(ms_is_meta_rule($rid))return -100;
 $score=0;
 if((string)($e['target']??'')!=='')$score+=40;
 if((string)($e['attack_type']??'')!=='')$score+=30;
 if((string)($e['data']??'')!=='')$score+=10;
 if(strtoupper((string)($e['severity']??''))==='CRITICAL')$score+=5;
 // Prefer concrete request rules over generic evaluation/reporting ranges.
 $n=(int)$rid;
 if($n>=900000 && $n<949000)$score+=20;
 return $score;
}
function ms_loki_events(int $minutes,int $limit):array{
 $minutes=max(5,min(1440,$minutes));$limit=max(20,min(1000,$limit));$end=(int)(microtime(true)*1000000000);$start=$end-($minutes*60*1000000000);
 $j=null;foreach(['{service="modsecurity"} |= "[id"','{service_name="modsecurity"} |= "[id"','{job="modsecurity"} |= "[id"'] as $query){$candidate=ms_loki_get('/loki/api/v1/query_range',['query'=>$query,'start'=>(string)$start,'end'=>(string)$end,'limit'=>(string)$limit,'direction'=>'backward']);if(!empty($candidate['data']['result'])){$j=$candidate;break;}}
 if($j===null)$j=['data'=>['result'=>[]]];
 $rows=[];foreach((array)($j['data']['result']??[]) as $stream){foreach((array)($stream['values']??[]) as $v){if(!is_array($v)||count($v)<2)continue;$e=ms_parse_event_line((string)$v[1],(string)$v[0]);if($e)$rows[]=$e;}}
 usort($rows,fn($a,$b)=>strcmp((string)$b['timestamp_ns'],(string)$a['timestamp_ns']));

 // Enrich duplicate Message/Apache-Error copies before transaction correlation.
 // The plain "Message:" copy often has no hostname/uri/unique_id while the
 // Apache-Error copy of the same rule and timestamp does.  Merge that request
 // context first so anonymous duplicates do not leak into the Security Events UI.
 $ctx=[];foreach($rows as $e){
   $k=(string)$e['timestamp_ns'].'|'.(string)$e['rule_id'];
   if(!isset($ctx[$k]))$ctx[$k]=['host'=>'','uri'=>'','target'=>'','unique_id'=>'','attack_type'=>''];
   foreach(['host','uri','target','unique_id','attack_type'] as $f)if($ctx[$k][$f]===''&&(string)($e[$f]??'')!=='')$ctx[$k][$f]=(string)$e[$f];
 }
 foreach($rows as &$e){$k=(string)$e['timestamp_ns'].'|'.(string)$e['rule_id'];foreach(['host','uri','target','unique_id','attack_type'] as $f)if((string)($e[$f]??'')===''&&($ctx[$k][$f]??'')!=='')$e[$f]=$ctx[$k][$f];}
 unset($e);

 // Correlate all CRS messages belonging to the same ModSecurity transaction.
 // Summary/anomaly rules are technical context only.  The actionable detecting
 // rules are returned with their correlated summary IDs and are the only rows
 // shown in the normal Security Events view.
 $tx=[];foreach($rows as $e){$uid=(string)($e['unique_id']??'');if($uid!=='')$tx[$uid][]=$e;}
 foreach($rows as &$e){
   $rid=(string)$e['rule_id'];$e['meta_rule']=ms_is_meta_rule($rid);$e['actionable']=!$e['meta_rule'];$e['root_event']=null;$e['summary_rules']=[];
   $uid=(string)($e['unique_id']??'');
   if($uid!==''&&!empty($tx[$uid])){
     $summary=[];foreach($tx[$uid] as $x){$xr=(string)($x['rule_id']??'');if(ms_is_meta_rule($xr))$summary[$xr]=true;}
     $e['summary_rules']=array_keys($summary);sort($e['summary_rules'],SORT_STRING);
     if($e['meta_rule']){
       $cand=array_values(array_filter($tx[$uid],fn($x)=>!ms_is_meta_rule((string)($x['rule_id']??''))));
       if($cand){usort($cand,fn($a,$b)=>ms_root_priority($b)<=>ms_root_priority($a));$e['root_event']=$cand[0];}
     }
   }
 }
 unset($e);

 // Collapse duplicate "Message" + "Apache-Error" copies. Use unique_id when
 // available; this keeps different concrete rules from the same request apart.
 $groups=[];foreach($rows as $e){
   $uid=(string)($e['unique_id']??'');$bucket=(string)$e['epoch'];
   $key=$e['rule_id'].'|'.($uid!==''?$uid:$bucket.'|'.substr(sha1($e['data'].'|'.$e['message']),0,14));
   if(!isset($groups[$key])){$e['count']=1;$groups[$key]=$e;continue;}
   $groups[$key]['count']++;
   foreach(['host','uri','target','attack_type','unique_id'] as $f)if($groups[$key][$f]===''&&$e[$f]!=='')$groups[$key][$f]=$e[$f];
   if(strlen($e['raw'])>strlen($groups[$key]['raw']))$groups[$key]['raw']=$e['raw'];
   if(empty($groups[$key]['root_event'])&&!empty($e['root_event']))$groups[$key]['root_event']=$e['root_event'];
 }
 $out=array_values($groups);usort($out,fn($a,$b)=>strcmp((string)$b['timestamp_ns'],(string)$a['timestamp_ns']));return array_slice($out,0,$limit);
}

try{
 $servers=ms_servers();
 if(($_GET['api']??'')==='summary'){
  ms_json(['ok'=>true,'servers'=>array_map(fn($s)=>['name'=>(string)$s['name'],'groups'=>array_values((array)($s['groups']??[])),'labels'=>(array)($s['labels']??[])],$servers)]);
 }
 if(($_GET['api']??'')==='load'){
  $name=trim((string)($_GET['server']??''));$srv=ms_find($servers,$name);$ctl=ms_ctl($srv);
  ms_json(['ok'=>true,'server'=>$name,'info'=>ms_unwrap($ctl->getModSecurityInfo()),'config'=>ms_unwrap($ctl->getModSecurityConfig())]);
 }
 if(($_GET['api']??'')==='rules'){
  $name=trim((string)($_GET['server']??''));$srv=ms_find($servers,$name);$ctl=ms_ctl($srv);
  ms_json(['ok'=>true,'server'=>$name,'rules'=>ms_unwrap($ctl->getModSecurityRules())]);
 }
 if(($_GET['api']??'')==='custom'){
  $name=trim((string)($_GET['server']??''));$srv=ms_find($servers,$name);$ctl=ms_ctl($srv);
  ms_json(['ok'=>true,'server'=>$name,'custom'=>ms_unwrap($ctl->getModSecurityCustomRules())]);
 }
 if(($_GET['api']??'')==='events'){
  $minutes=(int)($_GET['minutes']??60);$limit=(int)($_GET['limit']??300);
  ms_json(['ok'=>true,'events'=>ms_loki_events($minutes,$limit),'minutes'=>max(5,min(1440,$minutes))]);
 }
 if($_SERVER['REQUEST_METHOD']==='POST'){
  $in=ms_body();if(!hash_equals($csrf,(string)($in['csrf_token']??'')))throw new RuntimeException('CSRF fehlgeschlagen.',403);
  $name=trim((string)($in['server_name']??''));$srv=ms_find($servers,$name);$ctl=ms_ctl($srv);$action=(string)($in['action']??'');
  if($action==='install'){
    if(empty($in['confirm_install']))throw new RuntimeException('Installation muss explizit bestätigt werden.',400);
    $result=ms_unwrap($ctl->installModSecurity());
    mmbb_audit_write('modsecurity_install',$name,['server'=>$name],'modsecurity.php','ok');
    ms_json(['ok'=>true,'result'=>$result]);
  }
  if($action==='save'){
    $cfg=is_array($in['config']??null)?$in['config']:[];
    $result=ms_unwrap($ctl->saveModSecurityConfig($cfg));
    mmbb_audit_write('modsecurity_config',$name,['server'=>$name,'rule_engine'=>$cfg['rule_engine']??'','audit_engine'=>$cfg['audit_engine']??'','excluded_rule_ids'=>$cfg['excluded_rule_ids']??[]],'modsecurity.php','ok');
    ms_json(['ok'=>true,'result'=>$result]);
  }
  if($action==='generate_exclusion'){
    $event=is_array($in['event']??null)?$in['event']:[];
    $cur=ms_unwrap($ctl->getModSecurityCustomRules());$content=(string)($cur['content']??'');
    $gen=ms_generate_exclusion($event,$content);
    ms_json(['ok'=>true,'generated'=>$gen]);
  }
  if($action==='activate_exclusion'){
    $event=is_array($in['event']??null)?$in['event']:[];
    $cur=ms_unwrap($ctl->getModSecurityCustomRules());$content=(string)($cur['content']??'');
    $gen=ms_generate_exclusion($event,$content);
    $next=rtrim($content).($content!==''?"\n\n":'').$gen['rule']."\n";
    $result=ms_unwrap($ctl->saveModSecurityCustomRules($next));
    mmbb_audit_write('modsecurity_false_positive_activate',$name,['server'=>$name,'rule_id'=>$gen['scope']['rule_id'],'custom_id'=>$gen['custom_id'],'host'=>$gen['scope']['host'],'uri'=>$gen['scope']['uri'],'target'=>$gen['scope']['target'],'strategy'=>$gen['strategy']],'modsecurity.php','ok');
    ms_json(['ok'=>true,'generated'=>$gen,'result'=>$result]);
  }
  if($action==='save_custom'){
    $content=(string)($in['content']??'');
    $result=ms_unwrap($ctl->saveModSecurityCustomRules($content));
    mmbb_audit_write('modsecurity_custom_rules',$name,['server'=>$name,'bytes'=>strlen($content)],'modsecurity.php','ok');
    ms_json(['ok'=>true,'result'=>$result]);
  }
  throw new InvalidArgumentException('Unbekannte Aktion.');
 }
}catch(Throwable $e){$c=(int)$e->getCode();if($c<400||$c>599)$c=400;if(isset($_GET['api'])||$_SERVER['REQUEST_METHOD']==='POST')ms_json(['ok'=>false,'error'=>$e->getMessage()],$c);$pageError=$e->getMessage();}
?>
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ModSecurity / OWASP CRS</title>
<?php require MMBB_UI.'/includes/css.php'; ?>
<link rel="stylesheet" href="assets/css/modsecurity.css?v=3.5.2">
<style>.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}</style></head><body>
<?php require MMBB_UI.'/navigation.php';require MMBB_UI.'/sidebar.php';?>
<div class="container mmbb-main py-3 mmbb-page"><?php require MMBB_UI.'/module_header.php';?>

<div id="msg" class="alert d-none teko-status-alert"></div>
<div class="alert alert-secondary py-2"><strong>Lokale Komponente:</strong> ModSecurity / OWASP CRS wird direkt auf dem ausgewählten Webserver verwaltet.</div>
<section class="teko-workspace ms-console">
  <div class="teko-commandbar">
    <div class="teko-server-field">
      <label class="form-label" for="server">Zielserver</label>
      <select id="server" class="form-select form-select-sm"></select>
    </div>
    <div class="teko-actions">
      <button id="load" class="btn btn-outline-secondary btn-sm"><i class="bi bi-arrow-clockwise me-1"></i>Status laden</button>
      <button id="install" class="btn btn-primary btn-sm"><i class="bi bi-shield-plus me-1"></i>ModSecurity + OWASP CRS installieren</button>
    </div>
    <div class="ms-auto teko-help d-none d-xl-block">Native Paketnamen je Distribution; Apache wird vor jedem Reload geprüft.</div>
  </div>

  <div class="ms-statusbar">
    <div class="ms-status-main"><span class="ms-status-dot"></span><strong id="effectiveMode">—</strong><span class="text-muted">Runtime</span></div>
    <div class="ms-status-item"><span>ModSecurity</span><strong id="installed">—</strong></div>
    <div class="ms-status-item"><span>Apache</span><strong id="module">—</strong></div>
    <div class="ms-status-item"><span>OWASP CRS</span><strong id="crs">—</strong></div>
    <div class="ms-status-item"><span>Paketmanager</span><strong id="manager">—</strong></div>
    <div class="ms-status-item"><span>Abhängigkeiten</span><strong id="dependencyState">—</strong></div>
    <button id="runtimeToggle" class="btn btn-outline-secondary btn-sm ms-auto" type="button"><i class="bi bi-diagram-3 me-1"></i>Runtime-Details</button>
  </div>

  <div id="dependencyPanel" class="ms-runtime-details d-none mb-3">
    <div class="fw-semibold mb-1"><i class="bi bi-diagram-3 me-1"></i>ModSecurity Runtime / Abhängigkeiten</div>
    <div id="dependencySummary" class="small"></div>
    <div id="dependencyList" class="small mt-2"></div>
  </div>

  <div class="teko-section">
    <ul class="nav nav-tabs ms-tabs" role="tablist">
      <li class="nav-item"><button id="eventsTab" class="nav-link active" data-bs-toggle="tab" data-bs-target="#waf-events" type="button"><i class="bi bi-radar me-1"></i>Security Events <span id="eventCount" class="badge text-bg-danger ms-1">0</span></button></li>
      <!-- Ausnahmen & Custom Rules -->
      <li class="nav-item"><button id="customTab" class="nav-link" data-bs-toggle="tab" data-bs-target="#waf-custom" type="button"><i class="bi bi-shield-check me-1"></i>Ausnahmen <span id="customCount" class="badge text-bg-primary ms-1">0</span></button></li>
      <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#waf-config" type="button"><i class="bi bi-sliders me-1"></i>WAF-Konfiguration</button></li>
      <li class="nav-item"><button id="rulesTab" class="nav-link" data-bs-toggle="tab" data-bs-target="#waf-rules" type="button"><i class="bi bi-list-check me-1"></i>CRS-Regeln <span id="ruleCount" class="badge text-bg-secondary ms-1">0</span></button></li>
      <li class="nav-item"><button id="expertTab" class="nav-link" data-bs-toggle="tab" data-bs-target="#waf-expert" type="button"><i class="bi bi-code-square me-1"></i>Expertenmodus</button></li>
    </ul>
    <div class="tab-content">
      <div id="waf-events" class="tab-pane fade show active">
        <div class="ms-event-hero mb-3">
          <div><div class="ms-kicker">Loki / ModSecurity</div><div class="ms-panel-title">Security Events</div><div class="ms-panel-sub">Treffer prüfen und mit einem Klick eine eng begrenzte Ausnahme automatisch erzeugen und aktivieren.</div></div>
          <div class="ms-toolbar">
            <select id="eventWindow" class="form-select form-select-sm" style="width:auto"><option value="15">15 Minuten</option><option value="60" selected>1 Stunde</option><option value="360">6 Stunden</option><option value="1440">24 Stunden</option></select>
            <button id="reloadEvents" class="btn btn-primary btn-sm"><i class="bi bi-arrow-clockwise me-1"></i>Events laden</button>
          </div>
        </div>
        <div class="ms-event-stats mb-3"><div class="ms-event-stat"><span>Events</span><strong id="evTotal">0</strong></div><div class="ms-event-stat"><span>CRITICAL</span><strong id="evCritical">0</strong></div><div class="ms-event-stat"><span>Rule-IDs</span><strong id="evRules">0</strong></div><div class="ms-event-stat"><span>bereits getunt</span><strong id="evTuned">0</strong></div><div class="ms-event-stat"><span>Top Rule</span><strong id="evTopRule" class="mono">—</strong></div><div class="ms-event-stat"><span>Top Typ</span><strong id="evTopType">—</strong></div></div>
        <div class="ms-panel">
          <div class="ms-panel-head"><div><div class="ms-panel-title">Aktuelle CRS-Treffer</div><div class="ms-panel-sub">Nur konkrete, tunbare CRS-Ursachen. Summary-/Anomaly-Regeln werden automatisch korreliert und aus der Hauptliste ausgeblendet. <span id="eventRawInfo"></span></div></div><div class="ms-toolbar"><input id="eventSearch" class="form-control form-control-sm" style="min-width:280px" placeholder="Rule, Host, URI, Target, Meldung …"><select id="eventStatus" class="form-select form-select-sm" style="width:auto"><option value="all">Alle</option><option value="new">Nur neu</option><option value="tuned">Nur getunt</option></select></div></div>
          <div class="table-responsive ms-events-table-wrap"><table class="table table-sm align-middle table-hover ms-events-table mb-0"><thead><tr><th>Zeit</th><th>Status</th><th>Severity</th><th>Rule</th><th>Typ</th><th>Host / URI</th><th>Target</th><th>Treffer</th><th></th></tr></thead><tbody id="eventsBody"><tr><td colspan="9" class="text-center text-muted py-4">Events noch nicht geladen.</td></tr></tbody></table></div>
        </div>
      </div>

      <div id="waf-custom" class="tab-pane fade">
        <div class="ms-workflow compact">
          <div class="ms-step"><div class="ms-step-num">1</div><div><strong>Event wählen</strong><span>direkt aus Loki</span></div></div>
          <div class="ms-step"><div class="ms-step-num">2</div><div><strong>Scope erkennen</strong><span>Rule, Host, URI, Target</span></div></div>
          <div class="ms-step"><div class="ms-step-num">3</div><div><strong>Rule bauen</strong><span>Syntax automatisch</span></div></div>
          <div class="ms-step"><div class="ms-step-num">4</div><div><strong>Aktivieren</strong><span>Configtest + Reload + Rollback</span></div></div>
        </div>
        <div class="ms-auto-grid">
          <div class="ms-panel">
            <div class="ms-panel-head"><div><div class="ms-kicker">Automatischer Rule Builder</div><div class="ms-panel-title">Ausnahme automatisch erzeugen</div><div class="ms-panel-sub">Der Config Manager entscheidet selbst zwischen Target-Ausnahme und Endpoint-Ausnahme. Keine ModSecurity-Syntax nötig. Keine freie ModSecurity-/Apache-Syntax im Standardworkflow.</div></div><span class="ms-health"><i class="bi bi-magic"></i>Auto</span></div>
            <div class="ms-panel-body">
              <div id="selectedEventCard" class="ms-selected-event"><div class="ms-empty">Noch kein Security Event ausgewählt. Im Tab <strong>Security Events</strong> auf „Ausnahme bauen“ klicken.</div></div>
              <details class="mt-3"><summary class="small fw-semibold">Manueller Event-Import / Parser-Fallback</summary><div class="mt-2"><textarea id="eventPaste" class="form-control mono ms-event-input" spellcheck="false" placeholder='Message: Warning. ... [id "930120"] ... [hostname "teko.local"] [uri "/configs_editor.php"]'></textarea><div class="ms-toolbar mt-2"><button id="parseEvent" class="btn btn-outline-primary btn-sm"><i class="bi bi-magic me-1"></i>Event analysieren</button><button id="clearEvent" class="btn btn-outline-secondary btn-sm">Leeren</button><span id="parseState" class="small text-muted ms-auto"></span></div></div></details>
              <div class="ms-form-grid mt-3 ms-correction-grid">
                <div><label class="form-label" for="exRuleId">CRS Rule-ID</label><input id="exRuleId" class="form-control form-control-sm mono" inputmode="numeric"></div>
                <div><label class="form-label" for="exMethod">HTTP-Methode</label><select id="exMethod" class="form-select form-select-sm"><option value="">nicht erkannt / alle</option><option>GET</option><option>POST</option><option>PUT</option><option>PATCH</option><option>DELETE</option><option>HEAD</option><option>OPTIONS</option></select></div>
                <div><label class="form-label" for="exHost">Host</label><input id="exHost" class="form-control form-control-sm mono"></div>
                <div><label class="form-label" for="exUri">URI</label><input id="exUri" class="form-control form-control-sm mono"></div>
                <div class="full"><label class="form-label" for="exTarget">Target</label><input id="exTarget" class="form-control form-control-sm mono" placeholder="wird automatisch erkannt"></div>
                <div class="full"><label class="form-label" for="exComment">Bezeichnung</label><input id="exComment" class="form-control form-control-sm"></div>
                <select id="exMode" class="d-none"><option value="target">auto</option><option value="endpoint">endpoint</option></select>
              </div>
              <div class="d-flex flex-wrap gap-2 mt-3"><button id="buildExclusion" type="button" class="btn btn-primary btn-sm"><i class="bi bi-gear-wide-connected me-1"></i>Rule automatisch bauen</button><button id="activateExclusion" type="button" class="btn btn-success btn-sm" disabled><i class="bi bi-shield-check me-1"></i>Ausnahme aktivieren</button><button id="appendExclusion" type="button" class="btn btn-outline-secondary btn-sm" disabled>Nur in Experteneditor übernehmen</button></div><div id="builderState" class="small mt-2 text-muted">Event wählen – die Ausnahme wird danach automatisch erzeugt.</div>
            </div>
          </div>
          <div class="ms-panel">
            <div class="ms-panel-head"><div><div class="ms-panel-title">Scope & technische Vorschau</div><div class="ms-panel-sub">Die Rule wird serverseitig erzeugt; globale Deaktivierungen sind nicht zulässig.</div></div><span id="riskBadge" class="ms-risk ms-risk-low">noch offen</span></div>
            <div class="ms-panel-body"><div id="scopePreview" class="ms-scope-card mb-2"><div class="text-muted">Noch keine Rule erzeugt.</div></div><details id="technicalPreview"><summary class="small fw-semibold">Generierte ModSecurity-Syntax anzeigen</summary><pre id="rulePreview" class="ms-preview mt-2"><span class="ms-preview-empty">Hier erscheint die automatisch erzeugte Ausnahme.</span></pre></details></div>
          </div>
        </div>
        <div class="ms-panel mt-3"><div class="ms-panel-head"><div><div class="ms-panel-title">Aktive Ausnahmen</div><div class="ms-panel-sub">Verwaltete Ausnahmen mit Status und Validierungsstand aus der separaten Custom-Rules-Datei.</div></div><button id="reloadCustom" class="btn btn-outline-secondary btn-sm"><i class="bi bi-arrow-clockwise me-1"></i>Neu laden</button></div><div class="ms-panel-body"><div id="managedExclusions" class="ms-managed-list"><div class="ms-empty">Noch keine Daten geladen.</div></div></div></div>
        <div class="alert alert-info py-2 small mt-3"><i class="bi bi-shield-check me-1"></i><strong>Sicherheitsprinzip:</strong> Der Assistent erzeugt nur begrenzte Ausnahmen für einen konkreten Host und URI. Globale CRS-Deaktivierungen werden nicht automatisch erzeugt.</div>
      </div>

      <div id="waf-config" class="tab-pane fade">
        <div class="teko-section-title"><i class="bi bi-sliders me-1"></i>WAF-Konfiguration</div>
        <div class="row g-2"><div class="col-lg-4"><div class="ms-config-card"><label class="form-label">Rule Engine</label><select id="engine" class="form-select form-select-sm"><option>DetectionOnly</option><option>On</option><option>Off</option></select></div></div><div class="col-lg-4"><div class="ms-config-card"><label class="form-label">Audit Engine</label><select id="audit" class="form-select form-select-sm"><option>RelevantOnly</option><option>On</option><option>Off</option></select></div></div><div class="col-lg-4"><div class="ms-config-card"><label class="form-label">Request Body Limit (Bytes)</label><input id="limit" type="number" min="1048576" max="1073741824" class="form-control form-control-sm" value="134217728"></div></div><div class="col-md-6"><div class="form-check mt-2"><input id="req" type="checkbox" class="form-check-input"><label class="form-check-label" for="req">Request Body Inspection</label></div></div><div class="col-md-6"><div class="form-check mt-2"><input id="resp" type="checkbox" class="form-check-input"><label class="form-check-label" for="resp">Response Body Inspection</label></div></div><div class="col-12 mt-2"><details class="border rounded p-2 bg-light-subtle"><summary class="fw-semibold" style="cursor:pointer">Erweitert: Bulk-Ausnahmen</summary><div class="mt-2"><label class="form-label" for="ids">Mehrere Rule-IDs deaktivieren</label><input id="ids" class="form-control form-control-sm mono" placeholder="942100, 949110"><div class="form-text">Im Normalfall Regeln direkt im Tab „CRS-Regeln“ aktivieren/deaktivieren. Für False Positives den automatischen Rule Builder verwenden.</div></div></details></div></div>
        <div class="d-flex flex-wrap align-items-center gap-2 mt-3"><button id="save" class="btn btn-success btn-sm"><i class="bi bi-check2-circle me-1"></i>Prüfen, speichern & Apache reload</button><span class="teko-help">Bei Configtest- oder Reload-Fehler wird automatisch zurückgerollt.</span></div>
      </div>

      <div id="waf-rules" class="tab-pane fade">
        <div class="d-flex flex-wrap gap-2 align-items-end mb-2"><div class="flex-grow-1"><label class="form-label">Regeln durchsuchen</label><input id="ruleSearch" class="form-control form-control-sm" placeholder="Rule-ID, Beschreibung, Datei, Tag …"></div><div><label class="form-label">Status</label><select id="ruleFilter" class="form-select form-select-sm"><option value="all">Alle</option><option value="active">Aktiv</option><option value="disabled">Deaktiviert</option></select></div><button id="reloadRules" class="btn btn-outline-secondary btn-sm">Regeln neu laden</button></div>
        <div class="table-responsive" style="max-height:520px;overflow:auto"><table class="table table-sm table-hover align-middle ms-rule-table"><thead class="sticky-top bg-body"><tr><th>ID</th><th>Status</th><th>Typ</th><th>Phase</th><th>Severity</th><th>Beschreibung</th><th>Datei</th><th></th></tr></thead><tbody id="rulesBody"></tbody></table></div><div id="rulesInfo" class="form-text"></div>
      </div>

      <div id="waf-expert" class="tab-pane fade">
        <div class="ms-panel"><div class="ms-panel-head"><div><div class="ms-kicker">Advanced</div><div class="ms-panel-title">Expertenmodus / Raw Custom Rules</div><div class="ms-panel-sub">Direkte Bearbeitung nur für Spezialfälle. Der normale False-Positive-Workflow benötigt keine Syntaxkenntnisse.</div></div><span class="badge text-bg-warning">Expertenmodus</span></div><div class="ms-panel-body"><div class="ms-editor-wrap"><div class="ms-editor-head"><div><strong>Custom Rules</strong><div class="small text-muted">Separate Datei; CRS-Updates überschreiben sie nicht.</div></div></div><textarea id="customRules" class="form-control mono ms-editor" rows="22" spellcheck="false" placeholder="# Custom Rules"></textarea></div><div class="d-flex flex-wrap gap-2 align-items-center mt-3"><button id="saveCustom" class="btn btn-success btn-sm"><i class="bi bi-check2-circle me-1"></i>Prüfen, speichern & Apache reload</button><button id="clearCustom" class="btn btn-outline-danger btn-sm"><i class="bi bi-trash3 me-1"></i>Editor leeren</button><span class="teko-help">Configtest und Rollback erfolgen automatisch.</span></div></div></div>
      </div>
    </div>
  </div>
  </div>
</section>

<div class="modal fade" id="ruleDetailsModal" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog modal-xl modal-dialog-scrollable">
    <div class="modal-content">
      <div class="modal-header"><h5 class="modal-title" id="ruleDetailTitle">CRS Rule</h5><button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Schliessen"></button></div>
      <div class="modal-body">
        <div id="ruleDetailSummary" class="alert alert-light border fw-semibold"></div>
        <div id="ruleDetailMeta" class="row row-cols-1 row-cols-md-2 g-2 small mb-3"></div>
        <div class="mb-3"><div class="fw-semibold mb-1">Tags</div><div id="ruleDetailTags"></div></div>
        <div><div class="fw-semibold mb-1">Originale CRS-Regel</div><pre id="ruleDetailRaw" class="bg-light border rounded p-3 small mono" style="white-space:pre-wrap;max-height:420px;overflow:auto"></pre></div>
      </div>
      <div class="modal-footer"><button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Schliessen</button></div>
    </div>
  </div>
</div>

<script>
const CSRF=<?=json_encode($csrf)?>;let DATA={servers:[]},RULES=[],EVENTS=[],CUSTOM_LOADED=false,EXCLUSION_PREVIEW="",SELECTED_EVENT=null;
const $=id=>document.getElementById(id);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function api(u,o={}){
  const r=await fetch(u,{cache:'no-store',credentials:'same-origin',...o});
  const text=await r.text();
  let j={};
  try{j=text?JSON.parse(text):{}}catch(_){throw new Error(`Ungültige Serverantwort (HTTP ${r.status}).`)}
  if(!r.ok||!j.ok)throw new Error(j.error||`HTTP ${r.status}`);
  return j;
}
function msg(t,k='info'){const e=$('msg');e.textContent=t;e.className='alert alert-'+k}
function isNetworkError(e){const t=String(e?.message||e||'').toLowerCase();return e instanceof TypeError||t.includes('networkerror')||t.includes('failed to fetch')||t.includes('network request failed')}
async function waitForManager(timeoutMs=45000){
  const until=Date.now()+timeoutMs;
  let last='';
  while(Date.now()<until){
    try{await api('modsecurity.php?api=summary&_recover='+Date.now());return true}catch(e){last=String(e?.message||e);await sleep(1200)}
  }
  throw new Error('Config Manager kam nach dem Apache-Neustart nicht rechtzeitig zurück'+(last?': '+last:''));
}
function esc(v){return String(v??'').replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]))}
function excludedSet(){return new Set($('ids').value.split(/[\s,]+/).filter(Boolean).map(Number))}
function renderRules(){
  const q=$('ruleSearch').value.trim().toLowerCase(),f=$('ruleFilter').value,ex=excludedSet();
  let rows=RULES.filter(r=>{const active=!ex.has(Number(r.id));if(f==='active'&&!active)return false;if(f==='disabled'&&active)return false;const hay=[r.id,r.msg,r.file,r.tag,r.severity,r.phase].join(' ').toLowerCase();return !q||hay.includes(q)});
  $('rulesBody').innerHTML=rows.map(r=>{const active=!ex.has(Number(r.id));const kind=r.kind||'CRS-Regel';return `<tr><td class="mono fw-semibold">${r.id}</td><td><span class="badge ${active?'text-bg-success':'text-bg-secondary'}">${active?'aktiv':'aus'}</span></td><td><span class="badge ${kind==='CRS intern'?'text-bg-info':'text-bg-light border text-dark'}">${esc(kind)}</span></td><td>${esc(r.phase||'—')}</td><td>${esc(r.severity||'—')}</td><td>${esc(r.summary||r.msg||r.tag||'—')}</td><td class="mono small">${esc(r.file)}:${esc(r.line)}</td><td class="text-nowrap"><button class="btn btn-sm btn-outline-secondary me-1" data-details="${r.id}">Details</button><button class="btn btn-sm ${active?'btn-outline-danger':'btn-outline-success'}" data-rule="${r.id}">${active?'Deaktivieren':'Aktivieren'}</button></td></tr>`}).join('');
  $('rulesInfo').textContent=`${rows.length} von ${RULES.length} Regeln angezeigt. Änderungen werden erst mit „Prüfen, speichern & Apache reload“ aktiv.`;
  document.querySelectorAll('[data-rule]').forEach(b=>b.onclick=()=>toggleRule(Number(b.dataset.rule)));
  document.querySelectorAll('[data-details]').forEach(b=>b.onclick=()=>showRuleDetails(Number(b.dataset.details)));
}

function showRuleDetails(id){
  const r=RULES.find(x=>Number(x.id)===Number(id)); if(!r)return;
  $('ruleDetailTitle').textContent=`CRS Rule ${r.id}`;
  $('ruleDetailSummary').textContent=r.summary||r.msg||'Keine Beschreibung vorhanden';
  $('ruleDetailMeta').innerHTML=`<div><strong>Typ:</strong> ${esc(r.kind||'CRS-Regel')}</div><div><strong>Familie:</strong> ${esc(r.family||'—')}</div><div><strong>Phase:</strong> ${esc(r.phase||'—')}</div><div><strong>Severity:</strong> ${esc(r.severity||'—')}</div><div><strong>Version:</strong> ${esc(r.ver||'—')}</div><div><strong>Quelle:</strong> <span class="mono">${esc(r.file)}:${esc(r.line)}</span></div>`;
  const tags=Array.isArray(r.tags)?r.tags:[];
  $('ruleDetailTags').innerHTML=tags.length?tags.map(t=>`<span class="badge text-bg-light border text-dark me-1 mb-1">${esc(t)}</span>`).join(''):'<span class="text-muted">Keine Tags</span>';
  $('ruleDetailRaw').textContent=r.raw||'';
  bootstrap.Modal.getOrCreateInstance($('ruleDetailsModal')).show();
}

function toggleRule(id){let ids=[...excludedSet()];const s=new Set(ids);s.has(id)?s.delete(id):s.add(id);$('ids').value=[...s].sort((a,b)=>a-b).join(', ');renderRules()}
async function loadRules(){const j=await api('modsecurity.php?api=rules&server='+encodeURIComponent($('server').value));RULES=j.rules.rules||[];$('ruleCount').textContent=RULES.length;renderRules()}
function parseBracket(line,key){const m=String(line||'').match(new RegExp('\\['+key+'\\s+"([^"]+)"\\]','i'));return m?m[1]:''}
function eventFromForm(){return {rule_id:$('exRuleId').value.trim(),host:$('exHost').value.trim(),uri:$('exUri').value.trim(),method:$('exMethod').value.trim(),target:$('exTarget').value.trim(),message:$('exComment').value.trim()||'False Positive'}}
function showSelectedEvent(e){SELECTED_EVENT=e||null;if(!e){$('selectedEventCard').innerHTML='<div class="ms-empty">Noch kein Security Event ausgewählt. Im Tab <strong>Security Events</strong> auf „Ausnahme bauen“ klicken.</div>';return}$('selectedEventCard').innerHTML=`<div class="ms-selected-head"><div><span class="badge ${eventSeverityClass(e.severity)}">${esc(e.severity||'EVENT')}</span> <span class="mono fw-bold ms-2">Rule ${esc(e.rule_id||'—')}</span></div><span class="badge text-bg-light border">${esc(e.attack_type||'CRS')}</span></div><div class="ms-selected-grid"><div><span>Host</span><strong class="mono">${esc(e.host||'—')}</strong></div><div><span>URI</span><strong class="mono">${esc(e.uri||'—')}</strong></div><div><span>Target</span><strong class="mono">${esc(e.target||'—')}</strong></div><div><span>Meldung</span><strong>${esc(e.message||'—')}</strong></div></div>`}
function fillEvent(e){$('eventPaste').value=e.raw||'';$('exRuleId').value=e.rule_id||'';$('exHost').value=e.host||'';$('exUri').value=e.uri||'';$('exTarget').value=e.target||'';$('exMethod').value=e.method||'';$('exComment').value=(e.message?e.message+' - False Positive':'False Positive');showSelectedEvent(e)}
function parseEventLine(){
  const t=$('eventPaste').value.trim();if(!t){$('parseState').textContent='Event fehlt.';return}
  const id=parseBracket(t,'id'),host=parseBracket(t,'hostname'),uri=parseBracket(t,'uri'),msg=parseBracket(t,'msg');
  const method=(t.match(/\b(?:REQUEST_METHOD|Method:)\s*[:=]?\s*(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\b/i)||[])[1]||'';
  let target='';const direct=t.match(/\bat\s+((?:ARGS|ARGS_NAMES|REQUEST_HEADERS|REQUEST_COOKIES)(?:\\:|:)[A-Za-z0-9_.-]+|REQUEST_FILENAME|REQUEST_URI|REQUEST_BASENAME)/i);if(direct)target=direct[1].replace('\\:',':');
  const e={raw:t,rule_id:id,host,uri,target,method,message:msg||'False Positive',severity:parseBracket(t,'severity'),attack_type:(t.match(/\[tag "attack-([a-z0-9_-]+)"\]/i)||[])[1]||''};fillEvent(e);$('parseState').textContent=(id&&host&&uri)?'Event erkannt. Rule kann automatisch gebaut werden.':'Teilweise erkannt – fehlende Felder korrigieren.';
}
async function buildExclusion(showState=true){
  const e=eventFromForm();
  const state=$('builderState');
  if(!/^\d{5,7}$/.test(e.rule_id)||!e.host||!e.uri){
    EXCLUSION_PREVIEW='';$('appendExclusion').disabled=true;$('activateExclusion').disabled=true;
    const missing=[];if(!/^\d{5,7}$/.test(e.rule_id))missing.push('gültige Rule-ID');if(!e.host)missing.push('Host');if(!e.uri)missing.push('URI');
    const text='Fehlende Pflichtangaben: '+missing.join(', ')+'.';
    $('scopePreview').innerHTML='<div class="alert alert-warning py-2 mb-0">'+esc(text)+'</div>';
    $('rulePreview').textContent=text;$('riskBadge').className='ms-risk ms-risk-medium';$('riskBadge').textContent='unvollständig';
    if(state){state.className='small mt-2 text-warning';state.textContent=text}return false;
  }
  if(state){state.className='small mt-2 text-muted';state.textContent='Rule wird serverseitig erzeugt …'}
  try{
    const j=await api('modsecurity.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'generate_exclusion',server_name:$('server').value,event:e})});
    const g=j.generated||{};EXCLUSION_PREVIEW=g.rule||'';
    if(!EXCLUSION_PREVIEW)throw new Error('Server hat keine ModSecurity-Rule erzeugt.');
    $('rulePreview').textContent=EXCLUSION_PREVIEW;$('appendExclusion').disabled=false;$('activateExclusion').disabled=false;
    const sc=g.scope||{};$('scopePreview').innerHTML=`<div class="ms-scope-line"><b>CRS Rule</b><span>${esc(sc.rule_id||'—')}</span></div><div class="ms-scope-line"><b>Host</b><span>${esc(sc.host||'—')}</span></div><div class="ms-scope-line"><b>URI</b><span>${esc(sc.uri||'—')}</span></div><div class="ms-scope-line"><b>Methode</b><span>${esc(sc.method||'alle')}</span></div><div class="ms-scope-line"><b>Strategie</b><span>${esc(g.strategy==='target'?'nur betroffenes Target ausnehmen':'Rule nur auf diesem Endpoint ausnehmen')}</span></div><div class="ms-scope-line"><b>Target</b><span>${esc(sc.target||'—')}</span></div><div class="ms-scope-line"><b>Custom ID</b><span>${esc(g.custom_id||'—')}</span></div>`;
    $('riskBadge').className='ms-risk '+(g.risk==='LOW'?'ms-risk-low':'ms-risk-medium');$('riskBadge').textContent=g.risk==='LOW'?'ENG / niedrig':'ENDPOINT / mittel';
    if(state){state.className='small mt-2 text-success';state.textContent='Rule erfolgreich erzeugt. Scope prüfen und danach aktivieren.'}
    if(showState)$('parseState').textContent='Rule serverseitig erzeugt und Scope automatisch gewählt.';
    return true;
  }catch(e2){
    EXCLUSION_PREVIEW='';$('appendExclusion').disabled=true;$('activateExclusion').disabled=true;
    const text='Rule konnte nicht erzeugt werden: '+String(e2?.message||e2);
    $('scopePreview').innerHTML='<div class="alert alert-danger py-2 mb-0">'+esc(text)+'</div>';
    $('rulePreview').textContent=text;$('riskBadge').className='ms-risk ms-risk-medium';$('riskBadge').textContent='Fehler';
    if(state){state.className='small mt-2 text-danger';state.textContent=text}
    if(showState)msg(text,'danger');return false;
  }
}
function renderManagedCustom(content){
  const blocks=String(content||'').split(/(?=# ------------------------------------------------------------------\n# (?:CM|TEKO)-FP:)/g).filter(x=>/# (?:CM|TEKO)-FP:/.test(x));
  $('customCount').textContent=blocks.length;
  if(!blocks.length){$('managedExclusions').innerHTML='<div class="ms-empty"><i class="bi bi-shield-check d-block fs-4 mb-1"></i>Noch keine vom Assistenten erzeugten Ausnahmen.</div>';return}
  $('managedExclusions').innerHTML=blocks.map(b=>{
    const title=(b.match(/# (?:CM|TEKO)-FP:\s*([^\n]+)/)||[])[1]||'Ausnahme';
    const meta=(b.match(/# CRS\s+([^\n]+)/)||[])[1]||'';
    const cid=(b.match(/\bid:(10\d+)/)||[])[1]||'—';
    const state=(b.match(/# CM-FP-STATUS:\s*([^\n]+)/i)||[])[1]||'active';
    const validated=(b.match(/# CM-FP-VALIDATED:\s*([^\n]+)/i)||[])[1]||'legacy';
    const created=(b.match(/# CM-FP-CREATED:\s*([^\n]+)/i)||[])[1]||'';
    const active=state.toLowerCase()==='active';
    const statusBadge=active?'<span class="badge text-bg-success">aktiv</span>':'<span class="badge text-bg-secondary">deaktiviert</span>';
    const validBadge=validated.toLowerCase()==='yes'?'<span class="badge text-bg-light border text-success">geprüft</span>':'<span class="badge text-bg-light border">legacy</span>';
    return `<div class="ms-managed-item"><div class="d-flex justify-content-between gap-2"><div class="title"><i class="bi bi-shield-check text-success me-1"></i>${esc(title)}</div><span class="badge text-bg-light border mono">${esc(cid)}</span></div><div class="meta">${esc(meta)}</div><div class="d-flex gap-1 align-items-center mt-2">${statusBadge}${validBadge}${created?'<span class="small text-muted ms-1">'+esc(created)+'</span>':''}</div></div>`
  }).join('');
}
function msNormHost(v){return String(v||'').trim().toLowerCase().replace(/:\d+$/,'')}
function msNormUri(v){let s=String(v||'').trim();try{s=decodeURIComponent(s)}catch(_){ }return s.replace(/\/{2,}/g,'/')}
function parseManagedExclusions(content){
  const c=String(content||'').replace(/\r\n?/g,'\n');
  const blocks=c.split(/(?=# -{10,}\n# (?:CM|TEKO)-FP:)/g).filter(x=>/# (?:CM|TEKO)-FP:/.test(x));
  return blocks.map(b=>{
    const status=((b.match(/# CM-FP-STATUS:\s*([^\n]+)/i)||[])[1]||'active').trim().toLowerCase();
    const strategy=((b.match(/# Strategy:\s*([^|\n]+)/i)||[])[1]||'').trim().toLowerCase();
    const fp=(b.match(/# CM-FP-MATCH:\s*rule=(\d+)\s*\|\s*host=([^|\n]+)\s*\|\s*uri=([^|\n]+)\s*\|\s*method=([^|\n]+)\s*\|\s*target=([^\n]+)/i)||[]);
    let rule='',host='',uri='',method='*',target='*';
    if(fp.length){rule=fp[1].trim();host=fp[2].trim();uri=fp[3].trim();method=fp[4].trim();target=fp[5].trim()}
    else {
      const legacy=(b.match(/# CRS\s+(\d+)\s*\|\s*([^|\n]+)\s*\|\s*([^|\n]+)(?:\s*\|\s*([^\n]+))?/i)||[]);
      if(legacy.length){rule=legacy[1].trim();host=legacy[2].trim();uri=legacy[3].trim();target=(legacy[4]||'*').trim()}
    }
    return {block:b,status,strategy,rule,host,uri,method,target};
  });
}
function eventIsTuned(e){
  const rid=String(e.rule_id||'').trim(), host=msNormHost(e.host), uri=msNormUri(e.uri), target=String(e.target||'').trim(), method=String(e.method||'').trim().toUpperCase();
  if(!rid||!host||!uri)return false;
  return parseManagedExclusions($('customRules').value||'').some(x=>{
    if(x.status!=='active'||x.rule!==rid||msNormHost(x.host)!==host||msNormUri(x.uri)!==uri)return false;
    if(x.method&&x.method!=='*'&&method&&x.method.toUpperCase()!==method)return false;
    const targetScoped=x.strategy==='target';
    if(targetScoped && x.target && x.target!=='*' && target && x.target!==target)return false;
    return true;
  });
}
function eventSeverityClass(s){s=String(s||'').toUpperCase();return s==='CRITICAL'?'text-bg-danger':s==='ERROR'?'text-bg-warning':s==='WARNING'?'text-bg-warning':'text-bg-secondary'}
function topValue(items, field){
  const counts=new Map();items.forEach(e=>{const v=String(e?.[field]||'').trim();if(v)counts.set(v,(counts.get(v)||0)+Number(e.count||1))});
  let best='—',n=0;for(const [v,c] of counts){if(c>n){best=v;n=c}}return best==='—'?'—':best+' ('+n+')';
}
function renderEvents(){
  const q=$('eventSearch').value.trim().toLowerCase(),sf=$('eventStatus').value;
  const summaries=EVENTS.filter(e=>!!e.meta_rule);
  const actionable=EVENTS.filter(e=>!e.meta_rule);
  const incomplete=actionable.filter(e=>!String(e.host||'').trim()||!String(e.uri||'').trim());
  const usable=actionable.filter(e=>String(e.host||'').trim()&&String(e.uri||'').trim());
  let tuned=0;usable.forEach(e=>{e._tuned=eventIsTuned(e);if(e._tuned)tuned++});
  $('evTotal').textContent=usable.length;
  $('evCritical').textContent=usable.filter(e=>String(e.severity).toUpperCase()==='CRITICAL').length;
  $('evRules').textContent=new Set(usable.map(e=>e.rule_id)).size;
  $('evTuned').textContent=tuned;
  $('evTopRule').textContent=topValue(usable,'rule_id');
  $('evTopType').textContent=topValue(usable,'attack_type');
  $('eventCount').textContent=usable.filter(e=>!e._tuned).length;
  if($('eventRawInfo'))$('eventRawInfo').textContent=`Technischer Kontext: ${summaries.length} Summary-Zeilen ausgeblendet${incomplete.length?`, ${incomplete.length} unvollständige Rohzeilen ausgeblendet`:''}.`;
  const rows=usable.filter(e=>{if(sf==='new'&&e._tuned)return false;if(sf==='tuned'&&!e._tuned)return false;if(!q)return true;return [e.rule_id,e.host,e.uri,e.target,e.message,e.attack_type,e.data,(e.summary_rules||[]).join(' ')].join(' ').toLowerCase().includes(q)});
  if(!rows.length){$('eventsBody').innerHTML='<tr><td colspan="9" class="text-center text-muted py-4">Keine passenden konkreten CRS-Ursachen.</td></tr>';return}
  $('eventsBody').innerHTML=rows.map(e=>{
    const summaries=Array.isArray(e.summary_rules)?e.summary_rules:[];
    const summaryHint=summaries.length?`<div class="small text-muted ms-correlation-hint" title="Technische CRS Summary-/Anomaly-Regeln dieser Transaktion">Summary: ${summaries.map(esc).join(', ')}</div>`:'';
    const actionLabel=e._tuned?'Prüfen':'Ausnahme bauen';
    return `<tr class="${e._tuned?'ms-event-tuned':''}"><td class="text-nowrap mono small">${esc(e.time||'—')}</td><td>${e._tuned?'<span class="badge text-bg-success">getunt</span>':'<span class="badge text-bg-danger">offen</span>'}</td><td><span class="badge ${eventSeverityClass(e.severity)}">${esc(e.severity&&e.severity!=='UNKNOWN'?e.severity:'—')}</span></td><td class="mono fw-semibold">${esc(e.rule_id)}${summaryHint}</td><td>${e.attack_type?'<span class="badge text-bg-light border">'+esc(e.attack_type)+'</span>':'<span class="text-muted">—</span>'}</td><td><div class="fw-semibold">${esc(e.host)}</div><div class="mono small text-muted ms-event-uri">${esc(e.uri)}</div></td><td class="mono small">${esc(e.target||'—')}</td><td><span class="badge text-bg-light border">${Number(e.count||1)}</span></td><td class="text-end"><button class="btn btn-outline-primary btn-sm ms-tune-event" data-i="${EVENTS.indexOf(e)}" title="${e._tuned?'Aktive Ausnahme prüfen':'Eng begrenzte Ausnahme automatisch erzeugen'}"><i class="bi bi-sliders2 me-1"></i>${actionLabel}</button></td></tr>`
  }).join('');
  document.querySelectorAll('.ms-tune-event').forEach(b=>b.onclick=()=>tuneEvent(EVENTS[Number(b.dataset.i)]));
}
async function loadEvents(){
  const b=$('reloadEvents');b.disabled=true;try{if(!CUSTOM_LOADED)await loadCustom();const minutes=Number($('eventWindow').value||60);const j=await api('modsecurity.php?api=events&minutes='+minutes+'&limit=500');EVENTS=Array.isArray(j.events)?j.events:[];renderEvents();msg(`${EVENTS.length} ModSecurity-Events aus Loki geladen.`,'success')}catch(e){EVENTS=[];renderEvents();msg('Security Events: '+e.message,'warning')}finally{b.disabled=false}
}
async function tuneEvent(e){
  if(!e)return;
  if(e.meta_rule){
    if(!e.root_event){msg(`CRS Rule ${e.rule_id} ist nur eine Anomaly-/Reporting-Rule und darf nicht direkt ausgenommen werden. Keine konkrete Ursache in derselben Transaktion gefunden.`,'warning');return}
    msg(`Technische CRS Summary ${e.rule_id}: konkrete Ursache ${e.root_event.rule_id} wird verwendet.`,'info');
    e=e.root_event;
  }
  fillEvent(e);bootstrap.Tab.getOrCreateInstance($('customTab')).show();$('parseState').textContent=e._tuned?'Passende Ausnahme bereits erkannt – Scope prüfen.':'Event übernommen. Scope wird erkannt und die Rule serverseitig gebaut.';await buildExclusion(true);setTimeout(()=>$('scopePreview').scrollIntoView({behavior:'smooth',block:'center'}),120);
}
async function loadCustom(){const j=await api('modsecurity.php?api=custom&server='+encodeURIComponent($('server').value));$('customRules').value=j.custom.content||'';renderManagedCustom($('customRules').value);CUSTOM_LOADED=true}
async function init(){DATA=await api('modsecurity.php?api=summary');$('server').innerHTML=DATA.servers.map(s=>`<option>${String(s.name).replace(/[&<>"]/g,'')}</option>`).join('');if(DATA.servers.length)await load()}
function renderRuntime(i,c){
  const rt=i.runtime||{};
  const configured=rt.configured_mode||c.rule_engine||'—';
  const effective=rt.effective_override_mode||'nicht gesetzt';
  const ok=!!rt.override_present&&!!rt.override_matches;
  $('effectiveMode').textContent=effective;
  $('effectiveMode').className='teko-stat-value '+(ok?'text-success':'text-danger');
  const deps=Array.isArray(rt.dependencies)?rt.dependencies:[];
  $('dependencyState').textContent=ok?(deps.length?`${deps.length} erkannt / OK`:'OK'):'Prüfen';
  $('dependencyState').className='teko-stat-value '+(ok?'text-success':'text-danger');
  const panel=$('dependencyPanel'); panel.classList.remove('ms-runtime-ok','ms-runtime-bad'); panel.classList.add(ok?'ms-runtime-ok':'ms-runtime-bad');
  $('dependencySummary').innerHTML=ok
    ? `Soll-Modus <strong>${esc(configured)}</strong> wird durch <span class="mono">${esc(rt.mode_override_path||'zz-teko-modsecurity-mode.conf')}</span> wirksam zuletzt gesetzt.`
    : `Soll-Modus <strong>${esc(configured)}</strong>, aber der wirksame lokale Runtime-Override ist <strong>${esc(effective)}</strong>. Speichern repariert den Runtime-Override automatisch.`;
  if(deps.length){
    $('dependencyList').innerHTML='<div class="fw-semibold mb-1">Weitere SecRuleEngine-Definitionen:</div>'+deps.map(d=>`<div class="mono">${esc(d.path)}:${esc(d.line)} → ${esc(d.mode)}</div>`).join('')+'<div class="mt-1">Diese Definitionen dürfen vorhanden sein. Der lokale Runtime-Override wird auf SUSE bewusst als <span class="mono">zz-teko-modsecurity-mode.conf</span> danach angewendet.</div>';
  }else $('dependencyList').innerHTML='<span class="text-muted">Keine weiteren SecRuleEngine-Definitionen gefunden.</span>';
}
async function load(){try{const j=await api('modsecurity.php?api=load&server='+encodeURIComponent($('server').value)),i=j.info,c=j.config.config;$('installed').textContent=i.installed?'Ja':'Nein';$('module').textContent=i.module_loaded?'geladen':'nicht geladen';$('crs').textContent=i.crs_detected?'erkannt':'nicht erkannt';$('manager').textContent=i.os?.manager||'—';$('engine').value=c.rule_engine;$('audit').value=c.audit_engine;$('limit').value=c.request_body_limit;$('req').checked=!!c.request_body_access;$('resp').checked=!!c.response_body_access;$('ids').value=(c.excluded_rule_ids||[]).join(', ');$('install').disabled=!!i.installed;$('install').innerHTML=i.installed?'<i class="bi bi-check-circle me-1"></i>ModSecurity installiert':'<i class="bi bi-shield-plus me-1"></i>ModSecurity + OWASP CRS installieren';renderRuntime(i,c);if(RULES.length)renderRules();if(!i.installed)msg('ModSecurity / OWASP CRS ist auf diesem Webserver noch nicht installiert. Die Installation kann direkt gestartet werden.','warning');else msg((i.runtime&&i.runtime.override_matches)?'Lokaler ModSecurity-Status geladen. Runtime-Modus ist konsistent.':'Lokaler ModSecurity-Status geladen. Runtime-Abhängigkeit prüfen.',(i.runtime&&i.runtime.override_matches)?'success':'warning')}catch(e){msg(e.message,'danger')}}
$('load').onclick=load;
$('install').onclick=async()=>{
  if(!confirm('ModSecurity und OWASP CRS auf diesem Server installieren und Apache neu laden?'))return;
  const b=$('install');b.disabled=true;
  try{
    msg('Installation läuft … Apache kann dabei kurz neu starten.','info');
    await api('modsecurity.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'install',server_name:$('server').value,confirm_install:true})});
    msg('Installation abgeschlossen.','success');await load();
  }catch(e){
    if(!isNetworkError(e)){msg(e.message,'danger');return}
    try{
      msg('Apache wird neu gestartet. Verbindung kurz unterbrochen – warte auf Config Manager …','warning');
      await waitForManager();
      await load();
      msg('Apache ist wieder erreichbar. Installationsstatus wurde neu geladen.','success');
    }catch(re){msg(re.message,'danger')}
  }finally{b.disabled=false}
};
$('save').onclick=async()=>{const ids=$('ids').value.split(/[\s,]+/).filter(Boolean);const config={rule_engine:$('engine').value,audit_engine:$('audit').value,request_body_limit:Number($('limit').value),request_body_access:$('req').checked,response_body_access:$('resp').checked,excluded_rule_ids:ids};try{await api('modsecurity.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'save',server_name:$('server').value,config})});msg('ModSecurity-Konfiguration geprüft, gespeichert und Apache neu geladen.','success');await load()}catch(e){msg(e.message,'danger')}};
$('rulesTab').addEventListener('shown.bs.tab',()=>{if(!RULES.length)loadRules().catch(e=>msg(e.message,'danger'))});
$('eventsTab').addEventListener('shown.bs.tab',()=>{if(!EVENTS.length)loadEvents()});
$('customTab').addEventListener('shown.bs.tab',()=>{if(!CUSTOM_LOADED)loadCustom().catch(e=>msg(e.message,'danger'))});
$('ruleSearch').oninput=renderRules;$('ruleFilter').onchange=renderRules;$('reloadRules').onclick=()=>loadRules().catch(e=>msg(e.message,'danger'));
$('reloadCustom').onclick=()=>loadCustom().then(()=>{if(EVENTS.length)renderEvents()}).catch(e=>msg(e.message,'danger'));
$('reloadEvents').onclick=loadEvents;$('eventWindow').onchange=loadEvents;$('eventSearch').oninput=renderEvents;$('eventStatus').onchange=renderEvents;
$('parseEvent').onclick=parseEventLine;
$('clearEvent').onclick=()=>{$('eventPaste').value='';$('parseState').textContent='';EXCLUSION_PREVIEW='';SELECTED_EVENT=null;showSelectedEvent(null);$('rulePreview').textContent='Hier erscheint die automatisch erzeugte Ausnahme.';$('appendExclusion').disabled=true;$('activateExclusion').disabled=true};
$('buildExclusion').onclick=async()=>{const b=$('buildExclusion');const old=b.innerHTML;b.disabled=true;b.innerHTML='<span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span>Rule wird gebaut …';try{await buildExclusion(true)}finally{b.disabled=false;b.innerHTML=old}};
['exRuleId','exHost','exUri','exTarget','exMethod'].forEach(id=>$(id).addEventListener('input',()=>{if(!EXCLUSION_PREVIEW)return;EXCLUSION_PREVIEW='';$('appendExclusion').disabled=true;$('activateExclusion').disabled=true;$('scopePreview').innerHTML='<div class="text-muted">Felder geändert – Rule erneut automatisch bauen.</div>';$('riskBadge').className='ms-risk ms-risk-low';$('riskBadge').textContent='neu bauen';const st=$('builderState');if(st){st.className='small mt-2 text-warning';st.textContent='Scope wurde geändert. Rule bitte erneut bauen.'}}));
$('appendExclusion').onclick=()=>{if(!EXCLUSION_PREVIEW)return;const ta=$('customRules');const base=ta.value.trimEnd();ta.value=(base?base+'\n\n':'')+EXCLUSION_PREVIEW+'\n';renderManagedCustom(ta.value);bootstrap.Tab.getOrCreateInstance($('expertTab')).show();msg('Ausnahme in den Experteneditor übernommen.','info')};
$('activateExclusion').onclick=async()=>{const b=$('activateExclusion');b.disabled=true;try{const e=eventFromForm();const j=await api('modsecurity.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'activate_exclusion',server_name:$('server').value,event:e})});msg('Ausnahme validiert, gespeichert und Apache neu geladen.','success');EXCLUSION_PREVIEW=j.generated?.rule||EXCLUSION_PREVIEW;CUSTOM_LOADED=false;await loadCustom();if(EVENTS.length)renderEvents();$('activateExclusion').disabled=true;}catch(err){msg(err.message,'danger');b.disabled=false}};
$('runtimeToggle').onclick=()=>{$('dependencyPanel').classList.toggle('d-none')};
$('expertTab').addEventListener('shown.bs.tab',()=>{if(!CUSTOM_LOADED)loadCustom().catch(e=>msg(e.message,'danger'))});
$('clearCustom').onclick=()=>{if(confirm('Custom-Rules im Editor leeren? Gespeichert wird erst nach Klick auf Speichern.')){$('customRules').value='';renderManagedCustom('')}};
$('saveCustom').onclick=async()=>{try{await api('modsecurity.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'save_custom',server_name:$('server').value,content:$('customRules').value})});msg('Custom Rules geprüft, gespeichert und Apache neu geladen.','success');CUSTOM_LOADED=false;await loadCustom();if(EVENTS.length)renderEvents()}catch(e){msg(e.message,'danger')}};
init().catch(e=>msg(e.message,'danger'));
</script><?php require MMBB_UI.'/includes/js.php';?></body></html>
