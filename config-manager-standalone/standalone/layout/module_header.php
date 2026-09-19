<?php
declare(strict_types=1);
// Einheitlicher Seitenkopf fuer alle Config-Manager-Seiten.

$standaloneNavFile = __DIR__ . '/../../config/module_navigation.json';
$standaloneModuleLabel = 'Config Manager';
$standalonePageLabel = '';
$standalonePageIcon = 'bi bi-grid';
$standalonePageKey = '';

if (is_file($standaloneNavFile)) {
    $decoded = json_decode((string)file_get_contents($standaloneNavFile), true);
    if (is_array($decoded)) {
        $standaloneModuleLabel = (string)($decoded['label'] ?? $standaloneModuleLabel);
        $standaloneCurrentScript = basename((string)($_SERVER['SCRIPT_NAME'] ?? ''));
        foreach ((array)($decoded['items'] ?? []) as $item) {
            $href = (string)($item['href'] ?? '');
            if ($href . '.php' === $standaloneCurrentScript) {
                $standalonePageLabel = (string)($item['label'] ?? '');
                $standalonePageIcon = (string)($item['icon'] ?? $standalonePageIcon);
                $standalonePageKey = (string)($item['key'] ?? '');
                break;
            }
        }
    }
}

$standalonePageDescriptions = [
    'operations' => 'Health, Abhängigkeiten, Runtime/Sollzustand, Backups und Audit zentral überwachen.',
    'overview' => 'Server, Services und verwaltete Konfigurationen im Überblick.',
    'configs_editor' => 'Verwaltete Konfigurationsdateien zentral bearbeiten und sichern.',
    'configdiff' => 'Konfigurationen direkt vergleichen und Unterschiede nachvollziehen.',
    'git_config_editor' => 'Deployment-Profile verwalten, validieren und versionieren.',
    'git_deploy_overview' => 'Deployment-Status und verfügbare Versionen zentral überblicken.',
    'git_deploy' => 'Versionierte Pakete kontrolliert auf ausgewählte Systeme ausrollen.',
    'git_repository' => 'Repository-Inhalte, Commit-Historie und Änderungen direkt prüfen und Textdateien kontrolliert bearbeiten.',
    'git_upload' => 'Dateien und Verzeichnisse strukturiert in Git-Repositories übernehmen.',
    'desired_state' => 'Policies, Git-Sollzustand und Compliance der verwalteten Systeme zentral prüfen.',
    'managed_hosts' => 'Lifecycle verwalteter Hosts: Enrollment, Baseline, Registry und Übergang ins Monitoring.',
    'agent_enrollment' => 'Neue Hosts sicher aufnehmen und den Config Agent installieren bzw. registrieren.',
    'client_baseline' => 'Generische Host-Baseline aus Config Agent, Monit und Grafana Alloy installieren und grundkonfigurieren.',
    'server_management' => 'Registrierte Hosts, Gruppen, Labels und Agent-Zugriff in der Registry verwalten.',
    'package_management' => 'Pakete kontrolliert auf einzelnen Servern, Gruppen oder Canary-Systemen verwalten.',
    'monit_status' => 'Zentraler Server-Health-Status. Monit wird über den Config Agent lokal ausgelesen und nicht direkt exponiert.',
    'modsecurity' => 'Apache WAF und OWASP CRS zentral installieren, prüfen und sicher konfigurieren.',
    'auditlog' => 'Änderungen und administrative Aktionen nachvollziehbar protokollieren.',
    'password_change' => 'Passwort des aktuell angemeldeten lokalen Config-Manager-Benutzers ändern.',
];
$standalonePageDescription = (string)($standalonePageDescriptions[$standalonePageKey] ?? '');
?>
<header class="mmbb-module-header">
  <nav aria-label="breadcrumb" class="mmbb-module-breadcrumb">
    <ol class="breadcrumb mb-0">
      <li class="breadcrumb-item"><?= htmlspecialchars($standaloneModuleLabel, ENT_QUOTES, 'UTF-8') ?></li>
      <?php if ($standalonePageLabel !== ''): ?>
        <li class="breadcrumb-item active" aria-current="page"><?= htmlspecialchars($standalonePageLabel, ENT_QUOTES, 'UTF-8') ?></li>
      <?php endif; ?>
    </ol>
  </nav>

  <div class="mmbb-page-heading">
    <div class="mmbb-page-heading-icon" aria-hidden="true">
      <i class="<?= htmlspecialchars($standalonePageIcon, ENT_QUOTES, 'UTF-8') ?>"></i>
    </div>
    <div class="mmbb-page-heading-copy">
      <h1 class="mmbb-page-title"><?= htmlspecialchars($standalonePageLabel !== '' ? $standalonePageLabel : $standaloneModuleLabel, ENT_QUOTES, 'UTF-8') ?></h1>
      <?php if ($standalonePageDescription !== ''): ?>
        <p class="mmbb-page-subtitle"><?= htmlspecialchars($standalonePageDescription, ENT_QUOTES, 'UTF-8') ?></p>
      <?php endif; ?>
    </div>
  </div>
</header>
