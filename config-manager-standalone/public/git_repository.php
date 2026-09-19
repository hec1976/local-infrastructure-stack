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
if (!headers_sent()) { header('X-Content-Type-Options: nosniff'); header('Cache-Control: no-store, no-cache, must-revalidate'); }

function gr_h(mixed $v): string { return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function gr_json(array $p, int $status=200): never { http_response_code($status); header('Content-Type: application/json; charset=utf-8'); echo json_encode($p, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_INVALID_UTF8_SUBSTITUTE) ?: '{"ok":false}'; exit; }
function gr_actor(): string { foreach (['user_id','username','user','login'] as $k) { $v=trim((string)($_SESSION[$k]??'')); if ($v!=='') return substr(preg_replace('/[\x00-\x1f\x7f]/','?',$v)??'portal-user',0,128); } return 'portal-user'; }
function gr_controller(array $server): ConfigManagerController { return new ConfigManagerController(new ConfigManagerService(new ConfigManagerRepository($server))); }
function gr_idx(array $servers, mixed $v): int { $i=filter_var($v,FILTER_VALIDATE_INT); if ($i===false || !array_key_exists((int)$i,$servers)) throw new InvalidArgumentException('Ungültiger Serverindex.'); return (int)$i; }
function gr_csrf(): void { $a=(string)($_SERVER['HTTP_X_CSRF_TOKEN']??''); $b=(string)($_SESSION['csrf_token']??''); if ($a===''||$b===''||!hash_equals($b,$a)) throw new RuntimeException('CSRF-Prüfung fehlgeschlagen.',403); }
function gr_body(): array { $raw=file_get_contents('php://input'); if (!is_string($raw)||$raw==='') throw new InvalidArgumentException('Leerer JSON-Body.'); if (strlen($raw)>3*1024*1024) throw new LengthException('JSON-Body ist zu gross.'); $d=json_decode($raw,true); if (!is_array($d)) throw new InvalidArgumentException('Ungültiger JSON-Body.'); return $d; }

$configFile=__DIR__.'/../config/config.php';
try { $servers=cm_load_config_manager_servers($configFile); } catch (Throwable $e) { http_response_code(500); exit('Config-Manager-Konfiguration konnte nicht geladen werden: '.gr_h($e->getMessage())); }
$portalConfig=require $configFile;
$requiredService=trim((string)($portalConfig['git_upload']['required_service']??'')) ?: 'ConfigManager';
if (function_exists('mmbb_has_service') && !mmbb_has_service($requiredService)) { http_response_code(403); exit('Keine Berechtigung für Git Repository Browser.'); }

$api=trim((string)($_GET['api']??''));
if ($api!=='') {
    try {
        if ($api==='repositories') { $i=gr_idx($servers,$_GET['server_idx']??0); gr_json(['ok'=>true,'repositories'=>gr_controller($servers[$i])->getGitUploadRepositories(!empty($_GET['refresh']))]); }
        if ($api==='branches') { $i=gr_idx($servers,$_GET['server_idx']??0); $r=gr_controller($servers[$i])->getGitUploadBranches(trim((string)($_GET['owner']??'')),trim((string)($_GET['repository']??''))); gr_json(['ok'=>true]+$r); }
        if ($api==='tree') { $i=gr_idx($servers,$_GET['server_idx']??0); $r=gr_controller($servers[$i])->getGitRepositoryTree((string)($_GET['owner']??''),(string)($_GET['repository']??''),(string)($_GET['branch']??''),(string)($_GET['path']??'')); gr_json($r); }
        if ($api==='file') { $i=gr_idx($servers,$_GET['server_idx']??0); $r=gr_controller($servers[$i])->getGitRepositoryFile((string)($_GET['owner']??''),(string)($_GET['repository']??''),(string)($_GET['branch']??''),(string)($_GET['path']??'')); gr_json($r); }
        if ($api==='commits') { $i=gr_idx($servers,$_GET['server_idx']??0); $r=gr_controller($servers[$i])->getGitRepositoryCommits((string)($_GET['owner']??''),(string)($_GET['repository']??''),(string)($_GET['branch']??''),(string)($_GET['path']??''),(int)($_GET['limit']??30)); gr_json($r); }
        if ($api==='compare') { $i=gr_idx($servers,$_GET['server_idx']??0); $r=gr_controller($servers[$i])->getGitRepositoryCompare((string)($_GET['owner']??''),(string)($_GET['repository']??''),(string)($_GET['base']??''),(string)($_GET['head']??'')); gr_json($r); }
        if ($api==='save') { gr_csrf(); $p=gr_body(); $i=gr_idx($servers,$p['server_idx']??0); unset($p['server_idx']); $r=gr_controller($servers[$i])->updateGitRepositoryFile($p,gr_actor()); gr_json($r); }
        throw new InvalidArgumentException('Unbekannte API-Aktion.');
    } catch (Throwable $e) { $code=(int)$e->getCode(); if ($code<400||$code>599) $code=400; gr_json(['ok'=>false,'error'=>$e->getMessage()],$code); }
}

$selfUrl=(string)($_SERVER['SCRIPT_NAME']??'git_repository.php'); if ($selfUrl===''||str_contains($selfUrl,"\0")) $selfUrl='git_repository.php';
$serverOptions=[]; foreach ($servers as $i=>$s) $serverOptions[]=['idx'=>$i,'name'=>(string)$s['name']];
?>
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Git Repository Browser</title>
<?php require MMBB_UI . '/includes/css.php'; ?><link rel="stylesheet" href="assets/css/git_repository.css"></head><body>
<?php require MMBB_UI . '/navigation.php'; ?><?php require MMBB_UI . '/sidebar.php'; ?>
<div class="container mmbb-main py-3 git-repository-page">
<?php require MMBB_UI . '/module_header.php'; ?>
<div id="grMessage" class="alert d-none" role="alert"></div>
<section class="card shadow-sm mb-3"><div class="card-header mmbb-card-header"><i class="bi bi-git me-1"></i> Repository auswählen</div><div class="card-body"><div class="row g-3 align-items-end">
<div class="col-12 col-md-3"><label class="form-label fw-semibold">Config Agent</label><select id="grServer" class="form-select form-select-sm"><?php foreach($serverOptions as $o): ?><option value="<?= (int)$o['idx'] ?>"><?= gr_h($o['name']) ?></option><?php endforeach; ?></select></div>
<div class="col-12 col-md-5"><label class="form-label fw-semibold">Repository</label><select id="grRepo" class="form-select form-select-sm" disabled><option>Repositorys werden geladen …</option></select></div>
<div class="col-12 col-md-3"><label class="form-label fw-semibold">Branch</label><select id="grBranch" class="form-select form-select-sm" disabled><option>Branch auswählen …</option></select></div>
<div class="col-12 col-md-1 d-grid"><button id="grReload" class="btn btn-outline-secondary btn-sm" title="Neu laden"><i class="bi bi-arrow-clockwise"></i></button></div>
</div></div></section>

<section id="grWorkspace" class="gr-workspace">
<div class="card shadow-sm gr-files-card"><div class="card-header mmbb-card-header d-flex justify-content-between align-items-center"><span><i class="bi bi-folder2-open me-1"></i> Inhalt</span><span id="grPath" class="small text-body-secondary">/</span></div><div class="card-body p-0"><div id="grBreadcrumb" class="gr-breadcrumb"></div><div id="grTree" class="gr-tree"><div class="gr-empty">Repository auswählen.</div></div></div></div>
<div class="card shadow-sm gr-editor-card"><div class="card-header mmbb-card-header d-flex justify-content-between align-items-center gap-2"><div class="min-w-0"><i class="bi bi-file-earmark-code me-1"></i><strong id="grFileTitle">Datei</strong></div><div class="d-flex gap-2 flex-wrap justify-content-end"><button id="grHistoryToggle" class="btn btn-outline-secondary btn-sm" type="button"><i class="bi bi-clock-history me-1"></i>Historie</button><button id="grEdit" class="btn btn-outline-primary btn-sm" disabled><i class="bi bi-pencil me-1"></i>Bearbeiten</button><button id="grCancel" class="btn btn-outline-secondary btn-sm d-none">Abbrechen</button></div></div><div class="card-body gr-editor-body"><div class="gr-editor-meta"><span id="grFileMeta" class="small text-body-secondary"></span><span id="grCursor" class="small text-body-secondary">Zeile 1, Spalte 1</span></div><div id="grAce" class="gr-ace-editor" aria-label="Repository-Dateieditor">Datei auswählen.</div><div id="grSavePanel" class="gr-save-panel d-none"><input id="grCommitMessage" class="form-control form-control-sm" maxlength="500" placeholder="Commit-Nachricht"><button id="grSave" class="btn btn-success btn-sm"><i class="bi bi-check2-circle me-1"></i>Speichern & Commit</button></div></div></div>
<div id="grHistoryCard" class="card shadow-sm gr-history-card d-none"><div class="card-header mmbb-card-header d-flex justify-content-between align-items-center"><span><i class="bi bi-clock-history me-1"></i> Historie</span><div class="d-flex gap-2"><button id="grHistoryReload" class="btn btn-outline-secondary btn-sm" title="Historie neu laden"><i class="bi bi-arrow-clockwise"></i></button><button id="grHistoryClose" class="btn btn-outline-secondary btn-sm" type="button" title="Historie schliessen"><i class="bi bi-x-lg"></i></button></div></div><div class="card-body p-0"><div id="grCommits" class="gr-commits"><div class="gr-empty">Repository auswählen.</div></div></div></div>
</section>

<section class="card shadow-sm mt-3"><div class="card-header mmbb-card-header"><i class="bi bi-file-diff me-1"></i> Änderungen</div><div class="card-body"><div id="grDiffEmpty" class="text-body-secondary">In der Historie bei einem Commit „Änderungen“ auswählen.</div><div id="grDiff" class="d-none"></div></div></section>
</div>
<script>window.GIT_REPOSITORY_PAGE=<?= json_encode(['endpoint'=>$selfUrl,'csrfToken'=>$csrfToken,'servers'=>$serverOptions],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES) ?>;</script>
<?php require MMBB_UI . '/includes/js.php'; ?><script src="assets/js/git_repository.js?v=3.2.0"></script></body></html>
