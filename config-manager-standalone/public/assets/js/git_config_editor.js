(() => {
  'use strict';

  const cfg = window.GIT_CONFIG_EDITOR || {};
  const endpoint = String(cfg.endpoint || 'git_deploy.php');
  const csrfToken = String(cfg.csrfToken || '');
  const byId = (id) => document.getElementById(id);

  const serverSelect = byId('gceServer');
  const loadButton = byId('gceLoad');
  const reloadButton = byId('gceReloadInventory');
  const formatButton = byId('gceFormat');
  const validateButton = byId('gceValidate');
  const saveButton = byId('gceSave');
  const saveJsonButton = byId('gceSaveJson');
  const profileSearchReset = byId('gceProfileSearchReset');
  const backupSelect = byId('gceBackup');
  const backupList = byId('gceBackupList');
  const backupListEmpty = byId('gceBackupListEmpty');
  const backupCount = byId('gceBackupCount');
  const backupListCount = byId('gceBackupListCount');
  const backupTitle = byId('gceBackupTitle');
  const backupMeta = byId('gceBackupMeta');
  const backupPreview = byId('gceBackupPreview');
  const loadBackupsButton = byId('gceLoadBackups');
  const restoreButton = byId('gceRestore');

  const profilesEditorElement = byId('gceProfilesEditor');
  const profilesAce = window.MMBBConfigurationJsonEditor.create('gceProfilesEditor');
  let profilesEditorProgrammatic = false;
  const profilesEditor = {
    get value() {
      return profilesAce.getValue();
    },
    set value(value) {
      const next = String(value ?? '');
      if (profilesAce.getValue() === next) return;
      profilesEditorProgrammatic = true;
      try {
        profilesAce.setValue(next, -1);
      } finally {
        profilesEditorProgrammatic = false;
      }
    },
    set disabled(value) {
      const disabled = Boolean(value);
      profilesAce.setReadOnly(disabled);
      profilesEditorElement.classList.toggle('is-disabled', disabled);
      profilesEditorElement.setAttribute('aria-disabled', disabled ? 'true' : 'false');
    },
    addEventListener(type, handler) {
      if (type === 'input') {
        profilesAce.session.on('change', () => {
          if (!profilesEditorProgrammatic) handler();
        });
        return;
      }
      profilesEditorElement.addEventListener(type, handler);
    },
  };
  const profileForm = byId('gceProfileForm');
  const profileIdInput = byId('gceProfileId');
  const profileSearch = byId('gceProfileSearch');

  const pageMessage = byId('gcePageMessage');
  const editorMessage = byId('gceEditorMessage');
  const profilesStatus = byId('gceProfilesStatus');
  const profileActiveState = byId('gceProfileActiveState');
  const contextServer = byId('gceContextServer');
  const contextProfiles = byId('gceContextProfiles');
  const contextStatus = byId('gceContextStatus');

  const profilesSummary = byId('gceProfilesSummary');
  const profileList = byId('gceProfileList');
  const profileListEmpty = byId('gceProfileListEmpty');
  const profileCount = byId('gceProfileCount');
  const profileEmpty = byId('gceProfileEmpty');
  const profileDetail = byId('gceProfileDetail');
  const profileTitle = byId('gceProfileTitle');
  const profilePath = byId('gceProfilePath');

  const addProfileButton = byId('gceAddProfile');
  const duplicateProfileButton = byId('gceDuplicateProfile');
  const deleteProfileButton = byId('gceDeleteProfile');
  const renameProfileButton = byId('gceRenameProfile');
  const applyFullJsonButton = byId('gceApplyFullJson');
  const advancedToggleButton = byId('gceAdvancedToggle');
  const modeState = byId('gceModeState');
  const repositoryAssistantButton = byId('gceRepositoryAssistant');

  const fields = {
    enabled: byId('gceProfileEnabled'),
    deployMode: byId('gceDeployMode'),
    gitUrl: byId('gceGitUrl'),
    allowedRef: byId('gceAllowedRef'),
    refPolicy: byId('gceRefPolicy'),
    targetPath: byId('gceTargetPath'),
    releasesDir: byId('gceReleasesDir'),
    keepReleases: byId('gceKeepReleases'),
    immutablePermissions: byId('gceImmutablePermissions'),
    user: byId('gceUser'),
    group: byId('gceGroup'),
    restartService: byId('gceRestartService'),
    daemonReload: byId('gceDaemonReload'),
    authScheme: byId('gceAuthScheme'),
    deployUser: byId('gceDeployUser'),
    caInfo: byId('gceCaInfo'),
    allowSymlinks: byId('gceAllowSymlinks'),
    rejectHardlinks: byId('gceRejectHardlinks'),
    rejectLfsPointers: byId('gceRejectLfsPointers'),
    requireSignedCommit: byId('gceRequireSignedCommit'),
    maxFiles: byId('gceMaxFiles'),
    maxBytes: byId('gceMaxBytes'),
    maxTreeListingBytes: byId('gceMaxTreeListingBytes'),
    preflightEnabled: byId('gcePreflightEnabled'),
    preflightCwd: byId('gcePreflightCwd'),
    preflightTimeout: byId('gcePreflightTimeout'),
    postDeployEnabled: byId('gcePostDeployEnabled'),
    postDeployScript: byId('gcePostDeployScript'),
    postDeployTimeout: byId('gcePostDeployTimeout'),
    postDeployRollback: byId('gcePostDeployRollback'),
    healthType: byId('gceHealthType'),
    healthWait: byId('gceHealthWait'),
    healthTimeout: byId('gceHealthTimeout'),
    extra: byId('gceExtraFields'),
  };

  const preflightFields = byId('gcePreflightFields');
  const preflightArgs = byId('gcePreflightArgs');
  const addPreflightArgButton = byId('gceAddPreflightArg');
  const postDeployFields = byId('gcePostDeployFields');
  const postDeployArgs = byId('gcePostDeployArgs');
  const addPostDeployArgButton = byId('gceAddPostDeployArg');
  const healthExecFields = byId('gceHealthExecFields');
  const healthTimeoutWrap = byId('gceHealthTimeoutWrap');
  const healthArgs = byId('gceHealthArgs');
  const addHealthArgButton = byId('gceAddHealthArg');
  const preserveList = byId('gcePreserveList');
  const preserveEmpty = byId('gcePreserveEmpty');
  const addPreserveButton = byId('gceAddPreserve');
  const packagePlan = byId('gcePackagePlan');

  const assistantModalElement = byId('gceAssistantModal');
  const assistantMessage = byId('gceAssistantMessage');
  const assistantRepository = byId('gceAssistantRepository');
  const assistantRepositoryStatus = byId('gceAssistantRepositoryStatus');
  const assistantBranch = byId('gceAssistantBranch');
  const assistantRefreshRepos = byId('gceAssistantRefreshRepos');
  const assistantScanButton = byId('gceAssistantScan');
  const assistantResult = byId('gceAssistantResult');
  const assistantSummary = byId('gceAssistantSummary');
  const assistantWarnings = byId('gceAssistantWarnings');
  const assistantProfileId = byId('gceAssistantProfileId');
  const assistantTarget = byId('gceAssistantTarget');
  const assistantOwner = byId('gceAssistantOwner');
  const assistantGroup = byId('gceAssistantGroup');
  const assistantService = byId('gceAssistantService');
  const assistantServiceList = byId('gceAssistantServiceList');
  const assistantPreserve = byId('gceAssistantPreserve');
  const assistantPreserveEmpty = byId('gceAssistantPreserveEmpty');
  const assistantAddPreserve = byId('gceAssistantAddPreserve');
  const assistantPreflight = byId('gceAssistantPreflight');
  const assistantPostDeploy = byId('gceAssistantPostDeploy');
  const assistantTree = byId('gceAssistantTree');
  const assistantApply = byId('gceAssistantApply');


  const KNOWN_PROFILE_KEYS = new Set([
    'enabled', 'deploy_mode', 'git_url', 'allowed_ref', 'ref_policy', 'target_path', 'releases_dir',
    'restart_service', 'daemon_reload', 'keep_releases', 'immutable_permissions', 'allow_symlinks',
    'reject_hardlinks', 'reject_lfs_pointers', 'require_signed_commit', 'user', 'group', 'preserve_paths',
    'preflight', 'post_deploy', 'install', 'healthcheck', 'auth_scheme', 'deploy_user', 'ca_info', 'max_files', 'max_bytes',
    'max_tree_listing_bytes', 'repository', 'branch', 'tag', 'ref', 'target', 'owner', 'service',
    'preserve', 'advanced', 'format',
  ]);

  let inventory = [];
  let loaded = false;
  let dirty = false;
  let busy = false;
  let profilesDocument = null;
  let selectedProfileId = null;
  let backupItems = [];
  let backupsLoaded = false;
  let fullJsonPending = false;
  let formHydrating = false;
  let advancedMode = false;
  let assistantAllRepositories = [];
  let assistantRepositories = [];
  let assistantBranches = [];
  let assistantScan = null;
  let assistantBusy = false;

  const serverIndex = () => /^\d+$/.test(serverSelect.value) ? Number(serverSelect.value) : null;
  const fullJsonTabActive = () => byId('gceProfilesJsonTab')?.classList.contains('active') === true;

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, (m) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;',
    }[m]));
  }

  function deepClone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function prettyValue(value) {
    return JSON.stringify(value, null, 2);
  }

  function isObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  function simpleRef(value) {
    const ref = String(value || '').trim();
    if (ref.startsWith('refs/heads/')) return ref.slice(11);
    return ref;
  }

  function derivedReleaseDir(id, target) {
    const clean = String(target || '').replace(/\/+$/, '');
    const slash = clean.lastIndexOf('/');
    if (slash < 0) return '';
    const parent = clean.slice(0, slash) || '/';
    return `${parent === '/' ? '' : parent}/.git-deploy/${id}/releases`;
  }

  function normalizePreserveForForm(items) {
    if (!Array.isArray(items)) return [];
    return items.map((item) => {
      if (typeof item === 'string') return {path: item, policy: 'preserve_existing', required: false};
      if (!isObject(item)) return item;
      const copy = {...item};
      if (!copy.user && copy.owner) copy.user = copy.owner;
      if (!copy.policy) copy.policy = 'preserve_existing';
      if (copy.required === undefined) copy.required = false;
      return copy;
    });
  }

  function normalizedProfileForForm(profile, id) {
    const source = isObject(profile) ? profile : {};
    const advanced = isObject(source.advanced) ? source.advanced : {};
    const pick = (canonical, alias, fallback = '') => source[canonical] ?? source[alias] ?? advanced[canonical] ?? fallback;
    const repository = pick('git_url', 'repository');
    const target = pick('target_path', 'target');
    let allowedRef = source.allowed_ref ?? advanced.allowed_ref ?? '';
    if (!allowedRef && source.branch) allowedRef = String(source.branch).startsWith('refs/') ? source.branch : `refs/heads/${source.branch}`;
    if (!allowedRef && source.tag) allowedRef = String(source.tag).startsWith('refs/') ? source.tag : `refs/tags/${source.tag}`;
    if (!allowedRef && source.ref) allowedRef = String(source.ref).startsWith('refs/') ? source.ref : `refs/heads/${source.ref}`;
    const out = {...advanced, ...source};
    out.enabled = source.enabled !== false;
    out.deploy_mode = source.deploy_mode ?? advanced.deploy_mode ?? 'directory_swap';
    out.git_url = repository;
    out.allowed_ref = allowedRef || 'refs/heads/main';
    out.ref_policy = source.ref_policy ?? advanced.ref_policy ?? (String(out.allowed_ref).startsWith('refs/tags/') ? 'exact' : 'ancestor');
    out.target_path = target;
    out.releases_dir = source.releases_dir ?? advanced.releases_dir ?? derivedReleaseDir(id, target);
    out.user = pick('user', 'owner');
    out.group = source.group ?? advanced.group ?? '';
    out.restart_service = pick('restart_service', 'service');
    out.preserve_paths = normalizePreserveForForm(source.preserve_paths ?? source.preserve ?? advanced.preserve_paths ?? []);
    if (Array.isArray(source.preflight)) out.preflight = {argv: source.preflight, cwd: '{release}', timeout: 30};
    let post = source.post_deploy ?? source.install ?? advanced.post_deploy;
    if (typeof post === 'string') post = {script: post};
    if (Array.isArray(post)) post = {argv: post};
    if (isObject(post)) {
      post = {...post};
      if (!post.script && Array.isArray(post.argv) && String(post.argv[0] || '').startsWith('{release}/')) post.script = String(post.argv[0]).slice(10);
      if (!Array.isArray(post.args) && Array.isArray(post.argv)) post.args = post.argv.slice(1);
      if (post.timeout === undefined) post.timeout = 120;
      if (post.run_on_rollback === undefined) post.run_on_rollback = true;
      out.post_deploy = post;
    }
    return out;
  }

  function applyAdvancedMode() {
    document.body.classList.toggle('gce-simple-mode', !advancedMode);
    if (modeState) {
      modeState.classList.toggle('text-bg-light', !advancedMode);
      modeState.classList.toggle('text-bg-primary', advancedMode);
      modeState.innerHTML = advancedMode
        ? '<i class="bi bi-sliders me-1"></i> Erweiterter Modus'
        : '<i class="bi bi-magic me-1"></i> Einfacher Modus';
      modeState.title = advancedMode
        ? 'Alle technischen Profiloptionen sind sichtbar.'
        : 'Technische Standardwerte werden automatisch ergänzt.';
    }
    if (advancedToggleButton) {
      advancedToggleButton.setAttribute('aria-pressed', advancedMode ? 'true' : 'false');
      advancedToggleButton.classList.toggle('active', advancedMode);
      advancedToggleButton.innerHTML = advancedMode
        ? '<i class="bi bi-check2 me-2"></i>Erweiterte Optionen aktiv'
        : '<i class="bi bi-sliders me-2"></i>Erweiterte Optionen';
    }
  }

  function message(element, type, text) {
    element.className = `alert alert-${type}`;
    element.textContent = text;
    element.classList.remove('d-none');
  }

  function clearMessage(element) {
    element.classList.add('d-none');
    element.textContent = '';
  }

  function setBadge(element, text, variant = 'light') {
    element.className = `badge ${variant === 'light' ? 'text-bg-light border' : `text-bg-${variant}`}`;
    element.textContent = text;
  }

  async function fetchJson(url, options = {}) {
    const response = await fetch(url, {
      cache: 'no-store',
      credentials: 'same-origin',
      ...options,
      headers: {'Accept': 'application/json', ...(options.headers || {})},
    });
    let data;
    try {
      data = await response.json();
    } catch (_) {
      throw new Error(`Ungültige Portal-Antwort (HTTP ${response.status}).`);
    }
    if (!response.ok && !data?.error) throw new Error(`HTTP ${response.status}`);
    return data;
  }

  function updateStatusBadges() {
    setBadge(profilesStatus, !loaded ? 'Nicht geladen' : dirty ? 'Ungespeichert' : 'Gespeichert', !loaded ? 'light' : dirty ? 'warning' : 'success');
    const selected = selectedProfileId && profilesDocument?.profiles?.[selectedProfileId];
    if (profileActiveState) {
      if (!selected) setBadge(profileActiveState, 'Kein Profil', 'light');
      else if (fields.enabled && !fields.enabled.checked) setBadge(profileActiveState, 'Inaktiv', 'secondary');
      else setBadge(profileActiveState, 'Aktiv', 'success');
    }

    const idx = serverIndex();
    const server = idx === null ? null : inventory.find((item) => Number(item.idx) === idx);
    if (contextServer) contextServer.textContent = server ? `${server.name} · online` : 'Kein Server';
    if (contextProfiles) {
      const count = profileIds().length;
      const active = isObject(profilesDocument?.profiles)
        ? Object.values(profilesDocument.profiles).filter((profile) => isObject(profile) && profile.enabled !== false).length
        : 0;
      contextProfiles.textContent = loaded ? `${count} · ${active} aktiv` : 'Nicht geladen';
    }
    if (contextStatus) contextStatus.textContent = !loaded ? 'Noch nicht geladen' : dirty ? 'Ungespeicherte Änderungen' : 'Alles gespeichert';
  }

  function setProfileControlsDisabled(disabled) {
    profileForm.querySelectorAll('[data-profile-control]').forEach((control) => {
      control.disabled = disabled;
    });
    profileIdInput.disabled = disabled;
    renameProfileButton.disabled = disabled;
    profileForm.classList.toggle('is-disabled', disabled);
  }

  function updateButtons() {
    const idx = serverIndex();
    const hasSelected = Boolean(selectedProfileId && profilesDocument?.profiles?.[selectedProfileId]);

    serverSelect.disabled = busy || inventory.length === 0;
    loadButton.disabled = busy || idx === null;
    formatButton.disabled = busy || !loaded;
    validateButton.disabled = busy || !loaded;
    saveButton.disabled = busy || !loaded || !dirty;
    saveButton.classList.toggle('btn-success', loaded && dirty && !busy);
    saveButton.classList.toggle('btn-outline-secondary', !loaded || !dirty || busy);
    saveButton.innerHTML = loaded && !dirty ? '<i class="bi bi-check2-circle me-1"></i> Gespeichert' : '<i class="bi bi-save me-1"></i> Speichern';
    if (saveJsonButton) saveJsonButton.disabled = busy || !loaded;
    if (profileSearchReset) profileSearchReset.disabled = busy || !loaded || !profileSearch.value;
    loadBackupsButton.disabled = busy;
    backupSelect.disabled = busy || backupSelect.options.length <= 1;
    restoreButton.disabled = busy || !backupSelect.value;
    profilesEditor.disabled = busy || !loaded;
    profileSearch.disabled = busy || !loaded || !profilesDocument;
    addProfileButton.disabled = busy || !loaded || !profilesDocument;
    if (repositoryAssistantButton) repositoryAssistantButton.disabled = busy || idx === null;
    duplicateProfileButton.disabled = busy || !hasSelected;
    deleteProfileButton.disabled = busy || !hasSelected;
    applyFullJsonButton.disabled = busy || !loaded;
    if (advancedToggleButton) advancedToggleButton.disabled = busy || !loaded;
    setProfileControlsDisabled(busy || !loaded || !hasSelected);
    updateDependentFields();
    updateStatusBadges();
  }

  function setBusy(value) {
    busy = value;
    updateButtons();
  }

  function markDirty() {
    if (formHydrating) return;
    dirty = true;
    updateStatusBadges();
  }

  function profileIds() {
    if (!isObject(profilesDocument) || !isObject(profilesDocument.profiles)) return [];
    return Object.keys(profilesDocument.profiles).sort((a, b) => a.localeCompare(b, 'de'));
  }

  function optionalString(control) {
    const value = String(control.value || '').trim();
    return value === '' ? undefined : value;
  }

  function optionalNumber(control, label, {integer = true, min = null, max = null} = {}) {
    const raw = String(control.value || '').trim();
    if (raw === '') return undefined;
    const number = Number(raw);
    if (!Number.isFinite(number) || (integer && !Number.isInteger(number))) throw new Error(`${label} ist keine gültige ${integer ? 'Ganzzahl' : 'Zahl'}.`);
    if (min !== null && number < min) throw new Error(`${label} muss mindestens ${min} sein.`);
    if (max !== null && number > max) throw new Error(`${label} darf höchstens ${max} sein.`);
    return number;
  }

  function modeDisplay(value) {
    if (typeof value === 'number' && Number.isInteger(value)) return value.toString(8).padStart(4, '0');
    return value === undefined || value === null ? '' : String(value);
  }

  function renderProfilesSummary() {
    if (!profilesDocument) {
      profilesSummary.innerHTML = '<div class="gce-validation-state is-error"><i class="bi bi-x-circle"></i><div><strong>Gesamte Datei ist noch nicht übernommen</strong><span>JSON korrigieren und „JSON übernehmen“ ausführen.</span></div></div>';
      return;
    }
    const ids = profileIds();
    const active = ids.filter((id) => profilesDocument.profiles[id]?.enabled !== false).length;
    const preserveCount = ids.reduce((sum, id) => { const p = profilesDocument.profiles[id] || {}; const values = p.preserve_paths ?? p.preserve; return sum + (Array.isArray(values) ? values.length : 0); }, 0);
    const serviceCount = ids.filter((id) => { const p = profilesDocument.profiles[id] || {}; return String(p.restart_service || p.service || '').trim() !== ''; }).length;
    profilesSummary.innerHTML = `<div class="gce-summary-grid">
      <div class="gce-summary-card"><span>Profile</span><strong>${ids.length}</strong></div>
      <div class="gce-summary-card"><span>Aktiv</span><strong>${active}</strong></div>
      <div class="gce-summary-card"><span>Mit Service</span><strong>${serviceCount}</strong></div>
      <div class="gce-summary-card"><span>Persistente Pfade</span><strong>${preserveCount}</strong></div>
      <div class="gce-summary-card gce-summary-wide"><span>Schema-Version</span><strong>${escapeHtml(profilesDocument.schema_version ?? '—')}</strong></div>
    </div>`;
  }

  function profileMeta(profile) {
    const preserve = profile?.preserve_paths ?? profile?.preserve;
    return {
      target: String(profile?.target_path || profile?.target || 'kein Zielpfad'),
      mode: String(profile?.deploy_mode || profile?.advanced?.deploy_mode || 'directory_swap'),
      enabled: profile?.enabled !== false,
      preserve: Array.isArray(preserve) ? preserve.length : 0,
    };
  }

  function renderProfileList() {
    const ids = profileIds();
    const query = profileSearch.value.trim().toLocaleLowerCase('de');
    const visibleIds = ids.filter((id) => {
      const profile = profilesDocument.profiles[id] || {};
      const haystack = `${id} ${profile.target_path || profile.target || ''} ${profile.git_url || profile.repository || ''} ${profile.restart_service || profile.service || ''}`.toLocaleLowerCase('de');
      return !query || haystack.includes(query);
    });
    profileCount.textContent = String(ids.length);
    profileList.innerHTML = visibleIds.map((id) => {
      const profile = profilesDocument.profiles[id] || {};
      const meta = profileMeta(profile);
      const preserveChip = meta.preserve > 0 ? `<span>${meta.preserve} persistent</span>` : '';
      return `<button type="button" class="gce-master-item${id === selectedProfileId ? ' active' : ''}" data-profile-id="${escapeHtml(id)}" role="option" aria-selected="${id === selectedProfileId ? 'true' : 'false'}">
        <span class="gce-master-icon"><i class="bi bi-box"></i></span>
        <span class="gce-master-copy"><strong>${escapeHtml(id)}</strong><small>${escapeHtml(meta.target)}</small><span class="gce-master-chips"><span>${escapeHtml(meta.mode)}</span>${preserveChip}</span></span>
        <span class="gce-dot ${meta.enabled ? 'is-on' : 'is-off'}" title="${meta.enabled ? 'Aktiv' : 'Inaktiv'}"></span>
      </button>`;
    }).join('');
    profileListEmpty.classList.toggle('d-none', visibleIds.length > 0);
    if (visibleIds.length === 0) {
      profileListEmpty.querySelector('strong').textContent = ids.length ? 'Keine passenden Profile' : 'Keine Profile vorhanden';
      profileListEmpty.querySelector('span').textContent = ids.length ? 'Suche ändern oder leeren.' : 'Über + ein neues Profil erstellen.';
    }
    profileList.querySelectorAll('[data-profile-id]').forEach((button) => {
      button.addEventListener('click', () => selectProfile(String(button.dataset.profileId || '')));
    });
  }

  function createArgRow(value = '') {
    const row = document.createElement('div');
    row.className = 'gce-array-row';
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'form-control form-control-sm font-monospace';
    input.value = String(value ?? '');
    input.placeholder = '/usr/bin/perl oder --option';
    input.dataset.profileControl = '1';
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'btn btn-outline-danger btn-sm';
    remove.title = 'Argument entfernen';
    remove.innerHTML = '<i class="bi bi-trash"></i>';
    remove.dataset.profileControl = '1';
    remove.addEventListener('click', () => { row.remove(); markDirty(); });
    input.addEventListener('input', markDirty);
    row.append(input, remove);
    return row;
  }

  function setArgRows(container, values) {
    container.innerHTML = '';
    (Array.isArray(values) ? values : []).forEach((value) => container.append(createArgRow(value)));
  }

  function getArgRows(container) {
    return [...container.querySelectorAll('input')].map((input) => input.value).filter((value) => value !== '');
  }

  function createPreserveRow(spec = {}) {
    const row = document.createElement('div');
    row.className = 'gce-preserve-row';
    row.innerHTML = `
      <div class="gce-preserve-main"><label class="form-label">Relativer Pfad</label><input type="text" class="form-control form-control-sm font-monospace" data-preserve="path" placeholder="config.json"></div>
      <div><label class="form-label">Policy</label><select class="form-select form-select-sm" data-preserve="policy"><option value="preserve_existing">preserve_existing</option><option value="create_if_missing">create_if_missing</option><option value="replace_from_git">replace_from_git</option></select></div>
      <label class="gce-preserve-required"><input class="form-check-input" type="checkbox" data-preserve="required"><span>Pflicht</span></label>
      <div><label class="form-label">Benutzer</label><input type="text" class="form-control form-control-sm" data-preserve="user" placeholder="optional"></div>
      <div><label class="form-label">Gruppe</label><input type="text" class="form-control form-control-sm" data-preserve="group" placeholder="optional"></div>
      <div><label class="form-label">Modus</label><input type="text" class="form-control form-control-sm font-monospace" data-preserve="mode" placeholder="0660"></div>
      <button type="button" class="btn btn-outline-danger btn-sm gce-preserve-remove" title="Pfad entfernen"><i class="bi bi-trash"></i></button>`;
    row.querySelector('[data-preserve="path"]').value = String(spec.path || '');
    row.querySelector('[data-preserve="policy"]').value = String(spec.policy || 'preserve_existing');
    row.querySelector('[data-preserve="required"]').checked = spec.required !== false;
    row.querySelector('[data-preserve="user"]').value = String(spec.user || '');
    row.querySelector('[data-preserve="group"]').value = String(spec.group || '');
    row.querySelector('[data-preserve="mode"]').value = modeDisplay(spec.mode);
    row.querySelectorAll('input, select').forEach((control) => { control.dataset.profileControl = '1'; control.addEventListener('input', markDirty); control.addEventListener('change', markDirty); });
    const remove = row.querySelector('.gce-preserve-remove');
    remove.dataset.profileControl = '1';
    remove.addEventListener('click', () => { row.remove(); preserveEmpty.classList.toggle('d-none', preserveList.children.length > 0); markDirty(); });
    return row;
  }

  function setPreserveRows(specs) {
    preserveList.innerHTML = '';
    (Array.isArray(specs) ? specs : []).forEach((spec) => preserveList.append(createPreserveRow(spec)));
    preserveEmpty.classList.toggle('d-none', preserveList.children.length > 0);
  }

  function getPreserveRows() {
    return [...preserveList.querySelectorAll('.gce-preserve-row')].map((row, index) => {
      const path = row.querySelector('[data-preserve="path"]').value.trim();
      if (!path) throw new Error(`Persistenter Pfad ${index + 1}: path fehlt.`);
      const item = {
        path,
        policy: row.querySelector('[data-preserve="policy"]').value,
        required: row.querySelector('[data-preserve="required"]').checked,
      };
      for (const key of ['user', 'group', 'mode']) {
        const value = row.querySelector(`[data-preserve="${key}"]`).value.trim();
        if (value) item[key] = value;
      }
      return item;
    });
  }

  function updateDependentFields() {
    const hasSelected = Boolean(selectedProfileId && profilesDocument?.profiles?.[selectedProfileId]);
    const disable = busy || !loaded || !hasSelected;
    const preflightOn = fields.preflightEnabled.checked;
    preflightFields.classList.toggle('is-inactive', !preflightOn);
    preflightFields.querySelectorAll('input, button').forEach((control) => { control.disabled = disable || !preflightOn; });
    const postDeployOn = fields.postDeployEnabled.checked;
    postDeployFields.classList.toggle('is-inactive', !postDeployOn);
    postDeployFields.querySelectorAll('input, button').forEach((control) => { control.disabled = disable || !postDeployOn; });
    const healthExec = fields.healthType.value === 'exec';
    healthExecFields.classList.toggle('d-none', !healthExec);
    healthTimeoutWrap.classList.toggle('d-none', !healthExec);
    healthExecFields.querySelectorAll('input, button').forEach((control) => { control.disabled = disable || !healthExec; });
    fields.healthTimeout.disabled = disable || !healthExec;
  }

  function populateProfileForm(profile) {
    profile = normalizedProfileForForm(profile, selectedProfileId || 'deployment');
    formHydrating = true;
    profileIdInput.value = selectedProfileId || '';
    fields.enabled.checked = profile.enabled !== false;
    fields.deployMode.value = String(profile.deploy_mode || 'symlink_release');
    fields.gitUrl.value = String(profile.git_url || '');
    fields.allowedRef.value = advancedMode ? String(profile.allowed_ref || '') : simpleRef(profile.allowed_ref || 'main');
    fields.refPolicy.value = String(profile.ref_policy || ((String(profile.allowed_ref || '').startsWith('refs/tags/')) ? 'exact' : 'ancestor'));
    fields.targetPath.value = String(profile.target_path || '');
    fields.releasesDir.value = String(profile.releases_dir || '');
    fields.keepReleases.value = profile.keep_releases ?? '';
    fields.immutablePermissions.checked = profile.immutable_permissions !== false;
    fields.user.value = String(profile.user || '');
    fields.group.value = String(profile.group || '');
    fields.restartService.value = String(profile.restart_service || '');
    fields.daemonReload.checked = Boolean(profile.daemon_reload);
    fields.authScheme.value = String(profile.auth_scheme || '');
    fields.deployUser.value = String(profile.deploy_user || '');
    fields.caInfo.value = String(profile.ca_info || '');
    fields.allowSymlinks.checked = profile.allow_symlinks !== false;
    fields.rejectHardlinks.checked = profile.reject_hardlinks !== false;
    fields.rejectLfsPointers.checked = profile.reject_lfs_pointers !== false;
    fields.requireSignedCommit.checked = Boolean(profile.require_signed_commit);
    fields.maxFiles.value = profile.max_files ?? '';
    fields.maxBytes.value = profile.max_bytes ?? '';
    fields.maxTreeListingBytes.value = profile.max_tree_listing_bytes ?? '';

    const preflight = isObject(profile.preflight) ? profile.preflight : null;
    fields.preflightEnabled.checked = Boolean(preflight);
    fields.preflightCwd.value = String(preflight?.cwd || '');
    fields.preflightTimeout.value = preflight?.timeout ?? '';
    setArgRows(preflightArgs, preflight?.argv || []);

    const postDeploy = isObject(profile.post_deploy) ? profile.post_deploy : null;
    fields.postDeployEnabled.checked = Boolean(postDeploy);
    fields.postDeployScript.value = String(postDeploy?.script || '');
    fields.postDeployTimeout.value = postDeploy?.timeout ?? '';
    fields.postDeployRollback.checked = postDeploy ? postDeploy.run_on_rollback !== false : true;
    setArgRows(postDeployArgs, postDeploy?.args || (Array.isArray(postDeploy?.argv) ? postDeploy.argv.slice(1) : []));

    const health = isObject(profile.healthcheck) ? profile.healthcheck : null;
    fields.healthType.value = String(health?.type || '');
    fields.healthWait.value = health?.wait_seconds ?? '';
    fields.healthTimeout.value = health?.timeout ?? '';
    setArgRows(healthArgs, health?.argv || []);
    setPreserveRows(profile.preserve_paths || []);

    const extra = {};
    Object.entries(profile).forEach(([key, value]) => { if (!KNOWN_PROFILE_KEYS.has(key)) extra[key] = value; });
    fields.extra.value = prettyValue(extra);
    if (packagePlan) {
      const repos = Array.isArray(profile.package_repositories) ? profile.package_repositories : [];
      const packages = Array.isArray(profile.packages) ? profile.packages : [];
      const pkgText = packages.map((item) => typeof item === 'string' ? item : `${item.name || '?'}${item.version ? ' = '+item.version : ''} (${item.state || 'present'})`);
      const repoText = repos.map((r) => `${r.id || '?'} -> ${r.url || r.local_path || '?'}`);
      packagePlan.innerHTML = (repoText.length || pkgText.length)
        ? `${repoText.length ? '<div><strong>Repository:</strong> '+repoText.map(escapeHtml).join(', ')+'</div>' : ''}${pkgText.length ? '<div class="mt-1"><strong>Pakete:</strong> '+pkgText.map(escapeHtml).join(', ')+'</div>' : ''}`
        : (profile.allow_repository_package_plan
            ? '<div><strong>Quelle:</strong> Git-Repository <code>deploy-profile.json</code></div><div class="mt-1"><code>install.sh</code> wird nach Aktivierung des Git-Releases automatisch gestartet und setzt Repository + Paketplan aus diesem Commit um.</div>'
            : 'Keine Pakete im Profil definiert.');
    }
    formHydrating = false;
    updateDependentFields();
  }

  function buildProfileFromForm() {
    let extra;
    try {
      extra = JSON.parse(fields.extra.value || '{}');
      if (!isObject(extra)) throw new Error('Zusätzliche Felder müssen ein JSON-Objekt sein.');
    } catch (error) {
      throw new Error(`Zusätzliche Profilfelder: ${error.message}`);
    }

    const gitUrl = fields.gitUrl.value.trim();
    const target = fields.targetPath.value.trim();
    const refInput = fields.allowedRef.value.trim() || 'main';
    const allowedRef = refInput.startsWith('refs/') ? refInput : `refs/heads/${refInput}`;
    if (!gitUrl) throw new Error('Repository fehlt.');
    if (!target) throw new Error('Zielpfad fehlt.');

    const preserveRows = getPreserveRows();
    if (!advancedMode) {
      const profile = {...extra};
      if (!fields.enabled.checked) profile.enabled = false;
      profile.repository = gitUrl;
      if (allowedRef.startsWith('refs/tags/')) profile.tag = allowedRef.slice(10);
      else profile.branch = allowedRef.startsWith('refs/heads/') ? allowedRef.slice(11) : allowedRef;
      profile.target = target;
      const owner = optionalString(fields.user); if (owner !== undefined) profile.owner = owner;
      const group = optionalString(fields.group); if (group !== undefined) profile.group = group;
      const service = optionalString(fields.restartService); if (service !== undefined) profile.service = service;

      if (preserveRows.length) {
        profile.preserve = preserveRows.map((item) => {
          const compact = {path: item.path};
          if (item.policy && item.policy !== 'preserve_existing') compact.policy = item.policy;
          if (item.required) compact.required = true;
          if (item.user) compact.owner = item.user;
          if (item.group) compact.group = item.group;
          if (item.mode) compact.mode = item.mode;
          return Object.keys(compact).length === 1 ? compact.path : compact;
        });
      }

      if (fields.preflightEnabled.checked) {
        const argv = getArgRows(preflightArgs);
        if (!argv.length) throw new Error('Preflight ist aktiviert, aber argv ist leer.');
        const cwd = optionalString(fields.preflightCwd);
        const timeout = optionalNumber(fields.preflightTimeout, 'Preflight-Timeout', {integer: true, min: 1});
        if ((cwd === undefined || cwd === '{release}') && (timeout === undefined || timeout === 30)) profile.preflight = argv;
        else {
          profile.preflight = {argv};
          if (cwd !== undefined) profile.preflight.cwd = cwd;
          if (timeout !== undefined) profile.preflight.timeout = timeout;
        }
      }

      if (fields.postDeployEnabled.checked) {
        const script = fields.postDeployScript.value.trim();
        if (!script) throw new Error('Installationsskript ist aktiviert, aber der Skriptpfad fehlt.');
        if (script.startsWith('/') || script.split('/').includes('..')) throw new Error('Installationsskript muss ein relativer Pfad innerhalb des Repositorys sein.');
        const timeout = optionalNumber(fields.postDeployTimeout, 'Post-Deploy-Timeout', {integer: true, min: 1, max: 900}) ?? 120;
        profile.post_deploy = {script, args: getArgRows(postDeployArgs), timeout, run_on_rollback: fields.postDeployRollback.checked};
      }

      const advanced = {};
      const derivedRelease = derivedReleaseDir(selectedProfileId || 'deployment', target);
      if (fields.deployMode.value !== 'directory_swap') advanced.deploy_mode = fields.deployMode.value;
      if (allowedRef.startsWith('refs/tags/')) {
        if (fields.refPolicy.value !== 'exact') advanced.ref_policy = fields.refPolicy.value;
      } else if (fields.refPolicy.value !== 'ancestor') advanced.ref_policy = fields.refPolicy.value;
      const releases = optionalString(fields.releasesDir);
      if (releases !== undefined && releases !== derivedRelease) advanced.releases_dir = releases;
      const keep = optionalNumber(fields.keepReleases, 'Releases behalten', {integer: true, min: 2}); if (keep !== undefined && keep !== 5) advanced.keep_releases = keep;
      if (!fields.immutablePermissions.checked) advanced.immutable_permissions = false;
      if (fields.daemonReload.checked) advanced.daemon_reload = true;
      if (!fields.allowSymlinks.checked) advanced.allow_symlinks = false;
      if (!fields.rejectHardlinks.checked) advanced.reject_hardlinks = false;
      if (!fields.rejectLfsPointers.checked) advanced.reject_lfs_pointers = false;
      if (fields.requireSignedCommit.checked) advanced.require_signed_commit = true;
      for (const [key, control] of [['auth_scheme',fields.authScheme],['deploy_user',fields.deployUser],['ca_info',fields.caInfo]]) {
        const value = optionalString(control); if (value !== undefined) advanced[key] = value;
      }
      for (const [key, control, label] of [['max_files',fields.maxFiles,'Maximale Dateien'],['max_bytes',fields.maxBytes,'Maximale Bytes'],['max_tree_listing_bytes',fields.maxTreeListingBytes,'Max. Tree-Listing Bytes']]) {
        const value = optionalNumber(control,label,{integer:true,min:1}); if (value !== undefined) advanced[key]=value;
      }
      const healthType = fields.healthType.value;
      if (healthType) {
        advanced.healthcheck = {type: healthType};
        const wait = optionalNumber(fields.healthWait, 'Healthcheck-Wartezeit', {integer:false,min:0,max:60}); if (wait !== undefined) advanced.healthcheck.wait_seconds=wait;
        if (healthType === 'exec') {
          const argv=getArgRows(healthArgs); if (!argv.length) throw new Error('Healthcheck-Typ exec benötigt mindestens ein argv-Argument.');
          advanced.healthcheck.argv=argv;
          const timeout=optionalNumber(fields.healthTimeout,'Healthcheck-Timeout',{integer:true,min:1}); if (timeout !== undefined) advanced.healthcheck.timeout=timeout;
        }
      }
      if (Object.keys(advanced).length) profile.advanced = advanced;
      return profile;
    }

    const conflicting = Object.keys(extra).filter((key) => KNOWN_PROFILE_KEYS.has(key));
    if (conflicting.length) throw new Error(`Zusätzliche Profilfelder enthalten bereits abgebildete Schlüssel: ${conflicting.join(', ')}.`);
    const profile = {...extra};
    profile.enabled = fields.enabled.checked;
    profile.deploy_mode = fields.deployMode.value;
    profile.git_url = gitUrl;
    profile.allowed_ref = allowedRef;
    profile.ref_policy = fields.refPolicy.value;
    profile.target_path = target;
    const optional = [['releases_dir',fields.releasesDir],['user',fields.user],['group',fields.group],['restart_service',fields.restartService],['auth_scheme',fields.authScheme],['deploy_user',fields.deployUser],['ca_info',fields.caInfo]];
    optional.forEach(([key,control]) => { const value=optionalString(control); if (value !== undefined) profile[key]=value; });
    profile.daemon_reload=fields.daemonReload.checked;
    profile.immutable_permissions=fields.immutablePermissions.checked;
    profile.allow_symlinks=fields.allowSymlinks.checked;
    profile.reject_hardlinks=fields.rejectHardlinks.checked;
    profile.reject_lfs_pointers=fields.rejectLfsPointers.checked;
    profile.require_signed_commit=fields.requireSignedCommit.checked;
    const keep=optionalNumber(fields.keepReleases,'Releases behalten',{integer:true,min:2}); if (keep !== undefined) profile.keep_releases=keep;
    const maxFiles=optionalNumber(fields.maxFiles,'Maximale Dateien',{integer:true,min:1}); if (maxFiles !== undefined) profile.max_files=maxFiles;
    const maxBytes=optionalNumber(fields.maxBytes,'Maximale Bytes',{integer:true,min:1}); if (maxBytes !== undefined) profile.max_bytes=maxBytes;
    const maxTree=optionalNumber(fields.maxTreeListingBytes,'Max. Tree-Listing Bytes',{integer:true,min:1}); if (maxTree !== undefined) profile.max_tree_listing_bytes=maxTree;
    profile.preserve_paths=preserveRows;
    if (fields.preflightEnabled.checked) {
      const argv=getArgRows(preflightArgs); if (!argv.length) throw new Error('Preflight ist aktiviert, aber argv ist leer.');
      profile.preflight={argv}; const cwd=optionalString(fields.preflightCwd); const timeout=optionalNumber(fields.preflightTimeout,'Preflight-Timeout',{integer:true,min:1}); if (cwd !== undefined) profile.preflight.cwd=cwd; if (timeout !== undefined) profile.preflight.timeout=timeout;
    }
    if (fields.postDeployEnabled.checked) {
      const script=fields.postDeployScript.value.trim(); if (!script) throw new Error('Installationsskript ist aktiviert, aber der Skriptpfad fehlt.');
      if (script.startsWith('/') || script.split('/').includes('..')) throw new Error('Installationsskript muss ein relativer Pfad innerhalb des Repositorys sein.');
      profile.post_deploy={script,args:getArgRows(postDeployArgs),timeout:optionalNumber(fields.postDeployTimeout,'Post-Deploy-Timeout',{integer:true,min:1,max:900}) ?? 120,run_on_rollback:fields.postDeployRollback.checked};
    }
    const healthType=fields.healthType.value;
    if (healthType) { profile.healthcheck={type:healthType}; const wait=optionalNumber(fields.healthWait,'Healthcheck-Wartezeit',{integer:false,min:0,max:60}); if (wait !== undefined) profile.healthcheck.wait_seconds=wait; if (healthType==='exec') { const argv=getArgRows(healthArgs); if (!argv.length) throw new Error('Healthcheck-Typ exec benötigt mindestens ein argv-Argument.'); profile.healthcheck.argv=argv; const timeout=optionalNumber(fields.healthTimeout,'Healthcheck-Timeout',{integer:true,min:1}); if (timeout !== undefined) profile.healthcheck.timeout=timeout; } }
    return profile;
  }

  function renderSelectedProfile() {
    const profile = selectedProfileId && profilesDocument?.profiles?.[selectedProfileId];
    const hasProfile = isObject(profile);
    profileEmpty.classList.toggle('d-none', hasProfile);
    profileDetail.classList.toggle('d-none', !hasProfile);
    if (!hasProfile) {
      profileIdInput.value = '';
      setProfileControlsDisabled(true);
      return;
    }
    populateProfileForm(profile);
    profileTitle.textContent = selectedProfileId;
    profilePath.textContent = String(profile.target_path || profile.target || 'Kein Zielpfad gesetzt');
    renderProfileList();
    updateButtons();
  }

  function validateProfileId(id) {
    if (!/^[A-Za-z0-9._-]+$/.test(id)) throw new Error('Profil-ID darf nur A–Z, a–z, 0–9, Punkt, Unterstrich und Bindestrich enthalten.');
  }

  function commitSelectedProfile({showError = true} = {}) {
    if (!selectedProfileId || !profilesDocument?.profiles?.[selectedProfileId]) return true;
    try {
      const profile = buildProfileFromForm();
      profilesDocument.profiles[selectedProfileId] = profile;
      profilesEditor.value = prettyValue(profilesDocument);
      fullJsonPending = false;
      profilePath.textContent = String(profile.target_path || profile.target || 'Kein Zielpfad gesetzt');
      renderProfileList();
      renderProfilesSummary();
      return true;
    } catch (error) {
      if (showError) message(editorMessage, 'danger', `Profil „${selectedProfileId}“ ist ungültig: ${error.message}`);
      return false;
    }
  }

  function applyFullJson({showSuccess = true} = {}) {
    let parsed;
    try {
      parsed = JSON.parse(profilesEditor.value || '{}');
      if (!isObject(parsed)) throw new Error('git_deploy.json muss ein JSON-Objekt sein.');
      if (!isObject(parsed.profiles)) parsed.profiles = {};
    } catch (error) {
      message(editorMessage, 'danger', `Vollständige git_deploy.json ist ungültig: ${error.message}`);
      return false;
    }
    const previous = selectedProfileId;
    profilesDocument = parsed;
    profilesEditor.value = prettyValue(parsed);
    fullJsonPending = false;
    const ids = profileIds();
    selectedProfileId = previous && profilesDocument.profiles[previous] ? previous : (ids[0] || null);
    renderProfileList();
    renderSelectedProfile();
    renderProfilesSummary();
    if (showSuccess) message(editorMessage, 'success', 'Die vollständige JSON-Datei wurde in die Eingabemaske übernommen.');
    return true;
  }

  function syncProfilesDocumentForRequest() {
    if (fullJsonPending) {
      if (!applyFullJson({showSuccess: false})) return null;
    } else if (!commitSelectedProfile()) return null;
    profilesEditor.value = prettyValue(profilesDocument || {schema_version: 1, profiles: {}});
    return profilesEditor.value;
  }

  function selectProfile(id) {
    if (!profilesDocument?.profiles?.[id] || id === selectedProfileId) return;
    if (!commitSelectedProfile()) return;
    selectedProfileId = id;
    clearMessage(editorMessage);
    renderSelectedProfile();
  }

  function resetLoadedState() {
    loaded = false;
    dirty = false;
    profilesDocument = null;
    selectedProfileId = null;
    fullJsonPending = false;
    profilesEditor.value = '';
    profileIdInput.value = '';
    profilesSummary.innerHTML = '<div class="gce-overview-empty">Noch keine Profile geladen.</div>';
    profileList.innerHTML = '';
    profileCount.textContent = '0';
    profileListEmpty.classList.remove('d-none');
    profileEmpty.classList.remove('d-none');
    profileDetail.classList.add('d-none');
    backupItems = [];
    backupsLoaded = false;
    backupSelect.innerHTML = '<option value="">Keine Backups geladen</option>';
    if (backupList) backupList.innerHTML = '';
    backupListEmpty?.classList.remove('d-none');
    if (backupCount) backupCount.textContent = '0';
    if (backupListCount) backupListCount.textContent = '0';
    if (backupTitle) backupTitle.textContent = 'Kein Backup ausgewählt';
    if (backupMeta) backupMeta.textContent = 'deploy_profiles.json · zentral';
    if (backupPreview) backupPreview.textContent = 'Links ein Backup auswählen, um den Inhalt zu prüfen.';
    clearMessage(editorMessage);
    updateButtons();
  }

  async function loadInventory({preserveProfiles = false} = {}) {
    clearMessage(pageMessage);
    setBusy(true, 'Agenten werden geladen …');
    try {
      const data = await fetchJson(`${endpoint}?api=inventory`);
      if (!data.ok || !Array.isArray(data.servers)) throw new Error(data.error || 'Inventar konnte nicht geladen werden.');
      inventory = data.servers.filter((server) => server.online);
      const previous = serverSelect.value;
      serverSelect.innerHTML = inventory.length ? '' : '<option value="">Keine erreichbaren Agenten</option>';
      inventory.forEach((server) => serverSelect.append(new Option(`${server.name} (Agent ${server.version || '?'})`, String(server.idx))));
      if (inventory.some((server) => String(server.idx) === previous)) serverSelect.value = previous;
      else if (inventory.length) serverSelect.value = String(inventory[0].idx);
      serverSelect.dataset.previousValue = serverSelect.value;
      if (!preserveProfiles) resetLoadedState();
    } catch (error) {
      inventory = [];
      serverSelect.innerHTML = '<option value="">Laden fehlgeschlagen</option>';
      message(pageMessage, 'warning', `Agenten für Repository-Assistent nicht erreichbar: ${error.message || String(error)}`);
      if (!preserveProfiles) resetLoadedState();
    } finally {
      setBusy(false);
    }
  }

  async function loadProfiles({forAssistant = false} = {}) {
    if (dirty && !window.confirm('Ungespeicherte Änderungen verwerfen und Deploy-Profile neu laden?')) return false;
    setBusy(true, 'Zentrale Deploy-Profile werden geladen …');
    clearMessage(editorMessage);
    try {
      const data = await fetchJson(`${endpoint}?api=profiles_get`);
      if (!data.ok) throw new Error(data.error || 'Laden fehlgeschlagen.');
      const payload = data.config;
      profilesEditor.value = String(payload?.content || '');
      loaded = true;
      dirty = false;
      fullJsonPending = false;
      if (!applyFullJson({showSuccess: false})) {
        profilesDocument = null;
        selectedProfileId = null;
        renderProfileList();
        renderSelectedProfile();
        bootstrap.Tab.getOrCreateInstance(byId('gceProfilesJsonTab')).show();
      }
      if (!forAssistant && payload?.valid === false) {
        message(editorMessage, 'warning', `Der zentrale Profilkatalog wurde geladen, ist aber aktuell ungültig: ${payload.error || 'Validierungsfehler'}`);
      }
      return Boolean(profilesDocument);
    } catch (error) {
      loaded = false;
      profilesEditor.value = '';
      profilesDocument = null;
      selectedProfileId = null;
      renderProfileList();
      renderSelectedProfile();
      message(editorMessage, 'danger', error.message || String(error));
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function validateProfiles() {
    if (!loaded) return;
    const content = syncProfilesDocumentForRequest();
    if (content === null) return;
    setBusy(true, 'Deploy-Profile werden validiert …');
    try {
      const data = await fetchJson(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken}, body: JSON.stringify({action: 'profiles_validate', csrf_token: csrfToken, content})});
      if (!data.ok) throw new Error(data.error || 'Validierung fehlgeschlagen.');
      const warning = data.result?.combined_warning || data.result?.config_warning || '';
      const validatedBy = data.result?.validated_by || 'Portal';
      message(editorMessage, warning ? 'warning' : 'success', warning ? `Zentraler Profilkatalog ist gültig (Validierung: ${validatedBy}); Hinweis: ${warning}` : `Zentraler Profilkatalog ist gültig (Validierung: ${validatedBy}).`);
    } catch (error) {
      message(editorMessage, 'danger', error.message || String(error));
    } finally { setBusy(false); }
  }

  async function saveProfiles() {
    if (!loaded) return;
    const content = syncProfilesDocumentForRequest();
    if (content === null) return;
    if (!window.confirm('Zentralen Deploy-Profilkatalog speichern? Der aktuelle Stand wird vorher automatisch gesichert.')) return;
    setBusy(true, 'Zentrale Deploy-Profile werden atomar gespeichert …');
    try {
      const data = await fetchJson(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken}, body: JSON.stringify({action: 'profiles_save', csrf_token: csrfToken, content})});
      if (!data.ok) throw new Error(data.error || 'Speichern fehlgeschlagen.');
      dirty = false;
      await loadProfiles();
      const warning = data.result?.config_warning || '';
      message(editorMessage, warning || data.audit_error ? 'warning' : 'success', warning ? `Zentral gespeichert; Hinweis der Agent-Validierung: ${warning}` : data.audit_error ? `Zentral gespeichert; Audit-Warnung: ${data.audit_error}` : 'Deploy-Profile wurden zentral gespeichert und direkt neu geladen.');
    } catch (error) {
      message(editorMessage, 'danger', error.message || String(error));
    } finally { setBusy(false); }
  }

  function formatProfiles() {
    try {
      if (fullJsonTabActive() || !selectedProfileId) {
        profilesEditor.value = prettyValue(JSON.parse(profilesEditor.value || '{}'));
        fullJsonPending = true;
        if (!applyFullJson({showSuccess: false})) return;
        message(editorMessage, 'success', 'Die vollständige git_deploy.json wurde formatiert und in die Eingabemaske übernommen.');
      } else {
        if (!commitSelectedProfile()) return;
        fields.extra.value = prettyValue(JSON.parse(fields.extra.value || '{}'));
        profilesEditor.value = prettyValue(profilesDocument);
        message(editorMessage, 'success', 'Eingabemaske und JSON-Ansicht wurden synchronisiert und formatiert.');
      }
      markDirty();
    } catch (error) {
      message(editorMessage, 'danger', `JSON-Syntaxfehler: ${error.message}`);
    }
  }

  function renderBackupList() {
    if (!backupList) return;
    const selected = backupSelect.value;
    backupCount.textContent = String(backupItems.length);
    backupListCount.textContent = String(backupItems.length);
    backupList.innerHTML = backupItems.map((name) => `<button type="button" class="configuration-backup-item${name === selected ? ' active' : ''}" data-backup-name="${escapeHtml(name)}" role="option" aria-selected="${name === selected ? 'true' : 'false'}">
      <span class="configuration-backup-icon"><i class="bi bi-file-earmark-zip"></i></span>
      <span><strong>${escapeHtml(name)}</strong><small>zentraler Profilkatalog</small></span>
      <i class="bi bi-chevron-right"></i>
    </button>`).join('');
    backupListEmpty.classList.toggle('d-none', backupItems.length > 0);
    backupList.querySelectorAll('[data-backup-name]').forEach((button) => {
      button.addEventListener('click', () => selectBackup(String(button.dataset.backupName || '')));
    });
  }

  async function selectBackup(filename) {
    if (!filename) return;
    backupSelect.value = filename;
    renderBackupList();
    backupTitle.textContent = filename;
    backupMeta.textContent = 'Inhalt wird geladen …';
    backupPreview.textContent = 'Backup wird geladen …';
    restoreButton.disabled = true;
    clearMessage(editorMessage);
    try {
      const data = await fetchJson(`${endpoint}?api=profiles_backup_get&filename=${encodeURIComponent(filename)}`);
      if (!data.ok) throw new Error(data.error || 'Backup konnte nicht geladen werden.');
      const backup = data.backup || {};
      const content = String(backup.content || '');
      try { backupPreview.textContent = JSON.stringify(JSON.parse(content), null, 2); }
      catch (_) { backupPreview.textContent = content; }
      const summary = backup.summary || {};
      backupMeta.textContent = `${summary.profiles ?? '—'} Profil(e) · deploy_profiles.json · zentral`;
    } catch (error) {
      backupMeta.textContent = 'Vorschau nicht verfügbar';
      backupPreview.textContent = 'Die Backup-Vorschau konnte nicht geladen werden.';
      message(editorMessage, 'danger', error.message || String(error));
    } finally {
      updateButtons();
    }
  }

  async function loadBackups(showSuccess = true) {
    try {
      const data = await fetchJson(`${endpoint}?api=profiles_backups`);
      if (!data.ok || !Array.isArray(data.backups)) throw new Error(data.error || 'Backups konnten nicht geladen werden.');
      backupItems = data.backups.map(String);
      backupsLoaded = true;
      backupSelect.innerHTML = '<option value="">Backup wählen …</option>';
      backupItems.forEach((name) => backupSelect.append(new Option(name, name)));
      renderBackupList();
      if (showSuccess) message(editorMessage, 'success', `${backupItems.length} Backup(s) geladen.`);
    } catch (error) {
      backupItems = [];
      backupsLoaded = false;
      backupSelect.innerHTML = '<option value="">Backups nicht verfügbar</option>';
      renderBackupList();
      if (showSuccess) message(editorMessage, 'danger', error.message || String(error));
    } finally { updateButtons(); }
  }

  async function restoreProfiles() {
    const filename = backupSelect.value;
    if (!filename) return;
    if (!window.confirm(`${filename} als zentralen Profilkatalog wiederherstellen? Der aktuelle Stand wird vorher erneut gesichert.`)) return;
    setBusy(true, 'Backup der Deploy-Profile wird wiederhergestellt …');
    try {
      const data = await fetchJson(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken}, body: JSON.stringify({action: 'profiles_restore', csrf_token: csrfToken, filename})});
      if (!data.ok) throw new Error(data.error || 'Restore fehlgeschlagen.');
      dirty = false;
      await loadProfiles();
      message(editorMessage, data.result?.config_warning ? 'warning' : 'success', `${filename} wurde als zentraler Profilkatalog wiederhergestellt.`);
    } catch (error) { message(editorMessage, 'danger', error.message || String(error)); }
    finally { setBusy(false); }
  }



  function assistantAlert(type, text) {
    if (!assistantMessage) return;
    assistantMessage.className = `alert alert-${type}`;
    assistantMessage.textContent = text;
    assistantMessage.classList.remove('d-none');
  }

  function assistantClearAlert() {
    if (!assistantMessage) return;
    assistantMessage.classList.add('d-none');
    assistantMessage.textContent = '';
  }

  function assistantSetBusy(value, text = '') {
    assistantBusy = value;
    assistantRepository.disabled = value || assistantRepositories.length === 0;
    assistantBranch.disabled = value || assistantBranches.length === 0;
    assistantRefreshRepos.disabled = value;
    assistantScanButton.disabled = value || !assistantRepository.value || !assistantBranch.value;
    assistantApply.disabled = value || !assistantScan;
    if (value && text) assistantAlert('info', text);
  }

  function assistantRepoValue(repo) {
    return `${repo.owner}/${repo.name}`;
  }

  function assistantSelectedRepository() {
    return assistantRepositories.find((repo) => assistantRepoValue(repo) === assistantRepository.value) || null;
  }

  function suggestedProfileId(name) {
    const cleaned = String(name || 'deployment').toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
    let id = cleaned || 'deployment';
    let n = 2;
    while (profilesDocument?.profiles?.[id]) id = `${cleaned || 'deployment'}-${n++}`;
    return id;
  }

  function assistantRepositoryKey(value) {
    let raw = String(value || '').trim();
    if (!raw) return '';
    raw = raw.replace(/[?#].*$/, '').replace(/\/+$/, '').replace(/\.git$/i, '');
    let repositoryPath = raw;
    try {
      repositoryPath = new URL(raw).pathname;
    } catch (_) {
      const scp = raw.match(/^[^@\s]+@[^:\s]+:(.+)$/);
      if (scp) repositoryPath = scp[1];
    }
    try { repositoryPath = decodeURIComponent(repositoryPath); } catch (_) {}
    const parts = String(repositoryPath).replace(/^\/+|\/+$/g, '').split('/').filter(Boolean);
    if (parts.length < 2) return String(repositoryPath).toLocaleLowerCase('en');
    return `${parts[parts.length - 2]}/${parts[parts.length - 1]}`.toLocaleLowerCase('en');
  }

  function configuredAssistantRepositoryProfiles() {
    const repositories = new Map();
    const profiles = isObject(profilesDocument?.profiles) ? profilesDocument.profiles : {};
    Object.entries(profiles).forEach(([profileId, profile]) => {
      if (!isObject(profile)) return;
      const key = assistantRepositoryKey(profile.git_url || profile.repository || '');
      if (!key) return;
      if (!repositories.has(key)) repositories.set(key, []);
      repositories.get(key).push(profileId);
    });
    return repositories;
  }

  function assistantRepositoryProfiles(repo) {
    const key = assistantRepositoryKey(repo?.full_name || repo?.clone_url || assistantRepoValue(repo || {}));
    return configuredAssistantRepositoryProfiles().get(key) || [];
  }

  function updateAssistantRepositoryStatus() {
    const selected = assistantSelectedRepository();
    const configured = configuredAssistantRepositoryProfiles();
    const usedCount = assistantAllRepositories.filter((repo) => configured.has(assistantRepositoryKey(repo.full_name || repo.clone_url || assistantRepoValue(repo)))).length;
    if (selected) {
      const profileIds = assistantRepositoryProfiles(selected);
      assistantRepositoryStatus.textContent = profileIds.length
        ? `Repository ist bereits in ${profileIds.length} Deployment-Profil(en) verwendet: ${profileIds.join(', ')}. Ein weiteres Profil oder ein anderer Branch kann trotzdem erstellt werden.`
        : 'Repository ist noch in keinem Deployment-Profil verwendet.';
      return;
    }
    assistantRepositoryStatus.textContent = `${assistantAllRepositories.length} zugängliche Repository(s) verfügbar${usedCount ? ` · ${usedCount} bereits in git_deploy.json verwendet und markiert` : ''}.`;
  }

  async function loadAssistantRepositories(refresh = false) {
    const idx = serverIndex();
    if (idx === null) return;
    assistantSetBusy(true, 'Forgejo-Repositorys werden geladen …');
    assistantScan = null;
    assistantResult.classList.add('d-none');
    assistantRepositoryStatus.textContent = 'Repositorys werden mit der aktuellen git_deploy.json abgeglichen …';
    try {
      if (fullJsonPending && !applyFullJson({showSuccess: false})) throw new Error('Die JSON-Ansicht enthält ungültige Änderungen.');
      if (!fullJsonPending && !commitSelectedProfile({showError: false})) throw new Error('Das aktuell geöffnete Profil enthält ungültige Änderungen.');
      const data = await fetchJson(`${endpoint}?api=repo_list&server_idx=${encodeURIComponent(idx)}${refresh ? '&refresh=1' : ''}`);
      if (!data.ok || !Array.isArray(data.repositories)) throw new Error(data.error || 'Repositorys konnten nicht geladen werden.');
      assistantAllRepositories = data.repositories;
      assistantRepositories = [...assistantAllRepositories];
      const configured = configuredAssistantRepositoryProfiles();
      assistantRepository.innerHTML = assistantRepositories.length
        ? '<option value="">Repository wählen …</option>'
        : '<option value="">Keine Repositorys verfügbar</option>';
      assistantRepositories.forEach((repo) => {
        const key = assistantRepositoryKey(repo.full_name || repo.clone_url || assistantRepoValue(repo));
        const profileIds = configured.get(key) || [];
        const markers = [
          repo.private ? 'privat' : '',
          repo.can_push ? '' : 'nur lesen',
          profileIds.length ? `bereits verwendet: ${profileIds.join(', ')}` : ''
        ].filter(Boolean);
        const label = `${repo.full_name}${markers.length ? ` · ${markers.join(' · ')}` : ''}`;
        assistantRepository.append(new Option(label, assistantRepoValue(repo)));
      });
      assistantBranches = [];
      assistantBranch.innerHTML = '<option value="">Zuerst Repository wählen</option>';
      updateAssistantRepositoryStatus();
      assistantClearAlert();
      if (!assistantAllRepositories.length) {
        assistantAlert('warning', 'Für den Forgejo-Benutzer wurden keine zugänglichen Repositorys gefunden.');
      }
    } catch (error) {
      assistantAllRepositories = [];
      assistantRepositories = [];
      assistantRepository.innerHTML = '<option value="">Repositorys nicht verfügbar</option>';
      assistantRepositoryStatus.textContent = 'Repository-Liste konnte nicht geladen werden.';
      assistantAlert('danger', error.message || String(error));
    } finally {
      assistantSetBusy(false);
    }
  }

  async function loadAssistantBranches() {
    const idx = serverIndex();
    const repo = assistantSelectedRepository();
    assistantScan = null;
    assistantResult.classList.add('d-none');
    assistantApply.disabled = true;
    if (idx === null || !repo) {
      assistantBranches = [];
      assistantBranch.innerHTML = '<option value="">Zuerst Repository wählen</option>';
      assistantSetBusy(false);
      return;
    }
    assistantSetBusy(true, 'Branches werden geladen …');
    try {
      const data = await fetchJson(`${endpoint}?api=repo_branches&server_idx=${encodeURIComponent(idx)}&owner=${encodeURIComponent(repo.owner)}&repository=${encodeURIComponent(repo.name)}`);
      const result = data.result || {};
      if (!data.ok || !Array.isArray(result.branches)) throw new Error(data.error || 'Branches konnten nicht geladen werden.');
      assistantBranches = result.branches;
      assistantBranch.innerHTML = '<option value="">Branch wählen …</option>';
      assistantBranches.forEach((branch) => assistantBranch.append(new Option(`${branch.name}${branch.protected ? ' · geschützt' : ''}`, branch.name)));
      const preferred = repo.default_branch || result.repository?.default_branch || 'main';
      if (assistantBranches.some((branch) => branch.name === preferred)) assistantBranch.value = preferred;
      assistantClearAlert();
    } catch (error) {
      assistantBranches = [];
      assistantBranch.innerHTML = '<option value="">Branches nicht verfügbar</option>';
      assistantAlert('danger', error.message || String(error));
    } finally {
      assistantSetBusy(false);
    }
  }

  function createAssistantPreserveRow(spec = {}) {
    const row = document.createElement('div');
    row.className = 'gce-assistant-preserve-row';
    row.innerHTML = `
      <label class="gce-assistant-select"><input type="checkbox" class="form-check-input" data-ap="selected" ${spec.selected === false ? '' : 'checked'}><span class="visually-hidden">Übernehmen</span></label>
      <div class="gce-assistant-path"><input type="text" class="form-control form-control-sm font-monospace" data-ap="path"><small>${escapeHtml(spec.reason || 'Manuell hinzugefügt')}</small></div>
      <select class="form-select form-select-sm" data-ap="policy"><option value="preserve_existing">erhalten</option><option value="create_if_missing">bei Bedarf erstellen</option><option value="replace_from_git">aus Git ersetzen</option></select>
      <label class="gce-assistant-required"><input type="checkbox" class="form-check-input" data-ap="required"><span>Pflicht</span></label>
      <input type="text" class="form-control form-control-sm" data-ap="owner" placeholder="Benutzer" title="Benutzer">
      <input type="text" class="form-control form-control-sm" data-ap="group" placeholder="Gruppe" title="Gruppe">
      <input type="text" class="form-control form-control-sm font-monospace" data-ap="mode" placeholder="0640" title="Modus">
      <button type="button" class="btn btn-outline-danger btn-sm" data-ap-remove title="Zeile entfernen"><i class="bi bi-trash"></i></button>`;
    row.querySelector('[data-ap="path"]').value = String(spec.path || '');
    row.querySelector('[data-ap="policy"]').value = String(spec.policy || 'preserve_existing');
    row.querySelector('[data-ap="required"]').checked = Boolean(spec.required);
    row.querySelector('[data-ap="owner"]').value = String(spec.owner || '');
    row.querySelector('[data-ap="group"]').value = String(spec.group || '');
    row.querySelector('[data-ap="mode"]').value = String(spec.mode || (spec.type === 'directory' ? '0770' : '0640'));
    row.querySelector('[data-ap-remove]').addEventListener('click', () => { row.remove(); assistantPreserveEmpty.classList.toggle('d-none', assistantPreserve.children.length > 0); });
    assistantPreserveEmpty.classList.add('d-none');
    return row;
  }

  function renderAssistantScan(scan) {
    const summary = scan.summary || {};
    assistantSummary.innerHTML = [
      ['Dateien', summary.files ?? 0], ['Verzeichnisse', summary.directories ?? 0],
      ['Persistent', summary.preserve_candidates ?? 0], ['Installer', summary.post_deploy_candidates ?? 0], ['Warnungen', summary.warnings ?? 0],
    ].map(([label, value]) => `<span><strong>${escapeHtml(value)}</strong>${escapeHtml(label)}</span>`).join('');

    const warnings = Array.isArray(scan.warnings) ? scan.warnings : [];
    assistantWarnings.classList.toggle('d-none', warnings.length === 0);
    assistantWarnings.innerHTML = warnings.length ? `<div class="alert alert-warning mb-0"><strong><i class="bi bi-exclamation-triangle me-1"></i>Prüfhinweise</strong><ul class="mb-0 mt-2">${warnings.map((item) => `<li>${escapeHtml(item)}</li>`).join('')}</ul></div>` : '';

    const template = scan.profile_template || {};
    assistantProfileId.value = suggestedProfileId(scan.repository?.name || 'deployment');
    assistantTarget.value = String(template.target || '');
    assistantOwner.value = String(template.owner || 'root');
    assistantGroup.value = String(template.group || 'taskmgmt');
    assistantService.value = String(template.service || '');
    assistantServiceList.innerHTML = '';
    (Array.isArray(scan.service_candidates) ? scan.service_candidates : []).forEach((item) => assistantServiceList.append(new Option(item.name, item.name)));

    assistantPreserve.innerHTML = '';
    (Array.isArray(scan.preserve_candidates) ? scan.preserve_candidates : []).forEach((item) => assistantPreserve.append(createAssistantPreserveRow(item)));
    assistantPreserveEmpty.classList.toggle('d-none', assistantPreserve.children.length > 0);

    assistantPreflight.innerHTML = '<option value="">Keine automatische Prüfung</option>';
    (Array.isArray(scan.preflight_candidates) ? scan.preflight_candidates : []).forEach((item, index) => {
      const option = new Option(item.label || item.path || `Prüfung ${index + 1}`, String(index));
      option.dataset.argv = JSON.stringify(item.argv || []);
      option.dataset.cwd = String(item.cwd || '{release}');
      option.dataset.timeout = String(item.timeout || 30);
      assistantPreflight.append(option);
      if (item.selected) assistantPreflight.value = String(index);
    });

    assistantPostDeploy.innerHTML = '<option value="">Kein Installationsskript ausführen</option>';
    (Array.isArray(scan.post_deploy_candidates) ? scan.post_deploy_candidates : []).forEach((item, index) => {
      const option = new Option(item.label || item.script || `Installer ${index + 1}`, String(index));
      option.dataset.spec = JSON.stringify({script:item.script,args:item.args || [],timeout:item.timeout || 120,run_on_rollback:item.run_on_rollback !== false});
      assistantPostDeploy.append(option);
      if (item.selected) assistantPostDeploy.value = String(index);
    });

    const files = Array.isArray(scan.files) ? scan.files : [];
    const dirs = Array.isArray(scan.directories) ? scan.directories : [];
    assistantTree.innerHTML = `<div class="gce-assistant-tree-cols"><div><strong>Verzeichnisse</strong><pre>${escapeHtml(dirs.slice(0, 250).join('\n') || '—')}</pre></div><div><strong>Dateien</strong><pre>${escapeHtml(files.slice(0, 500).map((item) => `${item.mode || ''}  ${item.path}`).join('\n') || '—')}</pre></div></div>`;
    assistantResult.classList.remove('d-none');
    assistantApply.disabled = false;
  }

  async function scanAssistantRepository() {
    const idx = serverIndex();
    const repo = assistantSelectedRepository();
    const branch = assistantBranch.value;
    if (idx === null || !repo || !branch) return;
    assistantSetBusy(true, 'Repository wird sicher geklont und analysiert …');
    try {
      const data = await fetchJson(`${endpoint}?api=repo_scan&server_idx=${encodeURIComponent(idx)}&owner=${encodeURIComponent(repo.owner)}&repository=${encodeURIComponent(repo.name)}&branch=${encodeURIComponent(branch)}`);
      if (!data.ok || !data.scan?.ok) throw new Error(data.error || data.scan?.error || 'Repository-Analyse fehlgeschlagen.');
      assistantScan = data.scan;
      renderAssistantScan(assistantScan);
      assistantAlert('success', `Repository analysiert: ${assistantScan.summary?.files ?? 0} Datei(en), Commit ${String(assistantScan.commit || '').slice(0, 10) || 'unbekannt'}.`);
    } catch (error) {
      assistantScan = null;
      assistantResult.classList.add('d-none');
      assistantAlert('danger', error.message || String(error));
    } finally {
      assistantSetBusy(false);
    }
  }

  function applyAssistantProfile() {
    if (!assistantScan || !profilesDocument) return;
    const id = assistantProfileId.value.trim();
    try {
      validateProfileId(id);
      if (profilesDocument.profiles[id]) throw new Error('Diese Profil-ID existiert bereits.');
      const target = assistantTarget.value.trim();
      if (!target.startsWith('/')) throw new Error('Der Zielpfad muss absolut sein.');
      const repo = assistantScan.repository || {};
      const profile = {
        repository: String(repo.clone_url || assistantScan.profile_template?.repository || ''),
        branch: String(assistantScan.branch || assistantBranch.value || 'main'),
        target,
        owner: assistantOwner.value.trim() || 'root',
        group: assistantGroup.value.trim() || 'taskmgmt',
      };
      const service = assistantService.value.trim();
      if (service) profile.service = service;
      const preserve = [...assistantPreserve.querySelectorAll('.gce-assistant-preserve-row')].filter((row) => row.querySelector('[data-ap="selected"]').checked).map((row) => {
        const item = {path: row.querySelector('[data-ap="path"]').value.trim()};
        if (!item.path) throw new Error('Ein ausgewählter persistenter Pfad ist leer.');
        const policy = row.querySelector('[data-ap="policy"]').value;
        if (policy !== 'preserve_existing') item.policy = policy;
        if (row.querySelector('[data-ap="required"]').checked) item.required = true;
        const owner = row.querySelector('[data-ap="owner"]').value.trim();
        const group = row.querySelector('[data-ap="group"]').value.trim();
        const mode = row.querySelector('[data-ap="mode"]').value.trim();
        if (mode) item.mode = mode;
        item.owner = owner || profile.owner;
        item.group = group || profile.group;
        return item;
      });
      if (preserve.length) profile.preserve = preserve;
      const selectedPreflight = assistantPreflight.selectedOptions[0];
      if (selectedPreflight && selectedPreflight.value !== '') {
        const argv = JSON.parse(selectedPreflight.dataset.argv || '[]');
        if (Array.isArray(argv) && argv.length) profile.preflight = argv;
      }
      const selectedPostDeploy = assistantPostDeploy.selectedOptions[0];
      if (selectedPostDeploy && selectedPostDeploy.value !== '') {
        const spec = JSON.parse(selectedPostDeploy.dataset.spec || '{}');
        if (spec.script) profile.post_deploy = spec;
      }
      if (!commitSelectedProfile()) return;
      profilesDocument.profiles[id] = profile;
      selectedProfileId = id;
      profilesEditor.value = prettyValue(profilesDocument);
      fullJsonPending = false;
      markDirty();
      renderProfileList();
      renderSelectedProfile();
      renderProfilesSummary();
      bootstrap.Modal.getOrCreateInstance(assistantModalElement).hide();
      message(editorMessage, 'success', `Profil „${id}“ wurde aus der Repository-Analyse erstellt. Bitte prüfen und anschliessend speichern.`);
    } catch (error) {
      assistantAlert('danger', error.message || String(error));
    }
  }

  async function openRepositoryAssistant() {
    if (serverIndex() === null) return;
    assistantScan = null;
    assistantResult.classList.add('d-none');
    assistantClearAlert();
    assistantRepository.innerHTML = '<option value="">Repositorys laden …</option>';
    assistantBranch.innerHTML = '<option value="">Zuerst Repository wählen</option>';
    assistantRepositoryStatus.textContent = 'Aktuelle Deploy-Profile und Forgejo-Repositorys werden abgeglichen …';
    bootstrap.Modal.getOrCreateInstance(assistantModalElement).show();
    if (!loaded || !profilesDocument) {
      assistantAlert('info', 'git_deploy.json wird jetzt ausdrücklich vom ausgewählten Server geladen.');
      const ok = await loadProfiles({forAssistant: true});
      if (!ok) {
        assistantAlert('danger', 'git_deploy.json konnte nicht geladen werden. Ohne aktuellen Stand können doppelte Repository-Profile nicht sicher verhindert werden.');
        return;
      }
    }
    await loadAssistantRepositories(false);
  }

  function defaultProfile() {
    return {
      repository: '',
      branch: 'main',
      target: '',
      owner: 'root',
      group: 'taskmgmt',
      preserve: [],
    };
  }

  function addProfile() {
    if (!profilesDocument) return;
    const proposed = window.prompt('Neue Profil-ID:', 'neues-profil');
    if (proposed === null) return;
    const id = proposed.trim();
    try {
      validateProfileId(id);
      if (profilesDocument.profiles[id]) throw new Error('Diese Profil-ID existiert bereits.');
      if (!commitSelectedProfile()) return;
      profilesDocument.profiles[id] = defaultProfile();
      selectedProfileId = id;
      profilesEditor.value = prettyValue(profilesDocument);
      markDirty();
      renderProfileList();
      renderSelectedProfile();
      message(editorMessage, 'success', `Profil „${id}“ wurde lokal angelegt. Zum Übernehmen noch speichern.`);
    } catch (error) { message(editorMessage, 'danger', error.message || String(error)); }
  }

  function duplicateProfile() {
    if (!selectedProfileId || !profilesDocument?.profiles?.[selectedProfileId]) return;
    if (!commitSelectedProfile()) return;
    const proposed = window.prompt('ID für die Kopie:', `${selectedProfileId}-copy`);
    if (proposed === null) return;
    const id = proposed.trim();
    try {
      validateProfileId(id);
      if (profilesDocument.profiles[id]) throw new Error('Diese Profil-ID existiert bereits.');
      profilesDocument.profiles[id] = deepClone(profilesDocument.profiles[selectedProfileId]);
      selectedProfileId = id;
      profilesEditor.value = prettyValue(profilesDocument);
      markDirty();
      renderProfileList();
      renderSelectedProfile();
      message(editorMessage, 'success', `Profil wurde als „${id}“ dupliziert.`);
    } catch (error) { message(editorMessage, 'danger', error.message || String(error)); }
  }

  function deleteProfile() {
    if (!selectedProfileId || !profilesDocument?.profiles?.[selectedProfileId]) return;
    if (!window.confirm(`Deployment-Profil „${selectedProfileId}“ löschen? Die Änderung wird erst beim Speichern wirksam.`)) return;
    const oldId = selectedProfileId;
    delete profilesDocument.profiles[oldId];
    selectedProfileId = profileIds()[0] || null;
    profilesEditor.value = prettyValue(profilesDocument);
    markDirty();
    renderProfileList();
    renderSelectedProfile();
    renderProfilesSummary();
    message(editorMessage, 'warning', `Profil „${oldId}“ wurde lokal entfernt. Zum Übernehmen noch speichern.`);
  }

  function renameProfile() {
    if (!selectedProfileId || !profilesDocument?.profiles?.[selectedProfileId]) return;
    const newId = profileIdInput.value.trim();
    try {
      validateProfileId(newId);
      if (newId === selectedProfileId) { message(editorMessage, 'success', 'Die Profil-ID ist unverändert.'); return; }
      if (profilesDocument.profiles[newId]) throw new Error('Diese Profil-ID existiert bereits.');
      if (!commitSelectedProfile()) return;
      const oldId = selectedProfileId;
      profilesDocument.profiles[newId] = profilesDocument.profiles[oldId];
      delete profilesDocument.profiles[oldId];
      selectedProfileId = newId;
      profilesEditor.value = prettyValue(profilesDocument);
      markDirty();
      renderProfileList();
      renderSelectedProfile();
      message(editorMessage, 'success', `Profil-ID wurde von „${oldId}“ auf „${newId}“ geändert.`);
    } catch (error) { message(editorMessage, 'danger', error.message || String(error)); }
  }

  advancedToggleButton?.addEventListener('click', () => {
    if (!commitSelectedProfile()) return;
    advancedMode = !advancedMode;
    applyAdvancedMode();
    renderSelectedProfile();
    message(editorMessage, 'info', advancedMode
      ? 'Erweiterte Optionen sind sichtbar. Beim Speichern wird das vollständige technische Profil geschrieben.'
      : 'Einfacher Modus aktiv. Beim Speichern wird das Profil auf die notwendigen Angaben reduziert.');
  });

  profileForm.addEventListener('input', (event) => {
    if (event.target === profileIdInput) return;
    if (event.target === fields.targetPath) profilePath.textContent = fields.targetPath.value.trim() || 'Kein Zielpfad gesetzt';
    markDirty();
  });
  profileForm.addEventListener('change', (event) => {
    if (event.target !== profileIdInput) markDirty();
    updateDependentFields();
  });
  profilesEditor.addEventListener('input', () => { fullJsonPending = true; markDirty(); });
  profileSearch.addEventListener('input', () => { renderProfileList(); updateButtons(); });
  profileSearchReset?.addEventListener('click', () => { profileSearch.value = ''; renderProfileList(); updateButtons(); profileSearch.focus(); });
  fields.preflightEnabled.addEventListener('change', updateDependentFields);
  fields.postDeployEnabled.addEventListener('change', updateDependentFields);
  fields.healthType.addEventListener('change', updateDependentFields);
  addPreflightArgButton.addEventListener('click', () => { preflightArgs.append(createArgRow('')); markDirty(); updateButtons(); });
  addPostDeployArgButton.addEventListener('click', () => { postDeployArgs.append(createArgRow('')); markDirty(); updateButtons(); });
  addHealthArgButton.addEventListener('click', () => { healthArgs.append(createArgRow('')); markDirty(); updateButtons(); });
  addPreserveButton.addEventListener('click', () => { preserveList.append(createPreserveRow({required: false, policy: 'preserve_existing'})); preserveEmpty.classList.add('d-none'); markDirty(); updateButtons(); });

  repositoryAssistantButton?.addEventListener('click', openRepositoryAssistant);
  assistantRefreshRepos?.addEventListener('click', () => loadAssistantRepositories(true));
  assistantRepository?.addEventListener('change', () => { updateAssistantRepositoryStatus(); loadAssistantBranches(); });
  assistantBranch?.addEventListener('change', () => { assistantScanButton.disabled = assistantBusy || !assistantBranch.value; assistantScan = null; assistantResult.classList.add('d-none'); assistantApply.disabled = true; });
  assistantScanButton?.addEventListener('click', scanAssistantRepository);
  assistantAddPreserve?.addEventListener('click', () => assistantPreserve.append(createAssistantPreserveRow({selected:true,policy:'preserve_existing',type:'file'})));
  assistantApply?.addEventListener('click', applyAssistantProfile);

  reloadButton.addEventListener('click', () => {
    loadInventory({preserveProfiles: true});
  });
  serverSelect.addEventListener('change', () => {
    serverSelect.dataset.previousValue = serverSelect.value;
  });
  loadButton.addEventListener('click', loadProfiles);
  formatButton.addEventListener('click', formatProfiles);
  validateButton.addEventListener('click', validateProfiles);
  saveButton.addEventListener('click', saveProfiles);
  saveJsonButton?.addEventListener('click', saveProfiles);
  loadBackupsButton.addEventListener('click', () => loadBackups(true));
  backupSelect.addEventListener('change', () => { if (backupSelect.value) selectBackup(backupSelect.value); else updateButtons(); });
  restoreButton.addEventListener('click', restoreProfiles);
  addProfileButton.addEventListener('click', addProfile);
  duplicateProfileButton.addEventListener('click', duplicateProfile);
  deleteProfileButton.addEventListener('click', deleteProfile);
  renameProfileButton.addEventListener('click', renameProfile);
  applyFullJsonButton.addEventListener('click', () => { if (applyFullJson()) markDirty(); });

  byId('gceProfileEditTab')?.addEventListener('shown.bs.tab', () => {
    if (fullJsonPending) applyFullJson({showSuccess: false});
  });

  byId('gceProfilesJsonTab')?.addEventListener('shown.bs.tab', () => {
    if (!fullJsonPending && commitSelectedProfile({showError: true})) {
      profilesEditor.value = prettyValue(profilesDocument || {schema_version: 1, profiles: {}});
    }
    profilesAce.resize();
    profilesAce.focus();
  });

  byId('gceBackupsTab')?.addEventListener('shown.bs.tab', () => {
    if (!backupsLoaded) loadBackups(false);
  });

  const detailTabs = [...document.querySelectorAll('.configuration-detail-tabs [data-bs-toggle="tab"]')];
  detailTabs.forEach((button) => button.addEventListener('shown.bs.tab', () => {
    try { sessionStorage.setItem('gitConfigEditor.detailTab', button.id); } catch (_) {}
  }));
  try {
    const rememberedDetailTab = sessionStorage.getItem('gitConfigEditor.detailTab');
    const rememberedButton = rememberedDetailTab ? byId(rememberedDetailTab) : null;
    if (rememberedButton && window.bootstrap?.Tab) bootstrap.Tab.getOrCreateInstance(rememberedButton).show();
  } catch (_) {}

  window.addEventListener('beforeunload', (event) => {
    if (dirty) { event.preventDefault(); event.returnValue = ''; }
  });

  updateStatusBadges();
  updateButtons();
  applyAdvancedMode();
  (async () => {
    await loadInventory({preserveProfiles: true});
    await loadProfiles();
  })();
})();
