<?php
declare(strict_types=1);
$current = basename((string)($_SERVER['SCRIPT_NAME'] ?? ''));
$tabs = [
    ['href'=>'managed_hosts.php','label'=>'Übersicht','icon'=>'bi bi-hdd-rack'],
    ['href'=>'agent_enrollment.php','label'=>'Enrollment','icon'=>'bi bi-pc-display-horizontal'],
    ['href'=>'client_baseline.php','label'=>'Baseline','icon'=>'bi bi-layers'],
    ['href'=>'server_management.php','label'=>'Registry','icon'=>'bi bi-server'],
];
?>
<nav class="mb-3" aria-label="Managed Hosts Bereiche">
  <div class="nav nav-tabs flex-wrap">
    <?php foreach ($tabs as $tab): $active = $current === $tab['href']; ?>
      <a class="nav-link <?= $active ? 'active fw-semibold' : '' ?>" href="<?= htmlspecialchars($tab['href'], ENT_QUOTES, 'UTF-8') ?>">
        <i class="<?= htmlspecialchars($tab['icon'], ENT_QUOTES, 'UTF-8') ?> me-1"></i><?= htmlspecialchars($tab['label'], ENT_QUOTES, 'UTF-8') ?>
      </a>
    <?php endforeach; ?>
  </div>
</nav>
