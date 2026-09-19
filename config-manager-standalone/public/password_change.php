<?php
declare(strict_types=1);
require_once __DIR__ . '/../standalone/bootstrap.php';

if (!mmbb_has_service('ConfigManager')) {
    http_response_code(403);
    echo 'Forbidden';
    exit;
}

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}
if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

function pc_h(mixed $v): string {
    return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

$user = trim((string)($_SESSION['standalone_user'] ?? ''));
$error = '';
$success = '';
$required = !empty($_SESSION['standalone_must_change_password']) || (string)($_GET['required'] ?? '') === '1';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $csrf = (string)($_POST['csrf_token'] ?? '');
    $current = (string)($_POST['current_password'] ?? '');
    $new1 = (string)($_POST['new_password'] ?? '');
    $new2 = (string)($_POST['new_password_confirm'] ?? '');

    if (!hash_equals((string)$_SESSION['csrf_token'], $csrf)) {
        $error = 'CSRF-Prüfung fehlgeschlagen.';
    } elseif ($user === '') {
        $error = 'Kein angemeldeter Benutzer gefunden.';
    } elseif (strlen($new1) < 12) {
        $error = 'Das neue Passwort muss mindestens 12 Zeichen lang sein.';
    } elseif ($new1 !== $new2) {
        $error = 'Die neuen Passwörter stimmen nicht überein.';
    } elseif ($new1 === $current) {
        $error = 'Das neue Passwort muss sich vom bisherigen Passwort unterscheiden.';
    } else {
        $path = standalone_users_path();
        $users = standalone_users_load();
        $entry = $users[$user] ?? null;
        $oldHash = is_array($entry) ? (string)($entry['password_hash'] ?? '') : '';

        if ($oldHash === '' || !password_verify($current, $oldHash)) {
            $error = 'Das bisherige Passwort ist nicht korrekt.';
            mmbb_audit_write('password_change', $user, ['reason' => 'current_password_invalid'], 'password_change.php', 'failed');
        } else {
            $newHash = password_hash($new1, PASSWORD_BCRYPT, ['cost' => 12]);
            if (!is_string($newHash) || $newHash === '') {
                $error = 'Passwort-Hash konnte nicht erzeugt werden.';
            } else {
                $users[$user]['password_hash'] = $newHash;
                $users[$user]['must_change_password'] = false;
                $dir = dirname($path);
                $tmp = tempnam($dir, '.users.json.tmp.');
                if ($tmp === false) {
                    $error = 'Temporäre Benutzerdatei konnte nicht angelegt werden.';
                } else {
                    $json = json_encode($users, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
                    if ($json === false || file_put_contents($tmp, $json . "\n", LOCK_EX) === false) {
                        @unlink($tmp);
                        $error = 'Benutzerdaten konnten nicht geschrieben werden.';
                    } else {
                        @chmod($tmp, 0640);
                        if (!@rename($tmp, $path)) {
                            @unlink($tmp);
                            $error = 'Benutzerdaten konnten nicht atomar ersetzt werden.';
                        } else {
                            $success = 'Passwort wurde geändert.';
                            $_SESSION['standalone_must_change_password'] = false;
                            mmbb_audit_write('password_change', $user, ['user' => $user], 'password_change.php', 'ok');

                        }
                    }
                }
            }
        }
    }
}
?>
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Passwort ändern</title>
  <?php require MMBB_UI . '/includes/css.php'; ?>
</head>
<body>
<?php require MMBB_UI . '/navigation.php'; require MMBB_UI . '/sidebar.php'; ?>
<div class="container mmbb-main py-3 mmbb-page">
  <?php require MMBB_UI . '/module_header.php'; ?>

  <div class="row justify-content-start">
    <div class="col-xl-7 col-lg-8">
      <?php if ($required && $success === ''): ?>
        <div class="alert alert-warning"><strong>Erstlogin:</strong> Das Initialpasswort muss jetzt geändert werden, bevor der Config Manager verwendet werden kann.</div>
      <?php endif; ?>
      <?php if ($error !== ''): ?>
        <div class="alert alert-danger"><?= pc_h($error) ?></div>
      <?php endif; ?>
      <?php if ($success !== ''): ?>
        <div class="alert alert-success"><?= pc_h($success) ?></div>
      <?php endif; ?>

      <div class="card shadow-sm border-0">
        <div class="card-header bg-light fw-semibold">Lokales Config-Manager-Passwort</div>
        <div class="card-body">
          <div class="mb-3 small text-muted">Benutzer: <strong><?= pc_h($user) ?></strong></div>
          <form method="post" autocomplete="off">
            <input type="hidden" name="csrf_token" value="<?= pc_h((string)$_SESSION['csrf_token']) ?>">
            <div class="mb-3">
              <label class="form-label fw-semibold" for="current_password">Bisheriges Passwort</label>
              <input class="form-control" id="current_password" name="current_password" type="password" required autocomplete="current-password">
            </div>
            <div class="mb-3">
              <label class="form-label fw-semibold" for="new_password">Neues Passwort</label>
              <input class="form-control" id="new_password" name="new_password" type="password" minlength="12" required autocomplete="new-password">
              <div class="form-text">Mindestens 12 Zeichen. Speicherung ausschliesslich als bcrypt-Hash.</div>
            </div>
            <div class="mb-4">
              <label class="form-label fw-semibold" for="new_password_confirm">Neues Passwort bestätigen</label>
              <input class="form-control" id="new_password_confirm" name="new_password_confirm" type="password" minlength="12" required autocomplete="new-password">
            </div>
            <button class="btn btn-primary" type="submit"><i class="bi bi-key me-1"></i>Passwort ändern</button>
          </form>
        </div>
      </div>
    </div>
  </div>
</div>
<?php require MMBB_UI . '/includes/js.php'; ?>
</body>
</html>
