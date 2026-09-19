<?php

declare(strict_types=1);

require_once __DIR__ . '/../standalone/env.php';
require_once __DIR__ . '/../standalone/audit.php';
require_once __DIR__ . '/../standalone/auth.php';

if (session_status() === PHP_SESSION_NONE) {
    ini_set('session.use_strict_mode', '1');
    ini_set('session.use_only_cookies', '1');
    ini_set('session.cookie_httponly', '1');
    ini_set('session.cookie_secure', '1');
    ini_set('session.cookie_samesite', 'Strict');
    session_start();
}

if (!headers_sent()) {
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: DENY');
}

if (!isset($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}
$csrf_token = (string)$_SESSION['csrf_token'];

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['logout'])) {
    $postedToken = (string)($_POST['csrf_token'] ?? '');
    if ($postedToken === '' || !hash_equals($csrf_token, $postedToken)) {
        http_response_code(400);
        exit('Invalid CSRF token');
    }
    if (!empty($_SESSION['standalone_user'])) {
        mmbb_audit_write('logout', (string)$_SESSION['standalone_user'], [], 'login.php', 'ok');
    }
    standalone_auth_logout();
    header('Location: login.php');
    exit;
}

$error = '';
$redirect = (string)($_GET['redirect'] ?? $_POST['redirect'] ?? '');
if (
    $redirect !== ''
    && (
        !str_starts_with($redirect, '/')
        || str_starts_with($redirect, '//')
        || preg_match('/[\\r\\n]/', $redirect)
    )
) {
    $redirect = ''; // ausschließlich interne absolute Pfade erlauben
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $postedToken = (string)($_POST['csrf_token'] ?? '');
    if (!hash_equals($csrf_token, $postedToken)) {
        $error = 'Sitzung abgelaufen, bitte erneut versuchen.';
    } else {
        $username = (string)($_POST['username'] ?? '');
        $password = (string)($_POST['password'] ?? '');

        if (standalone_auth_attempt($username, $password)) {
            mmbb_audit_write('login_success', $username, [], 'login.php', 'ok');
            if (!empty($_SESSION['standalone_must_change_password'])) {
                header('Location: password_change.php?required=1');
            } else {
                header('Location: ' . ($redirect !== '' ? $redirect : 'index.php'));
            }
            exit;
        }

        mmbb_audit_write('login_failed', $username, [], 'login.php', 'error');
        $error = 'Benutzername oder Passwort falsch.';
    }
}

function h(mixed $v): string
{
    return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}
?>
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <title>Anmeldung – Config Manager</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="assets/vendor/inter/inter-local.css">
  <link rel="stylesheet" href="assets/vendor/bootstrap/bootstrap.min.css">
  <link rel="stylesheet" href="assets/vendor/bootstrap-icons/bootstrap-icons.min.css">
  <link rel="stylesheet" href="assets/standalone.css?v=3.20.3">
</head>
<body class="bg-dark d-flex align-items-center" style="min-height:100vh;">
<div class="container mmbb-login-shell">
  <div class="card shadow-sm mmbb-login-card">
    <div class="card-body p-4">
      <h1 class="h4 mb-3 text-center"><i class="bi bi-hdd-network me-2"></i>Config Manager</h1>
      <?php if ($error !== ''): ?>
        <div class="alert alert-danger py-2"><?= h($error) ?></div>
      <?php endif; ?>
      <form method="post" autocomplete="off">
        <input type="hidden" name="csrf_token" value="<?= h($csrf_token) ?>">
        <input type="hidden" name="redirect" value="<?= h($redirect) ?>">
        <div class="mb-3">
          <label for="username" class="form-label">Benutzername</label>
          <input type="text" class="form-control" id="username" name="username" required autofocus>
        </div>
        <div class="mb-3">
          <label for="password" class="form-label">Passwort</label>
          <input type="password" class="form-control" id="password" name="password" required>
        </div>
        <button type="submit" class="btn btn-primary w-100">Anmelden</button>
      </form>
    </div>
  </div>
</div>
</body>
</html>
