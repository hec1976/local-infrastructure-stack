<?php
declare(strict_types=1);
// Ersatz für MMBB_UI/navigation.php – Topbar mit Benutzer/Logout.
$standaloneCurrentUser = $_SESSION['standalone_user'] ?? 'unbekannt';
?>
<nav class="navbar navbar-expand-lg navbar-dark bg-dark mmbb-topbar">
  <div class="container-fluid">
    <span class="navbar-brand">
      <i class="bi bi-hdd-network me-2"></i>Config Manager <span class="badge bg-secondary ms-1">standalone</span>
    </span>
    <div class="d-flex align-items-center text-light gap-3 ms-auto">
      <span><i class="bi bi-person-circle me-1"></i><?= htmlspecialchars($standaloneCurrentUser, ENT_QUOTES, 'UTF-8') ?></span>
      <a href="password_change.php" class="btn btn-sm btn-outline-light"><i class="bi bi-key me-1"></i>Passwort ändern</a>
      <form method="post" action="login.php" class="m-0">
        <input type="hidden" name="csrf_token" value="<?= htmlspecialchars((string)($_SESSION['csrf_token'] ?? ''), ENT_QUOTES, 'UTF-8') ?>">
        <input type="hidden" name="logout" value="1">
        <button type="submit" class="btn btn-sm btn-outline-light">
          <i class="bi bi-box-arrow-right me-1"></i>Abmelden
        </button>
      </form>
    </div>
  </div>
</nav>
