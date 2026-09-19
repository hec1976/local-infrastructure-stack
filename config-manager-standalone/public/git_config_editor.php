<?php
declare(strict_types=1);

// Config Manager Portal 3.13.6
// Deploy-Profile werden zentral im Portal verwaltet und vor Compare/Deploy auf den Zielagenten synchronisiert.
// Allgemeine Git-Einstellungen bleiben Bestandteil von global.json und sind hier absichtlich nicht editierbar.

require_once __DIR__ . '/../standalone/bootstrap.php';

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}
if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}
$csrfToken = (string)$_SESSION['csrf_token'];

$portalConfigFile = __DIR__ . '/../config/config.php';
$portalConfig = is_file($portalConfigFile) ? require $portalConfigFile : [];
$requiredService = trim((string)($portalConfig['git_deploy']['required_service'] ?? ''));
$requiredService = $requiredService !== '' ? $requiredService : 'ConfigManager';
if (function_exists('mmbb_has_service') && !mmbb_has_service($requiredService)) {
    http_response_code(403);
    exit('Keine Berechtigung für die Deploy-Profile.');
}
?>
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Deploy-Profile</title>
  <?php require MMBB_UI . '/includes/css.php'; ?>
  <link rel="stylesheet" href="assets/css/configuration_workspace.css?v=3.13.6">
</head>
<body class="configuration-editor-page git-config-editor-page">
<?php require MMBB_UI . '/navigation.php'; ?>
<?php require MMBB_UI . '/sidebar.php'; ?>

<div class="container mmbb-main py-3">
  <?php require MMBB_UI . '/module_header.php'; ?>

  <noscript><div class="alert alert-danger">Der Editor benötigt JavaScript.</div></noscript>
  <div id="gcePageMessage" class="alert d-none" role="alert"></div>


  <section class="shadow-card p-3 gce-workspace">
    <ul class="nav nav-tabs mmbb-content-tabs" role="tablist">
      <li class="nav-item" role="presentation">
        <button class="nav-link active" id="gceProfileEditTab" data-bs-toggle="tab" data-bs-target="#gceProfileEditPane" type="button" role="tab">
          Formular
        </button>
      </li>
      <li class="nav-item" role="presentation">
        <button class="nav-link" id="gceProfilesJsonTab" data-bs-toggle="tab" data-bs-target="#gceProfilesJsonPane" type="button" role="tab">
          JSON
        </button>
      </li>
      <li class="nav-item" role="presentation">
        <button class="nav-link" id="gceBackupsTab" data-bs-toggle="tab" data-bs-target="#gceBackupsPane" type="button" role="tab">
          Backups / Restore <span class="badge rounded-pill text-bg-light border ms-1" id="gceBackupCount">0</span>
        </button>
      </li>
    </ul>

    <div id="gceEditorMessage" class="alert d-none mt-3 mb-0" role="alert"></div>

    <div class="tab-content mt-3">
      <div class="tab-pane fade show active" id="gceProfileEditPane" role="tabpanel">
        <div class="sticky-topbar gce-commandbar mb-3">
          <div class="gce-commandbar-main">
            <div class="gce-server-field gce-central-profile-source">
              <label class="form-label">Profilkatalog</label>
              <div class="form-control form-control-sm bg-body-tertiary d-flex align-items-center gap-2" aria-label="Zentraler Profilkatalog">
                <i class="bi bi-diagram-3 text-primary"></i>
                <span><strong>Zentral</strong> · gilt für alle Zielserver</span>
              </div>
              <select id="gceServer" class="d-none" aria-hidden="true" tabindex="-1"><option value=""></option></select>
            </div>

            <div class="gce-command-actions" aria-label="Deploy-Profile bearbeiten">
              <button type="button" class="d-none" id="gceLoad" tabindex="-1" aria-hidden="true">Profile laden</button>
              <button type="button" class="btn btn-outline-primary btn-sm" id="gceAddProfile" disabled>
                <i class="bi bi-plus-circle me-1"></i> Neues Profil
              </button>
              <button type="button" class="btn btn-outline-primary btn-sm" id="gceValidate" disabled>
                <i class="bi bi-check2-circle me-1"></i> Validieren
              </button>
              <button type="button" class="btn btn-success btn-sm" id="gceSave" disabled>
                <i class="bi bi-save me-1"></i> Speichern
              </button>

              <div class="dropdown">
                <button class="btn btn-outline-secondary btn-sm dropdown-toggle" type="button" id="gceMoreActions" data-bs-toggle="dropdown" aria-expanded="false">
                  <i class="bi bi-three-dots me-1"></i> Weitere Aktionen
                </button>
                <ul class="dropdown-menu dropdown-menu-end" aria-labelledby="gceMoreActions">
                  <li><button type="button" class="dropdown-item" id="gceReloadInventory"><i class="bi bi-arrow-clockwise me-2"></i>Agenten für Repository-Assistent aktualisieren</button></li>
                  <li><hr class="dropdown-divider"></li>
                  <li><button type="button" class="dropdown-item" id="gceRepositoryAssistant" disabled><i class="bi bi-magic me-2"></i>Profil aus Repository erstellen</button></li>
                  <li><button type="button" class="dropdown-item" id="gceAdvancedToggle" disabled aria-pressed="false"><i class="bi bi-sliders me-2"></i>Erweiterte Optionen</button></li>
                </ul>
              </div>
            </div>
          </div>

          <div class="gce-filterbar" aria-label="Deploy-Profile filtern">
            <div class="gce-filter-field gce-filter-search">
              <label for="gceProfileSearch" class="form-label">Suche</label>
              <input type="search" id="gceProfileSearch" class="form-control form-control-sm" placeholder="Profil-ID, Repository, Zielpfad …" autocomplete="off" disabled>
            </div>
            <button type="button" id="gceProfileSearchReset" class="btn btn-outline-secondary btn-sm gce-filter-reset" disabled>
              <i class="bi bi-x-circle me-1"></i> Filter löschen
            </button>
          </div>
        </div>

        <div class="gce-master-detail configuration-editor-workarea">
          <aside class="gce-master-pane" aria-label="Deploy-Profile">
            <div class="gce-master-head">
              <div>
                <strong><i class="bi bi-list-ul"></i> Profile</strong>
                <small>Profil auswählen und gezielt bearbeiten</small>
              </div>
              <span class="badge text-bg-light border" id="gceProfileCount">0</span>
            </div>

            <div id="gceProfileList" class="gce-master-list configuration-master-scroll" role="listbox" aria-label="Deploy-Profile"></div>
            <div id="gceProfileListEmpty" class="gce-master-empty">
              <i class="bi bi-box"></i>
              <strong>Noch keine Profile geladen</strong>
              <span>Noch keine zentralen Deploy-Profile vorhanden. Über „Neu“ ein Profil anlegen.</span>
            </div>
          </aside>

          <section class="gce-detail-pane" aria-label="Deployment-Profil bearbeiten">
            <div id="gceProfileEmpty" class="gce-detail-empty">
              <i class="bi bi-box-arrow-in-down"></i>
              <h3>Kein Profil ausgewählt</h3>
              <p>Links ein zentrales Deployment-Profil auswählen oder ein neues Profil erstellen.</p>
            </div>

            <div id="gceProfileDetail" class="d-none">
              <header class="gce-detail-header">
                <div class="gce-detail-title">
                  <span class="gce-detail-icon"><i class="bi bi-boxes"></i></span>
                  <div>
                    <h3 id="gceProfileTitle">Deployment-Profil</h3>
                    <p id="gceProfilePath">git_deploy.json</p>
                  </div>
                </div>
                <div class="gce-detail-meta">
                  <div class="gce-detail-status">
                    <span class="badge text-bg-light border" id="gceProfileActiveState">Status unbekannt</span>
                    <span class="badge text-bg-light border gce-mode-badge" id="gceModeState" title="Technische Standardwerte werden automatisch ergänzt.">
                      <i class="bi bi-magic me-1"></i> Einfacher Modus
                    </span>
                    <span class="badge text-bg-light border" id="gceProfilesStatus">Nicht geladen</span>
                  </div>
                  <div class="dropdown">
                    <button class="btn btn-outline-secondary btn-sm gce-kebab" type="button" id="gceProfileActions" data-bs-toggle="dropdown" aria-expanded="false" aria-label="Profilaktionen" title="Profilaktionen">
                      <i class="bi bi-three-dots-vertical"></i>
                    </button>
                    <ul class="dropdown-menu dropdown-menu-end" aria-labelledby="gceProfileActions">
                      <li>
                        <button type="button" class="dropdown-item" id="gceDuplicateProfile" disabled>
                          <i class="bi bi-copy me-2"></i>Duplizieren
                        </button>
                      </li>
                      <li><hr class="dropdown-divider"></li>
                      <li>
                        <button type="button" class="dropdown-item text-danger" id="gceDeleteProfile" disabled>
                          <i class="bi bi-trash me-2"></i>Löschen
                        </button>
                      </li>
                    </ul>
                  </div>
                </div>
              </header>

              <form id="gceProfileForm" class="gce-profile-form" autocomplete="off">
                  <nav class="configuration-detail-tabs nav nav-pills" role="tablist" aria-label="Bereiche des Deployment-Profils">
                    <button class="nav-link active" id="gceDetailGeneralTab" data-bs-toggle="tab" data-bs-target="#gceDetailGeneral" type="button" role="tab" aria-controls="gceDetailGeneral" aria-selected="true">
                      <i class="bi bi-card-list"></i> Allgemein
                    </button>
                    <button class="nav-link" id="gceDetailRightsTab" data-bs-toggle="tab" data-bs-target="#gceDetailRights" type="button" role="tab" aria-controls="gceDetailRights" aria-selected="false">
                      <i class="bi bi-shield-lock"></i> Rechte
                    </button>
                    <button class="nav-link" id="gceDetailActionsTab" data-bs-toggle="tab" data-bs-target="#gceDetailActions" type="button" role="tab" aria-controls="gceDetailActions" aria-selected="false">
                      <i class="bi bi-lightning-charge"></i> Aktionen
                    </button>
                  </nav>

                <div class="configuration-detail-content">
                  <div class="tab-content gce-profile-tab-content">
                    <div class="tab-pane fade show active" id="gceDetailGeneral" role="tabpanel" aria-labelledby="gceDetailGeneralTab" tabindex="0">
                                <div class="gce-profile-id-row">
                                  <div>
                                    <label for="gceProfileId" class="form-label">Profil-ID</label>
                                    <input type="text" id="gceProfileId" class="form-control form-control-sm" data-profile-control disabled>
                                    <div class="form-text">Eindeutiger Name im Portal und in der REST-API.</div>
                                  </div>
                                  <button type="button" id="gceRenameProfile" class="btn btn-outline-secondary btn-sm" disabled>
                                    <i class="bi bi-pencil me-1"></i> ID übernehmen
                                  </button>
                                </div>

                                <details class="gce-form-section" open>
                                  <summary><span><i class="bi bi-git"></i> Repository und Freigabe</span><small>Quelle, Branch oder Tag und Deployment-Modus</small></summary>
                                  <div class="gce-form-grid gce-form-grid-2">
                                    <label class="gce-check-card">
                                      <input class="form-check-input" type="checkbox" id="gceProfileEnabled" data-profile-control>
                                      <span><strong>Profil aktiviert</strong><small>Nur aktivierte Profile können ausgerollt werden.</small></span>
                                    </label>
                                    <div data-gce-advanced>
                                      <label for="gceDeployMode" class="form-label">Deployment-Modus</label>
                                      <select id="gceDeployMode" class="form-select form-select-sm" data-profile-control>
                                        <option value="directory_swap">directory_swap · fester Produktivpfad</option>
                                        <option value="symlink_release">symlink_release · current-Symlink</option>
                                      </select>
                                    </div>
                                    <div class="gce-span-2">
                                      <label for="gceGitUrl" class="form-label">Repository</label>
                                      <input type="url" id="gceGitUrl" class="form-control form-control-sm font-monospace" placeholder="https://git.local/teko/repository.git" data-profile-control>
                                    </div>
                                    <div>
                                      <label for="gceAllowedRef" class="form-label">Branch oder vollständiger Ref</label>
                                      <input type="text" id="gceAllowedRef" class="form-control form-control-sm font-monospace" placeholder="main" data-profile-control>
                                    </div>
                                    <div data-gce-advanced>
                                      <label for="gceRefPolicy" class="form-label">Ref-Prüfung</label>
                                      <select id="gceRefPolicy" class="form-select form-select-sm" data-profile-control>
                                        <option value="ancestor">ancestor · Commit muss im Ref liegen</option>
                                        <option value="exact">exact · Commit muss exakt dem Ref entsprechen</option>
                                      </select>
                                    </div>
                                  </div>
                                </details>

                                <details class="gce-form-section" open>
                                  <summary><span><i class="bi bi-folder2-open"></i> Ziel und Releases</span><small>Produktivpfad, Release-Ablage und Aufbewahrung</small></summary>
                                  <div class="gce-form-grid gce-form-grid-2">
                                    <div class="gce-span-2">
                                      <label for="gceTargetPath" class="form-label">Produktiver Zielpfad</label>
                                      <input type="text" id="gceTargetPath" class="form-control form-control-sm font-monospace" placeholder="/opt/mmbb_script/postfix_attachment" data-profile-control>
                                    </div>
                                    <div class="gce-span-2" data-gce-advanced>
                                      <label for="gceReleasesDir" class="form-label">Technisches Release-Verzeichnis</label>
                                      <input type="text" id="gceReleasesDir" class="form-control form-control-sm font-monospace" placeholder="/opt/mmbb_script/.git-deploy/postfix-attachment/releases" data-profile-control>
                                    </div>
                                    <div data-gce-advanced>
                                      <label for="gceKeepReleases" class="form-label">Releases behalten</label>
                                      <input type="number" min="2" step="1" id="gceKeepReleases" class="form-control form-control-sm" placeholder="globaler Standard" data-profile-control>
                                    </div>
                                    <label class="gce-check-card" data-gce-advanced>
                                      <input class="form-check-input" type="checkbox" id="gceImmutablePermissions" data-profile-control>
                                      <span><strong>Release unveränderlich setzen</strong><small>Code wird nach der Vorbereitung schreibgeschützt.</small></span>
                                    </label>
                                  </div>
                                </details>

                                <details class="gce-form-section" data-gce-advanced>
                                  <summary><span><i class="bi bi-braces-asterisk"></i> Zusätzliche Profilfelder</span><small>Unbekannte oder zukünftige Felder verlustfrei erhalten</small></summary>
                                  <label for="gceExtraFields" class="form-label">Zusätzliche Felder als JSON-Objekt</label>
                                  <textarea id="gceExtraFields" class="form-control form-control-sm font-monospace gce-extra-editor" spellcheck="false" data-profile-control>{}</textarea>
                                  <div class="form-text">Bereits als Eingabefeld vorhandene Schlüssel dürfen hier nicht erneut eingetragen werden.</div>
                                </details>
                    </div>

                    <div class="tab-pane fade" id="gceDetailRights" role="tabpanel" aria-labelledby="gceDetailRightsTab" tabindex="0">
                                <details class="gce-form-section" open>
                                  <summary><span><i class="bi bi-person-lock"></i> Rechte und Service</span><small>Eigentümer, Gruppe und optionaler Service-Restart</small></summary>
                                  <div class="gce-form-grid gce-form-grid-3">
                                    <div><label for="gceUser" class="form-label">Benutzer</label><input type="text" id="gceUser" class="form-control form-control-sm" placeholder="root" data-profile-control></div>
                                    <div><label for="gceGroup" class="form-label">Gruppe</label><input type="text" id="gceGroup" class="form-control form-control-sm" placeholder="taskmgmt" data-profile-control></div>
                                    <div><label for="gceRestartService" class="form-label">Service neu starten</label><input type="text" id="gceRestartService" class="form-control form-control-sm font-monospace" placeholder="postfix.service" data-profile-control></div>
                                    <label class="gce-check-card gce-span-3" data-gce-advanced><input class="form-check-input" type="checkbox" id="gceDaemonReload" data-profile-control><span><strong>Vor Restart systemctl daemon-reload</strong><small>Nur aktivieren, wenn Units mit dem Paket geändert werden.</small></span></label>
                                    <div data-gce-advanced>
                                      <label for="gceAuthScheme" class="form-label">Auth-Schema (optional)</label>
                                      <select id="gceAuthScheme" class="form-select form-select-sm" data-profile-control>
                                        <option value="">globaler Standard</option><option value="basic">basic</option><option value="bearer">bearer</option><option value="token">token</option>
                                      </select>
                                    </div>
                                    <div data-gce-advanced><label for="gceDeployUser" class="form-label">Deploy-Benutzer (optional)</label><input type="text" id="gceDeployUser" class="form-control form-control-sm" placeholder="git-deploy" data-profile-control></div>
                                    <div data-gce-advanced><label for="gceCaInfo" class="form-label">CA-Datei (optional)</label><input type="text" id="gceCaInfo" class="form-control form-control-sm font-monospace" placeholder="/etc/ssl/certs/internal-ca.pem" data-profile-control></div>
                                  </div>
                                </details>

                                <details class="gce-form-section" data-gce-advanced>
                                  <summary><span><i class="bi bi-shield-check"></i> Sicherheitsprüfungen und Limits</span><small>Git-Baum, Symlinks, Signaturen und Grössenbegrenzung</small></summary>
                                  <div class="gce-flag-grid">
                                    <label class="gce-check-card"><input class="form-check-input" type="checkbox" id="gceAllowSymlinks" data-profile-control><span><strong>Interne Symlinks erlauben</strong><small>Ausbrechende Links bleiben verboten.</small></span></label>
                                    <label class="gce-check-card"><input class="form-check-input" type="checkbox" id="gceRejectHardlinks" data-profile-control><span><strong>Hardlinks ablehnen</strong><small>Schützt vor Mehrfachverweisen auf Dateien.</small></span></label>
                                    <label class="gce-check-card"><input class="form-check-input" type="checkbox" id="gceRejectLfsPointers" data-profile-control><span><strong>Git-LFS-Pointer ablehnen</strong><small>Verhindert unvollständig geladene Inhalte.</small></span></label>
                                    <label class="gce-check-card"><input class="form-check-input" type="checkbox" id="gceRequireSignedCommit" data-profile-control><span><strong>Signierten Commit verlangen</strong><small>Führt git verify-commit aus.</small></span></label>
                                  </div>
                                  <div class="gce-form-grid gce-form-grid-3 mt-3">
                                    <div><label for="gceMaxFiles" class="form-label">Maximale Dateien</label><input type="number" min="1" step="1" id="gceMaxFiles" class="form-control form-control-sm" placeholder="globaler Standard" data-profile-control></div>
                                    <div><label for="gceMaxBytes" class="form-label">Maximale Bytes</label><input type="number" min="1" step="1" id="gceMaxBytes" class="form-control form-control-sm" placeholder="globaler Standard" data-profile-control></div>
                                    <div><label for="gceMaxTreeListingBytes" class="form-label">Max. Tree-Listing Bytes</label><input type="number" min="1" step="1" id="gceMaxTreeListingBytes" class="form-control form-control-sm" placeholder="33554432" data-profile-control></div>
                                  </div>
                                </details>

                                <details class="gce-form-section" open>
                                  <summary><span><i class="bi bi-box-seam"></i> Paketplan</span><small>Vom Deploy-Profil deklarativ ueber Package Management verwaltet</small></summary>
                                  <div id="gcePackagePlan" class="small text-body-secondary">Keine Pakete im Profil definiert.</div>
                                </details>

                                <details class="gce-form-section" open>
                                  <summary><span><i class="bi bi-file-earmark-lock2"></i> Persistente Paketpfade</span><small>Konfigurationen bei Code-Deploy und Rollback erhalten</small></summary>
                                  <div class="gce-array-head mb-2"><div><strong>preserve_paths</strong><small>Relative Dateien oder Verzeichnisse innerhalb des Pakets.</small></div><button type="button" class="btn btn-outline-primary btn-sm" id="gceAddPreserve" data-profile-control><i class="bi bi-plus-lg me-1"></i> Pfad hinzufügen</button></div>
                                  <div id="gcePreserveList" class="gce-preserve-list"></div>
                                  <div id="gcePreserveEmpty" class="gce-inline-empty">Keine persistenten Pfade definiert. Die vollständige Git-Version wird ausgerollt.</div>
                                </details>
                    </div>

                    <div class="tab-pane fade" id="gceDetailActions" role="tabpanel" aria-labelledby="gceDetailActionsTab" tabindex="0">

                                <details class="gce-form-section" data-gce-advanced>
                                  <summary><span><i class="bi bi-terminal"></i> Preflight</span><small>Fester Test vor der Aktivierung</small></summary>
                                  <label class="gce-check-card mb-3"><input class="form-check-input" type="checkbox" id="gcePreflightEnabled" data-profile-control><span><strong>Preflight ausführen</strong><small>Argumente werden ohne Shell-Auswertung gestartet.</small></span></label>
                                  <div id="gcePreflightFields">
                                    <div class="gce-form-grid gce-form-grid-2">
                                      <div><label for="gcePreflightCwd" class="form-label">Arbeitsverzeichnis</label><input type="text" id="gcePreflightCwd" class="form-control form-control-sm font-monospace" placeholder="{release}" data-profile-control></div>
                                      <div><label for="gcePreflightTimeout" class="form-label">Timeout (Sekunden)</label><input type="number" min="1" step="1" id="gcePreflightTimeout" class="form-control form-control-sm" placeholder="60" data-profile-control></div>
                                    </div>
                                    <div class="gce-array-editor mt-3"><div class="gce-array-head"><div><strong>Argumente (argv)</strong><small>Je Eintrag genau ein Prozessargument.</small></div><button type="button" class="btn btn-outline-primary btn-sm" id="gceAddPreflightArg" data-profile-control><i class="bi bi-plus-lg me-1"></i> Argument</button></div><div id="gcePreflightArgs" class="gce-array-list"></div></div>
                                  </div>
                                </details>

                                <details class="gce-form-section" open>
                                  <summary><span><i class="bi bi-tools"></i> Installation nach Aktivierung</span><small>Optionales, fest definiertes Installationsskript ohne Shell-Auswertung</small></summary>
                                  <label class="gce-check-card mb-3"><input class="form-check-input" type="checkbox" id="gcePostDeployEnabled" data-profile-control><span><strong>Installationsskript nach dem Deployment ausführen</strong><small>Wird nach dem atomaren Wechsel und vor dem Service-Restart ausgeführt.</small></span></label>
                                  <div id="gcePostDeployFields">
                                    <div class="gce-form-grid gce-form-grid-3">
                                      <div><label for="gcePostDeployScript" class="form-label">Skript im Repository</label><input type="text" id="gcePostDeployScript" class="form-control form-control-sm font-monospace" placeholder="_install.sh" data-profile-control></div>
                                      <div><label for="gcePostDeployTimeout" class="form-label">Timeout (Sekunden)</label><input type="number" min="1" max="900" step="1" id="gcePostDeployTimeout" class="form-control form-control-sm" placeholder="120" data-profile-control></div>
                                      <label class="gce-check-card"><input class="form-check-input" type="checkbox" id="gcePostDeployRollback" data-profile-control><span><strong>Beim Rollback erneut ausführen</strong><small>Stellt beispielsweise die vorherige systemd-Unit wieder her.</small></span></label>
                                    </div>
                                    <div class="gce-array-editor mt-3"><div class="gce-array-head"><div><strong>Argumente</strong><small>Beispiel: <code>--no-start</code>; der Config Agent übernimmt danach Restart und Healthcheck.</small></div><button type="button" class="btn btn-outline-primary btn-sm" id="gceAddPostDeployArg" data-profile-control><i class="bi bi-plus-lg me-1"></i> Argument</button></div><div id="gcePostDeployArgs" class="gce-array-list"></div></div>
                                  </div>
                                </details>

                                <details class="gce-form-section" data-gce-advanced>
                                  <summary><span><i class="bi bi-heart-pulse"></i> Healthcheck</span><small>Prüfung nach Restart und beim Rollback</small></summary>
                                  <div class="gce-form-grid gce-form-grid-3">
                                    <div><label for="gceHealthType" class="form-label">Healthcheck-Typ</label><select id="gceHealthType" class="form-select form-select-sm" data-profile-control><option value="">automatisch</option><option value="none">none</option><option value="systemd">systemd</option><option value="exec">exec</option></select></div>
                                    <div><label for="gceHealthWait" class="form-label">Wartezeit (Sekunden)</label><input type="number" min="0" max="60" step="0.1" id="gceHealthWait" class="form-control form-control-sm" placeholder="automatisch" data-profile-control></div>
                                    <div id="gceHealthTimeoutWrap"><label for="gceHealthTimeout" class="form-label">Exec-Timeout (Sekunden)</label><input type="number" min="1" step="1" id="gceHealthTimeout" class="form-control form-control-sm" placeholder="30" data-profile-control></div>
                                  </div>
                                  <div id="gceHealthExecFields" class="gce-array-editor mt-3"><div class="gce-array-head"><div><strong>Exec-Argumente (argv)</strong><small>Nur für Healthcheck-Typ exec.</small></div><button type="button" class="btn btn-outline-primary btn-sm" id="gceAddHealthArg" data-profile-control><i class="bi bi-plus-lg me-1"></i> Argument</button></div><div id="gceHealthArgs" class="gce-array-list"></div></div>
                                </details>

                    </div>
                  </div>
                </div>
              </form>

            </div>
          </section>
        </div>
      </div>

      <div class="tab-pane fade" id="gceProfilesJsonPane" role="tabpanel">
        <div class="gce-json-toolbar d-flex flex-wrap gap-2 mb-2 mt-2">
          <button type="button" class="btn btn-outline-secondary btn-sm" id="gceFormat" disabled>
            <i class="bi bi-braces me-1"></i> JSON schön formatieren
          </button>
          <button type="button" class="btn btn-outline-secondary btn-sm" id="gceApplyFullJson" disabled>
            <i class="bi bi-arrow-down-up me-1"></i> JSON zu Formular laden
          </button>
          <button type="button" class="btn btn-success btn-sm ms-auto" id="gceSaveJson" disabled>
            <i class="bi bi-save me-1"></i> Änderungen speichern
          </button>
        </div>
        <div class="gce-editor-labelrow mb-2">
          <div>
            <strong>Vollständige git_deploy.json</strong>
            <small>Enthält Schema-Version und alle zentralen Deploy-Profile. <code>global.json</code> bleibt agentlokal und ist nicht Bestandteil dieses Editors.</small>
          </div>
        </div>
        <div id="gceProfilesEditor" class="configuration-json-editor" aria-label="git_deploy.json bearbeiten"></div>
        <div id="gceProfilesSummary" class="d-none"></div>
      </div>

      <div class="tab-pane fade configuration-backup-pane" id="gceBackupsPane" role="tabpanel">
        <div class="configuration-backup-layout mt-2">
          <aside class="configuration-backup-master" aria-label="Backups der git_deploy.json">
            <div class="configuration-backup-head">
              <div>
                <strong><i class="bi bi-clock-history"></i> Backups / Restore</strong>
                <small>Automatische Sicherungen vor Änderungen und Restore</small>
              </div>
              <span class="badge text-bg-light border" id="gceBackupListCount">0</span>
            </div>
            <div class="configuration-backup-actions">
              <button type="button" class="btn btn-outline-secondary btn-sm" id="gceLoadBackups" disabled>
                <i class="bi bi-arrow-clockwise me-1"></i> Backups laden
              </button>
            </div>
            <select id="gceBackup" class="d-none" aria-hidden="true" tabindex="-1" disabled>
              <option value="">Keine Backups geladen</option>
            </select>
            <div id="gceBackupList" class="configuration-backup-list" role="listbox"></div>
            <div id="gceBackupListEmpty" class="configuration-backup-empty">
              <i class="bi bi-archive"></i>
              <strong>Noch keine Backups geladen</strong>
              <span>Backups des zentralen Profilkatalogs laden.</span>
            </div>
          </aside>

          <section class="configuration-backup-detail" aria-label="Backup-Vorschau">
            <div class="configuration-backup-detail-head">
              <div>
                <strong id="gceBackupTitle">Kein Backup ausgewählt</strong>
                <small id="gceBackupMeta">git_deploy.json</small>
              </div>
              <button type="button" class="btn btn-outline-warning btn-sm" id="gceRestore" disabled>
                <i class="bi bi-arrow-counterclockwise me-1"></i> Wiederherstellen
              </button>
            </div>
            <pre id="gceBackupPreview" class="configuration-backup-preview">Links ein Backup auswählen, um den Inhalt zu prüfen.</pre>
          </section>
        </div>
      </div>
    </div>

  </section>
</div>


<div class="modal fade" id="gceAssistantModal" tabindex="-1" aria-labelledby="gceAssistantTitle" aria-hidden="true">
  <div class="modal-dialog modal-xl modal-dialog-scrollable">
    <div class="modal-content">
      <div class="modal-header">
        <div>
          <h2 class="modal-title fs-5" id="gceAssistantTitle"><i class="bi bi-magic me-2"></i>Deployment-Profil-Assistent</h2>
          <div class="small text-body-secondary mt-1">Repository sicher analysieren, Vorschlag prüfen und anschliessend als bearbeitbares Profil übernehmen.</div>
        </div>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Schliessen"></button>
      </div>
      <div class="modal-body">
        <div id="gceAssistantMessage" class="alert d-none" role="alert"></div>

        <section class="gce-assistant-section">
          <div class="gce-assistant-section-head">
            <div><strong>1. Repository auswählen</strong><small>Der Agent verwendet sein lokal geschütztes Forgejo-Token.</small></div>
            <button type="button" class="btn btn-outline-secondary btn-sm" id="gceAssistantRefreshRepos"><i class="bi bi-arrow-clockwise me-1"></i> Repositorys aktualisieren</button>
          </div>
          <div class="gce-form-grid gce-form-grid-2">
            <div>
              <label for="gceAssistantRepository" class="form-label">Repository</label>
              <select id="gceAssistantRepository" class="form-select form-select-sm"><option value="">Repositorys laden …</option></select>
            </div>
            <div>
              <label for="gceAssistantBranch" class="form-label">Branch</label>
              <select id="gceAssistantBranch" class="form-select form-select-sm" disabled><option value="">Zuerst Repository wählen</option></select>
            </div>
          </div>
          <div id="gceAssistantRepositoryStatus" class="small text-body-secondary mt-2">Alle für den Forgejo-Service-User lesbaren Repositorys werden angezeigt. Bereits verwendete Repositorys werden markiert und bleiben auswählbar.</div>
          <div class="d-flex justify-content-end mt-3">
            <button type="button" class="btn btn-primary btn-sm" id="gceAssistantScan" disabled><i class="bi bi-search me-1"></i> Repository analysieren</button>
          </div>
        </section>

        <section class="gce-assistant-section d-none" id="gceAssistantResult">
          <div class="gce-assistant-section-head">
            <div><strong>2. Vorschlag anpassen</strong><small>Es wird nichts ausgeführt und noch nichts gespeichert.</small></div>
            <div id="gceAssistantSummary" class="gce-assistant-summary"></div>
          </div>

          <div id="gceAssistantWarnings" class="d-none"></div>

          <div class="gce-form-grid gce-form-grid-3 mt-3">
            <div><label for="gceAssistantProfileId" class="form-label">Profil-ID</label><input type="text" id="gceAssistantProfileId" class="form-control form-control-sm" placeholder="l2p-agent"></div>
            <div class="gce-span-2"><label for="gceAssistantTarget" class="form-label">Zielpfad</label><input type="text" id="gceAssistantTarget" class="form-control form-control-sm font-monospace" placeholder="/opt/mmbb_services/l2p-agent"></div>
            <div><label for="gceAssistantOwner" class="form-label">Benutzer</label><input type="text" id="gceAssistantOwner" class="form-control form-control-sm" value="root"></div>
            <div><label for="gceAssistantGroup" class="form-label">Gruppe</label><input type="text" id="gceAssistantGroup" class="form-control form-control-sm" value="taskmgmt"></div>
            <div><label for="gceAssistantService" class="form-label">Service <span class="text-muted fw-normal">(optional)</span></label><input type="text" id="gceAssistantService" class="form-control form-control-sm font-monospace" placeholder="mmbb-l2p-agent.service" list="gceAssistantServiceList"><datalist id="gceAssistantServiceList"></datalist></div>
          </div>

          <div class="gce-assistant-block mt-4">
            <div class="gce-assistant-block-head"><div><strong>Persistente Dateien und Verzeichnisse</strong><small>Erkannte Vorschläge können abgewählt, geändert oder ergänzt werden.</small></div><button type="button" class="btn btn-outline-primary btn-sm" id="gceAssistantAddPreserve"><i class="bi bi-plus-lg me-1"></i> Pfad</button></div>
            <div id="gceAssistantPreserve" class="gce-assistant-preserve"></div>
            <div id="gceAssistantPreserveEmpty" class="gce-inline-empty d-none">Keine persistenten Pfade vorgeschlagen.</div>
          </div>

          <div class="gce-assistant-block mt-4">
            <div class="gce-assistant-block-head"><div><strong>Preflight-Prüfung</strong><small>Der Scanner führt keine Repository-Datei aus. Die gewählte Prüfung läuft erst beim Deployment ohne Shell-Auswertung.</small></div></div>
            <select id="gceAssistantPreflight" class="form-select form-select-sm"><option value="">Keine automatische Prüfung</option></select>
          </div>

          <div class="gce-assistant-block mt-4">
            <div class="gce-assistant-block-head"><div><strong>Installation nach Aktivierung</strong><small>Erkannte Installationsskripte werden beim Scan nicht ausgeführt. Die Ausführung erfolgt erst nach erfolgreicher Aktivierung.</small></div></div>
            <select id="gceAssistantPostDeploy" class="form-select form-select-sm"><option value="">Kein Installationsskript ausführen</option></select>
            <div class="form-text">Bei unterstützten Installern wird automatisch <code>--no-start</code> vorgeschlagen, damit der Config Agent den Service kontrolliert neu startet.</div>
          </div>

          <details class="gce-assistant-details mt-4">
            <summary><i class="bi bi-list-check me-1"></i> Erkannte Repository-Struktur anzeigen</summary>
            <div id="gceAssistantTree" class="gce-assistant-tree"></div>
          </details>
        </section>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary btn-sm" data-bs-dismiss="modal">Abbrechen</button>
        <button type="button" class="btn btn-success btn-sm" id="gceAssistantApply" disabled><i class="bi bi-check2-circle me-1"></i> Als Profil übernehmen</button>
      </div>
    </div>
  </div>
</div>

<script>
window.GIT_CONFIG_EDITOR = <?= json_encode([
    'endpoint' => 'git_deploy.php',
    'csrfToken' => $csrfToken,
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?>;
</script>
<?php require MMBB_UI . '/includes/js.php'; ?>
  <script src="assets/js/configuration_json_editor.js?v=3.10.0"></script>
  <script src="assets/js/git_config_editor.js?v=3.13.6"></script>
</body>
</html>
