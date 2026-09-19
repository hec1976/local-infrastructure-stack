<?php
declare(strict_types=1);

require_once __DIR__ . '/../standalone/bootstrap.php';

if (!mmbb_has_service('ConfigManager')) {
    http_response_code(403);
    echo 'Forbidden';
    exit;
}

$csrf=(string)($_SESSION['csrf_token'] ?? '');
$cfgFile='/opt/service/config-manager/enrollment.json';

function ae_json_response(array $data,int $status=200): never {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data,JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
    exit;
}
function ae_load_cfg(string $path): array {
    if(!is_file($path)||!is_readable($path)) throw new RuntimeException('Enrollment ist auf diesem Manager nicht installiert.',503);
    $raw=file_get_contents($path);
    $j=json_decode((string)$raw,true);
    if(!is_array($j)) throw new RuntimeException('Enrollment-Konfiguration ist ungültig.',500);
    return $j;
}
function ae_valid_dns(string $v): bool {
    return (bool)preg_match('/^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/',$v);
}
function ae_valid_host(string $v): bool {
    return filter_var($v,FILTER_VALIDATE_IP)!==false || ae_valid_dns($v);
}
function ae_valid_job_id(string $v): bool {
    return (bool)preg_match('/^[A-Za-z0-9._-]{1,128}$/',$v);
}
function ae_unlink_if_file(string $path): void {
    if(is_file($path) && !@unlink($path)) throw new RuntimeException('Job-Datei konnte nicht gelöscht werden: '.basename($path),500);
}
function ae_clean_groups($raw): array {
    $items=is_array($raw)?$raw:preg_split('/[\s,]+/',(string)$raw,-1,PREG_SPLIT_NO_EMPTY);
    $out=[];
    foreach($items as $g){
        $g=trim((string)$g);
        if(!preg_match('/^[A-Za-z0-9._-]{1,64}$/',$g)) throw new InvalidArgumentException("Ungültige Gruppe: $g");
        $out[$g]=$g;
    }
    if($out===[]) throw new InvalidArgumentException('Mindestens eine Gruppe ist erforderlich.');
    return array_values($out);
}
function ae_clean_labels($raw): array {
    if(is_array($raw)) {
        $out=[];
        foreach($raw as $k=>$v){
            $k=trim((string)$k); $v=trim((string)$v);
            if(!preg_match('/^[A-Za-z0-9._-]{1,64}$/',$k) || !preg_match('/^[A-Za-z0-9._:@\/-]{1,128}$/',$v))
                throw new InvalidArgumentException('Ungültiges Label.');
            $out[$k]=$v;
        }
        return $out;
    }
    $out=[];
    foreach(preg_split('/[\r\n,]+/',(string)$raw,-1,PREG_SPLIT_NO_EMPTY) as $item){
        if(!str_contains($item,'=')) throw new InvalidArgumentException('Labels als key=value angeben.');
        [$k,$v]=array_map('trim',explode('=',$item,2));
        if(!preg_match('/^[A-Za-z0-9._-]{1,64}$/',$k) || !preg_match('/^[A-Za-z0-9._:@\/-]{1,128}$/',$v))
            throw new InvalidArgumentException("Ungültiges Label: $item");
        $out[$k]=$v;
    }
    return $out;
}
function ae_read_jobs(string $dir): array {
    $out=[];
    if(!is_dir($dir)) return [];
    $files=glob(rtrim($dir,'/').'/*.json') ?: [];
    rsort($files,SORT_STRING);
    foreach(array_slice($files,0,100) as $f){
        $j=json_decode((string)@file_get_contents($f),true);
        if(is_array($j)){
            unset($j['expected_host_key_sha256'],$j['ssh_password'],$j['secret_file']);
            $out[]=$j;
        }
    }
    return $out;
}
function ae_pending_delete_ids(array $cfg): array {
    $dir=rtrim((string)($cfg['control_dir']??''),'/');
    if($dir===''||!is_dir($dir)) return [];
    $out=[];
    foreach(glob($dir.'/delete-*.json') ?: [] as $f){
        $j=json_decode((string)@file_get_contents($f),true);
        $id=is_array($j)?trim((string)($j['job_id']??'')):'';
        if(ae_valid_job_id($id)) $out[$id]=true;
    }
    return $out;
}
function ae_queue_delete_request(array $cfg,string $id): void {
    $dir=rtrim((string)($cfg['control_dir']??''),'/');
    if($dir===''||!is_dir($dir)||!is_writable($dir))
        throw new RuntimeException('Enrollment Control-Verzeichnis ist nicht beschreibbar.',500);
    $tmp=$dir.'/.delete-'.$id.'.tmp';
    $dst=$dir.'/delete-'.$id.'.json';
    $payload=json_encode(['schema_version'=>1,'action'=>'delete_job','job_id'=>$id,'requested_at'=>gmdate('c')],JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n";
    if(file_put_contents($tmp,$payload,LOCK_EX)===false) throw new RuntimeException('Löschauftrag konnte nicht geschrieben werden.',500);
    chmod($tmp,0640);
    if(!rename($tmp,$dst)){@unlink($tmp);throw new RuntimeException('Löschauftrag konnte nicht atomar aktiviert werden.',500);}
}

function ae_write_secret(array $cfg,string $id,string $password): string {
    $dir=rtrim((string)($cfg['secret_dir']??''),'/');
    if($dir===''||!is_dir($dir)||!is_writable($dir)) throw new RuntimeException('Enrollment Secret-Verzeichnis ist nicht beschreibbar.',500);
    $tmp=$dir.'/.'.$id.'.tmp';
    $dst=$dir.'/'.$id.'.secret';
    if(file_put_contents($tmp,$password,LOCK_EX)===false) throw new RuntimeException('Enrollment-Passwort konnte nicht temporär gespeichert werden.',500);
    chmod($tmp,0600);
    if(!rename($tmp,$dst)){@unlink($tmp);throw new RuntimeException('Enrollment-Passwort konnte nicht atomar aktiviert werden.',500);}
    return $dst;
}

try {
    $cfg=ae_load_cfg($cfgFile);

    if(isset($_GET['api']) && $_GET['api']==='summary'){
        $pubPath=(string)$cfg['ssh_key'].'.pub';
        $pub=is_file($pubPath)?trim((string)file_get_contents($pubPath)):'';
        // Merge queue + worker status by job id. A worker status always wins over
        // the queued file so one enrollment is rendered exactly once.
        $byId=[];
        foreach(ae_read_jobs((string)$cfg['queue_dir']) as $q){
            if(!isset($q['state'])) $q['state']='queued';
            if(!isset($q['stage'])) $q['stage']='queued';
            if(!isset($q['stage_message'])) $q['stage_message']='Wartet auf Enrollment-Worker.';
            $id=(string)($q['id']??'');
            if($id!=='') $byId[$id]=$q;
        }
        foreach(ae_read_jobs((string)$cfg['status_dir']) as $st){
            $id=(string)($st['id']??'');
            if($id!=='') $byId[$id]=$st;
        }
        $pendingDeletes=ae_pending_delete_ids($cfg);
        foreach(array_keys($pendingDeletes) as $deleteId) unset($byId[$deleteId]);
        $jobs=array_values($byId);
        usort($jobs,static fn($a,$b)=>strcmp((string)($b['created_at']??$b['started_at']??''),(string)($a['created_at']??$a['started_at']??'')));
        ae_json_response([
            'ok'=>true,
            'manager_ip'=>(string)$cfg['manager_ip'],
            'password_auth_available'=>!empty($cfg['password_auth_available']),
            'public_key'=>$pub,
            'jobs'=>array_slice($jobs,0,100),
        ]);
    }

    if($_SERVER['REQUEST_METHOD']==='POST' && (string)($_GET['api']??'')==='delete_job'){
        $raw=file_get_contents('php://input');
        $in=json_decode((string)$raw,true);
        if(!is_array($in)) throw new InvalidArgumentException('Ungültiges JSON.');
        if(!hash_equals($csrf,(string)($in['csrf_token']??''))) throw new RuntimeException('CSRF-Prüfung fehlgeschlagen.',403);
        $id=trim((string)($in['job_id']??''));
        if(!ae_valid_job_id($id)) throw new InvalidArgumentException('Ungültige Job-ID.');

        $status=rtrim((string)$cfg['status_dir'],'/').'/'.$id.'.json';
        $state=[];
        if(is_file($status)){
            $st=json_decode((string)@file_get_contents($status),true);
            if(is_array($st)) $state=$st;
        }
        if(($state['state']??'')==='running') throw new RuntimeException('Ein laufender Enrollment-Job kann nicht gelöscht werden. Warte bis er beendet ist.',409);

        // Web/PHP darf Statusdateien absichtlich nur lesen. Die eigentliche
        // Löschung erfolgt privilegiert über den Root-Worker.
        ae_queue_delete_request($cfg,$id);
        mmbb_audit_write('agent_enrollment_delete_request',$id,['state'=>(string)($state['state']??'queued')],'agent_enrollment.php','ok');
        ae_json_response(['ok'=>true,'delete_queued'=>true,'deleted_job_id'=>$id],202);
    }

    if($_SERVER['REQUEST_METHOD']==='POST'){
        $raw=file_get_contents('php://input');
        $in=json_decode((string)$raw,true);
        if(!is_array($in)) throw new InvalidArgumentException('Ungültiges JSON.');
        if(!hash_equals($csrf,(string)($in['csrf_token']??''))) throw new RuntimeException('CSRF-Prüfung fehlgeschlagen.',403);

        $sshHost=trim((string)($in['ssh_host']??''));
        $bindIp=trim((string)($in['bind_ip']??''));
        $fqdn=trim((string)($in['fqdn']??''));
        $sshUser=trim((string)($in['ssh_user']??'root'));
        $sshPort=(int)($in['ssh_port']??22);
        $fp=trim((string)($in['expected_host_key_sha256']??''));
        $authMode=strtolower(trim((string)($in['auth_mode']??'key')));

        if(!ae_valid_host($sshHost)) throw new InvalidArgumentException('SSH Host/IP ist ungültig.');
        if(filter_var($bindIp,FILTER_VALIDATE_IP)===false) throw new InvalidArgumentException('Agent Bind-IP ist ungültig.');
        $managerIp=(string)$cfg['manager_ip'];
        $sshHostIp=filter_var($sshHost,FILTER_VALIDATE_IP)!==false;
        if($sshHostIp && $sshHost!==$managerIp && $bindIp===$managerIp)
            throw new InvalidArgumentException('Agent Bind-IP entspricht der Manager-IP. Für dieses SSH-Ziel ist sehr wahrscheinlich '.$sshHost.' als Agent Bind-IP erforderlich.');
        if(!ae_valid_dns($fqdn)) throw new InvalidArgumentException('Agent FQDN ist ungültig.');
        if(!preg_match('/^[a-z_][a-z0-9_-]{0,31}$/',$sshUser)) throw new InvalidArgumentException('SSH-Benutzer ist ungültig.');
        if($sshPort<1||$sshPort>65535) throw new InvalidArgumentException('SSH-Port ist ungültig.');
        if(!in_array($authMode,['key','password'],true)) throw new InvalidArgumentException('SSH Authentifizierung muss SSH-Key oder Passwort sein.');
        if($authMode==='key' && !preg_match('/^SHA256:[A-Za-z0-9+\/]{43}=?$/',$fp))
            throw new InvalidArgumentException('SSH Host-Key Fingerprint ist im SSH-Key-Modus erforderlich und muss SHA256:... sein.');
        if($authMode==='password' && $fp!=='' && !preg_match('/^SHA256:[A-Za-z0-9+\/]{43}=?$/',$fp))
            throw new InvalidArgumentException('Optionaler SSH Host-Key Fingerprint muss SHA256:... sein.');

        $password='';
        if($authMode==='password'){
            if(empty($cfg['password_auth_available'])) throw new RuntimeException('Passwort-Enrollment ist auf diesem Manager nicht verfügbar (sshpass fehlt).',503);
            $password=(string)($in['ssh_password']??'');
            if($password===''||strlen($password)>1024||str_contains($password,"\0")||str_contains($password,"\n")||str_contains($password,"\r"))
                throw new InvalidArgumentException('SSH-Passwort ist leer, zu lang oder enthält nicht unterstützte Steuerzeichen.');
        }

        $groups=ae_clean_groups($in['groups']??[]);
        if(!empty($in['canary']) && !in_array('canary',$groups,true)) $groups[]='canary';
        $labels=ae_clean_labels($in['labels']??[]);

        $id=gmdate('YmdHis').'-'.bin2hex(random_bytes(6));
        $hostId='host-'.substr(hash('sha256',strtolower($fqdn)),0,16);
        $job=[
            'schema_version'=>2,
            'id'=>$id,
            'state'=>'queued',
            'stage'=>'queued',
            'stage_message'=>'Wartet auf Enrollment-Worker.',
            'progress_percent'=>0,
            'created_at'=>gmdate('c'),
            'created_by'=>mmbb_audit_current_user(),
            'manager_ip'=>(string)$cfg['manager_ip'],
            'ssh_host'=>$sshHost,
            'ssh_port'=>$sshPort,
            'ssh_user'=>$sshUser,
            'auth_mode'=>$authMode,
            'use_sudo'=>!empty($in['use_sudo']),
            'expected_host_key_sha256'=>$fp,
            'bind_ip'=>$bindIp,
            'fqdn'=>$fqdn,
            'host_id'=>$hostId,
            'groups'=>$groups,
            'labels'=>$labels,
        ];

        $queue=rtrim((string)$cfg['queue_dir'],'/');
        if(!is_dir($queue)||!is_writable($queue)) throw new RuntimeException('Enrollment Queue ist nicht beschreibbar.',500);
        $secretPath='';
        try {
            if($authMode==='password') $secretPath=ae_write_secret($cfg,$id,$password);
            // Build the temporary job outside the watched queue.  This prevents
            // systemd.path from waking the worker for an incomplete .tmp file.
            // Temporary queue files belong in a dedicated web-writable incoming
            // directory. Never require PHP/Apache to write into the root-owned
            // worker state directory. The final rename into queue is atomic
            // because incoming and queue live below the same STATE filesystem.
            $incoming=rtrim((string)($cfg['incoming_dir']??dirname($queue).'/incoming'),'/');
            if(!is_dir($incoming)||!is_writable($incoming)) throw new RuntimeException('Enrollment Incoming-Verzeichnis ist nicht beschreibbar.',500);
            $tmp=$incoming.'/.queue-'.$id.'.tmp';
            $dst=$queue.'/'.$id.'.json';
            $encoded=json_encode($job,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)."\n";
            if(file_put_contents($tmp,$encoded,LOCK_EX)===false) throw new RuntimeException('Job konnte nicht geschrieben werden.',500);
            chmod($tmp,0640);
            if(!rename($tmp,$dst)){@unlink($tmp);throw new RuntimeException('Job konnte nicht atomar aktiviert werden.',500);}
        } catch(Throwable $writeError) {
            if($secretPath!=='') @unlink($secretPath);
            throw $writeError;
        }

        // Password and fingerprint are intentionally excluded from audit payloads.
        mmbb_audit_write('agent_enrollment_queue',$fqdn,[
            'ssh_host'=>$sshHost,'bind_ip'=>$bindIp,'groups'=>$groups,'labels'=>$labels,
            'auth_mode'=>$authMode,'use_sudo'=>!empty($in['use_sudo'])
        ],'agent_enrollment.php','ok');

        ae_json_response(['ok'=>true,'job_id'=>$id],202);
    }
} catch(Throwable $e){
    $code=(int)$e->getCode(); if($code<400||$code>599)$code=400;
    if(isset($_GET['api'])||$_SERVER['REQUEST_METHOD']==='POST') ae_json_response(['ok'=>false,'error'=>$e->getMessage()],$code);
    $pageError=$e->getMessage();
}
?>
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Managed Hosts – Enrollment</title>
<?php require MMBB_UI.'/includes/css.php'; ?>
<style>
.ae-grid{display:grid;grid-template-columns:minmax(420px,1fr) minmax(520px,1.15fr);gap:1rem;align-items:start}
.ae-panel{border:1px solid var(--bs-border-color);border-radius:.75rem;background:var(--bs-body-bg);overflow:hidden;box-shadow:0 .2rem .65rem rgba(15,23,42,.08)}
.ae-status-panel{position:sticky;top:.75rem;display:flex;flex-direction:column;max-height:calc(100vh - 1.5rem);min-height:32rem}
.ae-status-panel .ae-panel-head{flex:0 0 auto}
.ae-status-actions{display:flex;align-items:center;gap:.4rem;flex-wrap:wrap}
.ae-status-actions .btn{padding:.18rem .48rem;font-size:.72rem}
.ae-auto-label{font-size:.74rem;font-weight:500;color:#64748b;white-space:nowrap}
.ae-panel-head{display:flex;align-items:center;justify-content:space-between;gap:.75rem;padding:.85rem 1rem;background:#e9eef5;border-bottom:1px solid #cbd5e1;font-weight:700;color:#172033}
.ae-panel-body{padding:1rem}
.ae-section{border:1px solid #cbd5e1;border-radius:.65rem;background:#f8fafc;padding:.9rem;margin-bottom:.85rem}
.ae-section-title{display:flex;align-items:center;gap:.45rem;font-weight:700;color:#172033;margin-bottom:.7rem}
.ae-section-no{display:inline-flex;align-items:center;justify-content:center;width:1.55rem;height:1.55rem;border-radius:50%;background:#2f5fa7;color:#fff;font-size:.78rem;font-weight:700}
.ae-auth-grid{display:grid;grid-template-columns:1fr 1fr;gap:.7rem}
.ae-auth-option{position:relative;border:1px solid #b8c4d4;border-radius:.6rem;background:#fff;padding:.8rem;cursor:pointer;transition:.15s ease}
.ae-auth-option:has(input:checked){border-color:#2f5fa7;box-shadow:0 0 0 .18rem rgba(47,95,167,.14);background:#f2f6fc}
.ae-auth-option input{margin-right:.45rem}.ae-auth-option strong{color:#172033}.ae-auth-option small{display:block;margin:.3rem 0 0 1.5rem;color:#526174}
.ae-tech{background:#172033;color:#dbe7f5;border:1px solid #263750;border-radius:.65rem;padding:.85rem}
.ae-tech-label{font-size:.72rem;text-transform:uppercase;letter-spacing:.06em;color:#91a9c6;font-weight:700;margin-bottom:.35rem}
.ae-key{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.76rem;word-break:break-all;line-height:1.45;color:#f8fbff}
.ae-summary{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.7rem;margin-bottom:1rem}
.ae-kpi{border:1px solid #cbd5e1;border-radius:.65rem;background:#f8fafc;padding:.75rem .85rem}.ae-kpi-label{font-size:.72rem;text-transform:uppercase;letter-spacing:.05em;color:#64748b;font-weight:700}.ae-kpi-value{font-weight:700;color:#172033;margin-top:.2rem;overflow:hidden;text-overflow:ellipsis}
.ae-jobs{display:flex;flex:1 1 auto;min-height:0;flex-direction:column;gap:.7rem;padding:.85rem;background:#eef2f7;overflow-y:scroll;overflow-x:hidden;scrollbar-gutter:stable;overscroll-behavior:contain;scroll-behavior:smooth}
.ae-jobs::-webkit-scrollbar{width:12px}.ae-jobs::-webkit-scrollbar-track{background:#dfe6ef}.ae-jobs::-webkit-scrollbar-thumb{background:#9aa9bc;border:3px solid #dfe6ef;border-radius:999px}.ae-jobs::-webkit-scrollbar-thumb:hover{background:#74869d}
.ae-job{border:1px solid #c9d3df;border-left-width:4px;border-radius:.65rem;background:#fff;box-shadow:0 .12rem .35rem rgba(15,23,42,.05);overflow:hidden;flex:0 0 auto}
.ae-job>summary{list-style:none;cursor:pointer}.ae-job>summary::-webkit-details-marker{display:none}.ae-job>summary:focus-visible{outline:3px solid rgba(47,95,167,.25);outline-offset:-3px}.ae-job-toggle{display:inline-flex;align-items:center;justify-content:center;width:1.4rem;height:1.4rem;border-radius:.35rem;color:#64748b;background:#edf1f6;flex:0 0 auto}.ae-job[open] .ae-job-toggle i{transform:rotate(90deg)}.ae-job-toggle i{transition:transform .15s ease}.ae-job-summary-main{display:flex;align-items:center;gap:.55rem;min-width:0}.ae-job-summary-text{min-width:0}
.ae-job.completed{border-left-color:#198754}.ae-job.failed{border-left-color:#dc3545}.ae-job.running{border-left-color:#d39e00}.ae-job.queued{border-left-color:#6c757d}
.ae-job-head{display:flex;justify-content:space-between;align-items:center;gap:.75rem;padding:.7rem .8rem;background:#f8fafc;border-bottom:1px solid #e0e6ee}
.ae-job-agent{font-weight:700;color:#172033}.ae-job-time{font-size:.75rem;color:#64748b}
.ae-job-body{display:grid;grid-template-columns:1fr 1fr;gap:.55rem .9rem;padding:.75rem .8rem}.ae-meta-label{font-size:.68rem;text-transform:uppercase;letter-spacing:.05em;color:#718096;font-weight:700}.ae-meta-value{font-size:.86rem;color:#253247;word-break:break-word}
.ae-result{padding:.65rem .8rem;background:#172033;color:#dbe7f5;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.76rem;word-break:break-word}
.ae-status{font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.04em;padding:.3rem .55rem;border-radius:999px}.ae-status.completed{background:#dff3e8;color:#12643c}.ae-status.failed{background:#f8dfe2;color:#9d1f2d}.ae-status.running{background:#fff1c7;color:#805e00}.ae-status.queued{background:#e5e9ef;color:#4d5a6a}
.ae-progress-wrap{padding:.75rem .85rem .15rem}.ae-progress-head{display:flex;align-items:center;justify-content:space-between;gap:.75rem;margin-bottom:.45rem}.ae-current-stage{font-weight:700;color:#172033}.ae-progress-value{font-size:.78rem;font-weight:700;color:#526174}.ae-progress{height:.55rem;background:#dfe6ef;border-radius:999px;overflow:hidden}.ae-progress-bar{height:100%;background:#2f5fa7;transition:width .25s ease}.ae-job.completed .ae-progress-bar{background:#198754}.ae-job.failed .ae-progress-bar{background:#dc3545}.ae-stage-message{margin-top:.5rem;font-size:.83rem;color:#526174}
.ae-step-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.45rem;padding:.65rem .85rem .8rem}.ae-step{display:flex;align-items:center;gap:.45rem;min-width:0;border:1px solid #d5dde8;border-radius:.5rem;background:#f8fafc;padding:.48rem .55rem;color:#64748b}.ae-step i{font-size:.9rem;flex:0 0 auto}.ae-step-label{font-size:.75rem;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.ae-step.completed{border-color:#b9dec9;background:#eef9f3;color:#157347}.ae-step.running{border-color:#91add3;background:#edf4ff;color:#1f4f92}.ae-step.failed{border-color:#e7b6bd;background:#fff1f2;color:#a52834}.ae-step.waiting{border-color:#d8c58d;background:#fff9e8;color:#7b6000}
.ae-meta-strip{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.5rem;padding:.7rem .85rem;border-top:1px solid #e0e6ee;border-bottom:1px solid #e0e6ee;background:#fbfcfe}.ae-meta-box{min-width:0}.ae-meta-box .ae-meta-value{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.ae-job-id{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:#718096;font-size:.7rem}
.ae-eventlog{margin:.1rem .85rem .85rem;border:1px solid #263750;border-radius:.55rem;background:#172033;color:#dbe7f5;overflow:hidden}.ae-eventlog-head{display:flex;justify-content:space-between;align-items:center;padding:.45rem .65rem;background:#202d42;color:#aebfd5;font-size:.7rem;text-transform:uppercase;letter-spacing:.05em;font-weight:700}.ae-event{display:grid;grid-template-columns:4.7rem 7.8rem 1fr;gap:.45rem;padding:.38rem .65rem;border-top:1px solid rgba(255,255,255,.07);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.72rem;line-height:1.35}.ae-event-time{color:#8fa6c3}.ae-event-stage{color:#b9c9dc}.ae-event-message{color:#eef5ff;word-break:break-word}.ae-event.error .ae-event-message{color:#ffb4bd}.ae-event.success .ae-event-message{color:#a9e9c5}
.ae-bind-warning{display:none;margin-top:.5rem;padding:.55rem .65rem;border:1px solid #e6c66d;border-left:4px solid #d39e00;border-radius:.5rem;background:#fff9e6;color:#6b5600;font-size:.78rem;line-height:1.4}.ae-bind-warning.show{display:block}.ae-job-tools{display:flex;justify-content:flex-end;padding:.1rem .85rem .65rem}.ae-delete-job{font-size:.74rem;padding:.25rem .5rem}
.ae-result{margin:.1rem .85rem .85rem;border-radius:.5rem}.ae-result.success{background:#e8f6ee;color:#155d38;border:1px solid #b8dfc8;font-family:inherit;font-weight:600}.ae-result.error{background:#fff0f1;color:#912936;border:1px solid #e6b9bf;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.ae-error-summary{margin:.65rem .85rem .2rem;padding:.7rem .8rem;border:1px solid #efabb3;border-left:4px solid #dc3545;border-radius:.55rem;background:#fff3f4;color:#7d1d29}.ae-error-title{display:flex;align-items:center;gap:.4rem;font-size:.76rem;font-weight:800;text-transform:uppercase;letter-spacing:.04em}.ae-error-text{margin-top:.35rem;font-family:inherit;font-size:.84rem;font-weight:650;line-height:1.45;white-space:pre-wrap;word-break:break-word}.ae-error-details{margin:.35rem .85rem .75rem;border:1px solid #d5dde7;border-radius:.5rem;background:#fff}.ae-error-details summary{cursor:pointer;padding:.5rem .65rem;font-size:.78rem;font-weight:700;color:#39495f}.ae-error-details pre{margin:0;border-top:1px solid #d5dde7;padding:.65rem;background:#172033;color:#eef5ff;font-size:.76rem;line-height:1.45;white-space:pre;overflow:auto;max-height:min(42vh,26rem);max-width:100%;tab-size:4}.ae-error-details[open]{box-shadow:0 .2rem .55rem rgba(15,23,42,.12)}.ae-queue-hint{margin:.1rem .85rem .85rem;padding:.55rem .65rem;border:1px solid #dfcf9c;border-radius:.5rem;background:#fff9e8;color:#705800;font-size:.78rem}.ae-queue-stale{border-color:#e4a7ad;background:#fff0f1;color:#8a2430}.ae-note{font-size:.82rem;color:#526174}.ae-hidden{display:none!important}
@media(max-width:1100px){.ae-grid{grid-template-columns:1fr}.ae-status-panel{position:relative;top:auto;max-height:none;min-height:0}.ae-jobs{max-height:70vh;min-height:26rem}}
@media(max-width:900px){.ae-step-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.ae-meta-strip{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:720px){.ae-auth-grid,.ae-summary,.ae-job-body,.ae-step-grid,.ae-meta-strip{grid-template-columns:1fr}.ae-event{grid-template-columns:4.7rem 1fr}.ae-event-stage{display:none}}
</style>
</head>
<body>
<?php require MMBB_UI.'/navigation.php'; require MMBB_UI.'/sidebar.php'; ?>
<div class="container mmbb-main py-3 mmbb-page">
<?php require MMBB_UI.'/module_header.php'; ?>
<?php require __DIR__.'/../standalone/layout/managed_hosts_tabs.php'; ?>
<div class="mmbb-page-toolbar mb-3">
 <div class="mmbb-page-toolbar-spacer"></div>
 <button id="refresh" class="btn btn-outline-secondary btn-sm"><i class="bi bi-arrow-clockwise me-1"></i>Neu laden</button>
</div>
<div id="msg" class="alert d-none"></div>
<?php if(!empty($pageError)): ?><div class="alert alert-danger"><?=htmlspecialchars($pageError,ENT_QUOTES)?></div><?php endif; ?>

<div class="ae-summary">
 <div class="ae-kpi"><div class="ae-kpi-label">Manager IP</div><div id="managerIp" class="ae-kpi-value">wird geladen…</div></div>
 <div class="ae-kpi"><div class="ae-kpi-label">SSH Auth</div><div id="authCapability" class="ae-kpi-value">SSH-Key</div></div>
 <div class="ae-kpi"><div class="ae-kpi-label">Jobs</div><div id="jobCount" class="ae-kpi-value">0</div></div>
</div>

<div class="ae-grid">
<section class="ae-panel">
 <div class="ae-panel-head"><span><i class="bi bi-pc-display-horizontal me-1"></i>Neuen Agent installieren</span><span class="badge text-bg-primary">Enrollment</span></div>
 <div class="ae-panel-body">
  <form id="form" autocomplete="off">
   <div class="ae-section">
    <div class="ae-section-title"><span class="ae-section-no">1</span>Verbindung</div>
    <div class="row g-2">
     <div class="col-md-7"><label class="form-label">SSH Host / IP</label><input id="sshHost" name="ssh_host" class="form-control" required placeholder="192.168.1.21"></div>
     <div class="col-md-5"><label class="form-label">SSH Port</label><input name="ssh_port" class="form-control" type="number" value="22" min="1" max="65535"></div>
     <div class="col-md-5"><label class="form-label">SSH Benutzer</label><input name="ssh_user" class="form-control" value="root" required></div>
     <div class="col-md-7"><label class="form-label">SSH Host-Key SHA256 <span id="hostKeyModeHint" class="badge text-bg-secondary ms-1">Pflicht bei SSH-Key</span></label><input id="hostKeyFingerprint" name="expected_host_key_sha256" class="form-control font-monospace" required placeholder="SHA256:..."><div id="hostKeyHelp" class="form-text">Fingerprint des Zielsystems. Im SSH-Key-Modus erforderlich.</div></div>
    </div>
   </div>

   <div class="ae-section">
    <div class="ae-section-title"><span class="ae-section-no">2</span>SSH Authentifizierung</div>
    <div class="ae-auth-grid mb-2">
     <label class="ae-auth-option"><div><input type="radio" name="auth_mode" value="key" checked><strong>SSH-Key</strong></div><small>Für dauerhaften und produktiven Betrieb empfohlen.</small></label>
     <label class="ae-auth-option" id="passwordOption"><div><input type="radio" name="auth_mode" value="password"><strong>Passwort</strong></div><small>Praktisch für Demo/Bootstrap; Secret wird nach dem Job gelöscht.</small></label>
    </div>
    <div id="passwordFields" class="ae-hidden">
      <label class="form-label">SSH-Passwort</label>
      <input type="password" name="ssh_password" class="form-control" maxlength="1024" autocomplete="new-password" placeholder="nur für diesen Enrollment-Job">
      <div class="form-text">Nicht im Job-JSON, Auditlog oder Status gespeichert. Übergabe an SSH nur über einen File-Descriptor.</div>
    </div>
    <div class="form-check mt-2"><input class="form-check-input" type="checkbox" name="use_sudo" id="sudo"><label class="form-check-label" for="sudo">sudo -n verwenden</label></div>
    <div class="ae-note mt-1">Bei nicht-root Benutzern benötigt das Remote-Setup weiterhin passwortloses <code>sudo -n</code>.</div>
   </div>

   <div class="ae-section">
    <div class="ae-section-title"><span class="ae-section-no">3</span>Agent Identität</div>
    <div class="row g-2">
     <div class="col-md-6"><label class="form-label">Agent Bind-IP</label><input id="bindIp" name="bind_ip" class="form-control" required placeholder="192.168.1.21"><div id="bindIpWarning" class="ae-bind-warning"><i class="bi bi-exclamation-triangle-fill me-1"></i><span></span></div></div>
     <div class="col-md-6"><label class="form-label">Agent FQDN</label><input name="fqdn" class="form-control" required placeholder="mail01.example.internal"></div>
    </div>
   </div>

   <div class="ae-section">
    <div class="ae-section-title"><span class="ae-section-no">4</span>Zuordnung</div>
    <div class="row g-2">
     <div class="col-md-6"><label class="form-label">Gruppen</label><input name="groups" class="form-control" value="linux" placeholder="linux,mail"></div>
     <div class="col-md-6"><label class="form-label">Labels</label><input name="labels" class="form-control" placeholder="env=prod,role=mailrelay"></div>
     <div class="col-12"><div class="form-check"><input class="form-check-input" type="checkbox" name="canary" id="canary"><label class="form-check-label" for="canary">Als Canary-System registrieren</label></div></div>
    </div>
   </div>

   <div id="bootstrapKeyBox" class="ae-tech mb-3">
    <div class="ae-tech-label">Bootstrap Public Key · nur SSH-Key-Modus</div>
    <div id="pubkey" class="ae-key">wird geladen…</div>
   </div>
   <button class="btn btn-primary w-100" type="submit"><i class="bi bi-cloud-arrow-down me-1"></i>Agent installieren & registrieren</button>
  </form>
 </div>
</section>

<section class="ae-panel ae-status-panel">
 <div class="ae-panel-head"><span><i class="bi bi-activity me-1"></i>Enrollment Status</span><div class="ae-status-actions"><span class="ae-auto-label">automatisch aktualisiert</span><button type="button" id="expandJobs" class="btn btn-outline-secondary btn-sm" title="Alle Jobs öffnen"><i class="bi bi-arrows-expand me-1"></i>Alle öffnen</button><button type="button" id="collapseJobs" class="btn btn-outline-secondary btn-sm" title="Alle Jobs schliessen"><i class="bi bi-arrows-collapse me-1"></i>Alle schliessen</button></div></div>
 <div id="jobs" class="ae-jobs" tabindex="0" aria-label="Enrollment Jobs – eigener Scrollbereich"><div class="text-center text-body-secondary py-4">wird geladen…</div></div>
</section>
</div>
</div>
<script>
const CSRF=<?=json_encode($csrf,JSON_UNESCAPED_SLASHES)?>;
const esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
const state={passwordAvailable:false,authRestored:false,managerIp:'',bindDirty:false,openJobs:new Set(),jobsInitialized:false,deletedJobs:new Set()};
const ENROLL_STEPS=[
 ['queued','Job angenommen'],['hostkey','SSH Host-Key'],['ssh_auth','SSH Anmeldung'],
 ['remote_prepare','Ziel vorbereiten'],['bundle_transfer','Bundle übertragen'],['agent_install','Agent installieren'],
 ['registration_fetch','Registrierung abrufen'],['registration_import','Registrierung importieren'],['health_check','Health-Check']
];
const STAGE_LABEL=Object.fromEntries(ENROLL_STEPS);
function message(t,kind='info'){const e=document.getElementById('msg');e.textContent=t;e.className='alert alert-'+kind}
async function api(url,opt={}){const r=await fetch(url,{cache:'no-store',...opt});let j;try{j=await r.json()}catch{throw new Error(`HTTP ${r.status}: ungültige Serverantwort`)}if(!r.ok||!j.ok)throw new Error(j.error||`HTTP ${r.status}`);return j}
function stateLabel(s){return ({completed:'Erfolgreich',failed:'Fehler',running:'Läuft',queued:'Wartet'})[s]||s||'Wartet'}
function authLabel(m){return m==='password'?'Passwort':'SSH-Key'}
function fmtTime(v,onlyTime=false){if(!v)return '—';const d=new Date(v);if(Number.isNaN(d.getTime()))return String(v);return onlyTime?d.toLocaleTimeString('de-CH',{hour:'2-digit',minute:'2-digit',second:'2-digit'}):d.toLocaleString('de-CH',{day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'})}
function normalizedSteps(x){
 if(Array.isArray(x.steps)&&x.steps.length)return x.steps;
 const stateName=String(x.state||'queued');const current=String(x.stage||'queued');let idx=ENROLL_STEPS.findIndex(([id])=>id===current);if(idx<0)idx=0;
 return ENROLL_STEPS.map(([id,label],i)=>({id,label,state:stateName==='completed'?'completed':(i<idx?'completed':(i===idx?(stateName==='failed'?'failed':stateName==='queued'?'waiting':'running'):'pending'))}));
}
function stepIcon(s){return ({completed:'bi-check-circle-fill',running:'bi-arrow-repeat',failed:'bi-x-circle-fill',waiting:'bi-hourglass-split',pending:'bi-circle'})[s]||'bi-circle'}
function progressValue(x){const n=Number(x.progress_percent);if(Number.isFinite(n))return Math.max(0,Math.min(100,n));if(x.state==='completed')return 100;const idx=ENROLL_STEPS.findIndex(([id])=>id===(x.stage||'queued'));return idx<0?0:Math.round((idx/ENROLL_STEPS.length)*100)}
function renderEvents(x){
 let ev=Array.isArray(x.events)?x.events.slice(-10):[];
 if(!ev.length&&x.stage_message)ev=[{at:x.started_at||x.created_at||'',stage:x.stage||'queued',level:x.state==='failed'?'error':'info',message:x.stage_message}];
 if(!ev.length)return '';
 return `<div class="ae-eventlog"><div class="ae-eventlog-head"><span>Ablauf</span><span>letzte ${ev.length}</span></div>${ev.map(e=>`<div class="ae-event ${esc(e.level||'info')}"><span class="ae-event-time">${esc(fmtTime(e.at,true))}</span><span class="ae-event-stage">${esc(STAGE_LABEL[e.stage]||e.stage||'Status')}</span><span class="ae-event-message">${esc(e.message||'')}</span></div>`).join('')}</div>`;
}
function compactErrorText(v){
 const t=String(v||'').replace(/\x1b\[[0-?]*[ -\/]*[@-~]/g,'').replace(/\r/g,'\n').trim(); if(!t)return '';
 const errWord=/(?:error|fehler|failed|failure|fatal|not found|no such file|permission denied|denied|cannot|can't|unable|missing|invalid|syntax|traceback|command not found|nicht gefunden|fehlgeschlagen|konnte nicht|kann nicht|verweigert)/i;
 const infoNoise=/(?:vorhandene .* gesichert:|backup(?:[- ]datei)? .* (?:gesichert|erstellt)|sicherung .* erstellt)/i;
 const lines=t.split(/\n+/).map(x=>x.replace(/\x08/g,'').trim()).filter(x=>{
   if(!x||/^STD(?:OUT|ERR):$/.test(x)||/^Kommando fehlgeschlagen \(rc=\d+\):/.test(x)||/^command failed rc=/i.test(x)||infoNoise.test(x))return false;
   if(x.length>=8&&/^[\s.+'#=:_\-|\/\\<>*]+$/.test(x))return false;
   if(x.length>=20){const a=(x.match(/[A-Za-z0-9ÄÖÜäöüß]/g)||[]).length;if(a/x.length<0.12)return false;}
   return true;
 });
 if(!lines.length)return 'Enrollment fehlgeschlagen. Technische Details anzeigen.';
 const flagged=lines.filter(x=>errWord.test(x));
 const useful=(flagged.length?flagged[flagged.length-1]:lines[lines.length-1]);
 return useful.length>420?useful.slice(0,417)+'…':useful;
}
function renderFailure(x){
 if(String(x.state||'')!=='failed'||(!x.error&&!x.error_summary))return '';
 const short=String(x.error_summary||'').trim()||compactErrorText(x.error)||'Enrollment fehlgeschlagen.';
 const details=String(x.error||short);
 return `<div class="ae-error-summary"><div class="ae-error-title"><i class="bi bi-exclamation-octagon-fill"></i>Fehlerursache</div><div class="ae-error-text">${esc(short)}</div></div><details class="ae-error-details"><summary><i class="bi bi-terminal me-1"></i>Technische Fehlerdetails anzeigen</summary><pre>${esc(details)}</pre></details>`;
}
function renderJob(x,openDefault=false){
 const s=String(x.state||'queued');const steps=normalizedSteps(x);const pct=progressValue(x);const current=STAGE_LABEL[x.stage]||(s==='completed'?'Abgeschlossen':s==='failed'?'Fehlgeschlagen':'Job angenommen');
 const idx=steps.findIndex(st=>['running','waiting','failed'].includes(st.state));const stepText=s==='completed'?`${steps.length}/${steps.length}`:(idx>=0?`${idx+1}/${steps.length}`:`—/${steps.length}`);
 const result=x.registered_url?`<div class="ae-result success"><i class="bi bi-check-circle-fill me-1"></i>Registriert: ${esc(x.registered_url)}</div>`:'';
 let queueHint='';
 if(s==='queued'){
   let stale=false;
   const created=Date.parse(String(x.created_at||''));
   if(Number.isFinite(created)) stale=(Date.now()-created)>20000;
   queueHint=stale
     ? `<div class="ae-queue-hint ae-queue-stale"><i class="bi bi-exclamation-triangle me-1"></i>Job wartet länger als 20 Sekunden. Enrollment-Worker/Trigger prüfen. Der Fallback-Timer sollte spätestens nach 10 Sekunden übernehmen.</div>`
     : `<div class="ae-queue-hint"><i class="bi bi-hourglass-split me-1"></i>Der Job liegt in der Queue und wartet auf den Root-Worker <code>teko-agent-enrollment.service</code>.</div>`;
 }
 const openAttr=openDefault?' open':'';
 return `<details class="ae-job ${esc(s)}" data-job-id="${esc(x.id||'')}"${openAttr}>
  <summary class="ae-job-head"><div class="ae-job-summary-main"><span class="ae-job-toggle" aria-hidden="true"><i class="bi bi-chevron-right"></i></span><div class="ae-job-summary-text"><div class="ae-job-agent">${esc(x.fqdn||'—')}</div><div class="ae-job-time">${esc(fmtTime(x.created_at||x.started_at||x.completed_at))} <span class="ae-job-id ms-2">${esc(x.id||'')}</span></div></div></div><span class="ae-status ${esc(s)}">${esc(stateLabel(s))}</span></summary>
  <div class="ae-meta-strip">
   <div class="ae-meta-box"><div class="ae-meta-label">Agent</div><div class="ae-meta-value">${esc(x.bind_ip||'—')}</div></div>
   <div class="ae-meta-box"><div class="ae-meta-label">SSH Ziel</div><div class="ae-meta-value">${esc(x.ssh_user||'')}@${esc(x.ssh_host||'')}:${esc(x.ssh_port||'')}</div></div>
   <div class="ae-meta-box"><div class="ae-meta-label">Authentifizierung</div><div class="ae-meta-value">${esc(authLabel(x.auth_mode))}${x.use_sudo?' · sudo -n':''}</div></div>
   <div class="ae-meta-box"><div class="ae-meta-label">Gruppen</div><div class="ae-meta-value">${(x.groups||[]).map(g=>`<span class="badge text-bg-secondary me-1">${esc(g)}</span>`).join('')||'—'}</div></div>
  </div>
  <div class="ae-progress-wrap"><div class="ae-progress-head"><span class="ae-current-stage">${esc(current)}</span><span class="ae-progress-value">Schritt ${esc(stepText)} · ${pct}%</span></div><div class="ae-progress"><div class="ae-progress-bar" style="width:${pct}%"></div></div><div class="ae-stage-message">${esc(x.stage_message||'Status wird aktualisiert…')}</div></div>
  ${renderFailure(x)}
  <div class="ae-step-grid">${steps.map(st=>`<div class="ae-step ${esc(st.state||'pending')}" title="${esc(st.label||st.id)}"><i class="bi ${stepIcon(st.state)}"></i><span class="ae-step-label">${esc(st.label||STAGE_LABEL[st.id]||st.id)}</span></div>`).join('')}</div>
  ${queueHint}${renderEvents(x)}${result}
  <div class="ae-job-tools"><button type="button" class="btn btn-outline-danger btn-sm ae-delete-job" data-job-id="${esc(x.id||'')}" ${s==='running'?'disabled title="Laufende Jobs können nicht gelöscht werden"':''}><i class="bi bi-trash3 me-1"></i>Job löschen</button></div>
 </details>`;
}
function syncAuthMode(){
 const mode=document.querySelector('input[name="auth_mode"]:checked')?.value||'key';
 try{localStorage.setItem('tekoEnrollmentAuthMode',mode)}catch{}
 const box=document.getElementById('passwordFields');
 const input=document.querySelector('input[name="ssh_password"]');
 const fp=document.getElementById('hostKeyFingerprint');
 const fpHint=document.getElementById('hostKeyModeHint');
 const fpHelp=document.getElementById('hostKeyHelp');
 const keyBox=document.getElementById('bootstrapKeyBox');
 box.classList.toggle('ae-hidden',mode!=='password');
 input.required=mode==='password';
 fp.required=mode==='key';
 keyBox.classList.toggle('ae-hidden',mode!=='key');
 if(mode==='password'){
  fp.placeholder='optional – wird automatisch ermittelt';
  fpHint.textContent='optional bei Passwort';
  fpHint.className='badge text-bg-info ms-1';
  fpHelp.textContent='Optional. Ohne Fingerprint wird der SSH Host-Key beim ersten Enrollment automatisch erfasst und für diese Verbindung gepinnt (TOFU).';
 }else{
  fp.placeholder='SHA256:...';
  fpHint.textContent='Pflicht bei SSH-Key';
  fpHint.className='badge text-bg-secondary ms-1';
  fpHelp.textContent='Fingerprint des Zielsystems. Im SSH-Key-Modus erforderlich.';
  input.value='';
 }
}
function isIpLiteral(v){
 const s=String(v||'').trim();
 if(!s)return false;
 if(/^\d{1,3}(?:\.\d{1,3}){3}$/.test(s))return s.split('.').every(x=>Number(x)>=0&&Number(x)<=255);
 return s.includes(':') && /^[0-9A-Fa-f:]+$/.test(s);
}
function syncBindFromSsh(){
 const ssh=document.getElementById('sshHost');const bind=document.getElementById('bindIp');if(!ssh||!bind)return;
 const host=ssh.value.trim();
 if(isIpLiteral(host) && (!state.bindDirty || !bind.value.trim() || bind.value.trim()===state.managerIp)) bind.value=host;
 validateBindRelation();
}
function validateBindRelation(){
 const ssh=document.getElementById('sshHost');const bind=document.getElementById('bindIp');const box=document.getElementById('bindIpWarning');
 if(!ssh||!bind||!box)return true;
 const host=ssh.value.trim(), val=bind.value.trim();
 const bad=isIpLiteral(host)&&host!==state.managerIp&&val===state.managerIp;
 box.classList.toggle('show',bad);
 box.querySelector('span').textContent=bad?`Die Agent Bind-IP ${val} ist die Manager-IP. Für das SSH-Ziel ${host} ist normalerweise ${host} erforderlich.`:'';
 return !bad;
}
async function deleteJob(id){
 if(!id)return;
 if(!confirm(`Enrollment-Job ${id} wirklich löschen?\n\nStatus-, Queue- und temporäre Secret-Dateien dieses Jobs werden vom Root-Worker entfernt.`))return;
 try{
   await api('agent_enrollment.php?api=delete_job',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({csrf_token:CSRF,action:'delete_job',job_id:id})});
   state.deletedJobs.add(id);state.openJobs.delete(id);
   document.querySelector(`#jobs details.ae-job[data-job-id="${CSS.escape(id)}"]`)?.remove();
   message(`Löschauftrag für Enrollment-Job ${id} wurde angenommen.`,'success');await load();
 }catch(e){message(e.message,'danger')}
}

async function load(){
 try{
  const j=await api('agent_enrollment.php?api=summary');
  state.passwordAvailable=Boolean(j.password_auth_available);
  state.managerIp=String(j.manager_ip||'');
  document.getElementById('managerIp').textContent=state.managerIp||'—';
  document.getElementById('authCapability').textContent=state.passwordAvailable?'SSH-Key + Passwort':'nur SSH-Key';
  document.getElementById('pubkey').textContent=j.public_key||'Public Key nicht gefunden';
  const passRadio=document.querySelector('input[name="auth_mode"][value="password"]');
  passRadio.disabled=!state.passwordAvailable;
  document.getElementById('passwordOption').title=state.passwordAvailable?'':'sshpass ist auf diesem Manager nicht installiert';
  if(!state.authRestored){
   let wanted='key';try{wanted=localStorage.getItem('tekoEnrollmentAuthMode')||'key'}catch{}
   if(wanted==='password'&&state.passwordAvailable)passRadio.checked=true;else document.querySelector('input[name="auth_mode"][value="key"]').checked=true;
   state.authRestored=true;syncAuthMode();
  }
  if(!state.passwordAvailable && passRadio.checked){document.querySelector('input[name="auth_mode"][value="key"]').checked=true;syncAuthMode()}
  const rows=(j.jobs||[]).filter(row=>!state.deletedJobs.has(String(row.id||'')));
  document.getElementById('jobCount').textContent=String(rows.length);
  const jobsEl=document.getElementById('jobs');const oldScroll=jobsEl.scrollTop;
  if(!state.jobsInitialized && rows.length){state.openJobs.add(String(rows[0].id||''));state.jobsInitialized=true}
  jobsEl.innerHTML=rows.length?rows.map(row=>renderJob(row,state.openJobs.has(String(row.id||'')))).join(''):'<div class="text-center text-body-secondary py-4">Noch keine Enrollment-Jobs.</div>';
  jobsEl.scrollTop=oldScroll;
 }catch(e){message(e.message,'danger')}
}
document.getElementById('refresh').addEventListener('click',load);
document.getElementById('expandJobs').addEventListener('click',()=>{document.querySelectorAll('#jobs details.ae-job').forEach(x=>{x.open=true;const id=String(x.dataset.jobId||'');if(id)state.openJobs.add(id)})});
document.getElementById('collapseJobs').addEventListener('click',()=>{document.querySelectorAll('#jobs details.ae-job').forEach(x=>x.open=false);state.openJobs.clear()});
document.getElementById('jobs').addEventListener('toggle',e=>{const d=e.target.closest?.('details.ae-job');if(!d||e.target!==d)return;const id=String(d.dataset.jobId||'');if(!id)return;if(d.open)state.openJobs.add(id);else state.openJobs.delete(id)},true);
document.querySelectorAll('input[name="auth_mode"]').forEach(x=>x.addEventListener('change',syncAuthMode));
document.getElementById('jobs').addEventListener('click',e=>{const b=e.target.closest('.ae-delete-job');if(!b)return;e.preventDefault();e.stopPropagation();deleteJob(String(b.dataset.jobId||''));});
document.getElementById('sshHost').addEventListener('input',syncBindFromSsh);
document.getElementById('sshHost').addEventListener('change',syncBindFromSsh);
document.getElementById('bindIp').addEventListener('input',()=>{state.bindDirty=true;validateBindRelation()});
document.getElementById('form').addEventListener('submit',async e=>{
 e.preventDefault();
 const f=new FormData(e.currentTarget);const mode=String(f.get('auth_mode')||'key');
 if(mode==='password'&&!state.passwordAvailable){message('Passwort-Enrollment ist nicht verfügbar: sshpass fehlt.','danger');return}
 syncBindFromSsh();
 if(!validateBindRelation()){message('Agent Bind-IP prüfen: Sie entspricht der Manager-IP, obwohl das SSH-Ziel eine andere IP hat.','warning');document.getElementById('bindIp').focus();return}
 const body={
  csrf_token:CSRF,ssh_host:f.get('ssh_host'),ssh_port:Number(f.get('ssh_port')),ssh_user:f.get('ssh_user'),auth_mode:mode,
  ssh_password:mode==='password'?f.get('ssh_password'):'',use_sudo:f.get('use_sudo')==='on',expected_host_key_sha256:f.get('expected_host_key_sha256'),
  bind_ip:f.get('bind_ip'),fqdn:f.get('fqdn'),groups:f.get('groups'),labels:f.get('labels'),canary:f.get('canary')==='on'
 };
 try{
  const j=await api('agent_enrollment.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const pwd=document.querySelector('input[name="ssh_password"]');if(pwd)pwd.value='';
  message(`Enrollment Job ${j.job_id} wurde gestartet.`,'success');await load();
 }catch(err){message(err.message,'danger')}
});
load();setInterval(load,3000);
</script>
<?php require MMBB_UI.'/includes/js.php'; ?>
</body></html>
