<?php
declare(strict_types=1);
// Ersatz für MMBB_UI/sidebar.php – baut die linke Navigation aus
// config/module_navigation.json auf (unverändert aus dem MMBB-Projekt
// übernommen, nur der Renderer ist neu).

$standaloneNavFile = __DIR__ . '/../../config/module_navigation.json';
$standaloneNav = [];
if (is_file($standaloneNavFile)) {
    $decoded = json_decode((string)file_get_contents($standaloneNavFile), true);
    if (is_array($decoded) && !empty($decoded['items']) && is_array($decoded['items'])) {
        $standaloneNav = $decoded['items'];
    }
}

usort($standaloneNav, fn($a, $b) => ($a['order'] ?? 0) <=> ($b['order'] ?? 0));

$standaloneGroups = [];
foreach ($standaloneNav as $item) {
    if (empty($item['enabled'])) {
        continue;
    }
    $group = (string)($item['group'] ?? 'Weitere');
    $standaloneGroups[$group][] = $item;
}

$standaloneCurrentScript = basename((string)($_SERVER['SCRIPT_NAME'] ?? ''));
?>
<div class="mmbb-shell d-flex align-items-start">
<div class="offcanvas-lg offcanvas-start bg-white border-end mmbb-sidebar" tabindex="-1" id="mmbbSidebar">
  <div class="offcanvas-body d-flex flex-column p-3">
    <?php foreach ($standaloneGroups as $groupName => $items): ?>
      <div class="mb-4">
        <div class="text-uppercase text-muted small fw-semibold mb-2 mmbb-nav-group"><?= htmlspecialchars($groupName, ENT_QUOTES, 'UTF-8') ?></div>
        <ul class="nav nav-pills flex-column gap-1">
          <?php foreach ($items as $item):
            $href = htmlspecialchars((string)($item['href'] ?? '#'), ENT_QUOTES, 'UTF-8');
            $isActive = $standaloneCurrentScript === (($item['href'] ?? '') . '.php')
                || ($standaloneCurrentScript === 'index.php' && ($item['href'] ?? '') === 'index');
          ?>
            <li class="nav-item">
              <a class="nav-link d-flex align-items-center gap-2 <?= $isActive ? 'active' : 'link-dark' ?>" href="<?= $href ?>.php">
                <i class="<?= htmlspecialchars((string)($item['icon'] ?? 'bi bi-dot'), ENT_QUOTES, 'UTF-8') ?>"></i>
                <?= htmlspecialchars((string)($item['label'] ?? $href), ENT_QUOTES, 'UTF-8') ?>
              </a>
            </li>
          <?php endforeach; ?>
        </ul>
      </div>
    <?php endforeach; ?>
  </div>
</div>
<div class="mmbb-content flex-grow-1 min-w-0">
