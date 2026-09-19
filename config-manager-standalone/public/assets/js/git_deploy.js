(() => {
    'use strict';

    const cfg = window.GIT_DEPLOY_PAGE || {};
    const endpoint = String(cfg.endpoint || 'git_deploy.php');
    const csrfToken = String(cfg.csrfToken || '');

    const el = (id) => document.getElementById(id);
    const inventoryBusy = el('gitDeployInventoryBusy');
    const serverPanel = el('gitDeployServerPanel');
    const serverList = el('gitDeployServerList');
    const serverSearch = el('gitDeployServerSearch');
    const serverSummary = el('gitDeployServerSummary');
    const serverEmpty = el('gitDeployServerEmpty');
    const selectVisibleButton = el('gitDeploySelectVisible');
    const clearServersButton = el('gitDeployClearServers');
    const profileSelect = el('gitDeployProfile');
    const tokenInput = el('gitDeployToken');
    const commitSelect = el('gitDeployCommit');
    const commitLoadButton = el('gitDeployLoadCommits');
    const commitSummary = el('gitDeployCommitSummary');
    const diffPreviewButton = el('gitDeployPreviewDiff');
    const diffPreview = el('gitDeployDiffPreview');
    const tokenWrap = el('gitDeployTokenWrap');
    const tokenToggle = el('gitDeployToggleToken');
    const confirmInput = el('gitDeployConfirm');
    const profileDetails = el('gitDeployProfileDetails');
    const startButton = el('gitDeployStart');
    const statusButton = el('gitDeployLoadStatus');
    const blockReason = el('gitDeployBlockReason');
    const messageBox = el('gitDeployMessage');
    const resultEmpty = el('gitDeployResultEmpty');
    const resultBusy = el('gitDeployResultBusy');
    const resultsWrap = el('gitDeployResults');
    const resultsBody = el('gitDeployResultsBody');
    const resultSummary = el('gitDeployResultSummary');
    const nextAction = el('gitDeployNextAction');
    const workflowSteps = [1, 2, 3, 4].map((n) => el(`gitDeployStep${n}`));
    const tabButtons = Array.from(document.querySelectorAll('[data-gd-tab]'));
    const tabPanels = {
        deploy: el('gitDeployTabDeploy'),
        history: el('gitDeployTabHistory'),
        restore: el('gitDeployTabRestore'),
    };

    const restoreServerSelect = el('gitDeployRestoreServer');
    const restoreProfileSelect = el('gitDeployRestoreProfile');
    const restoreReleaseSelect = el('gitDeployRestoreRelease');
    const restoreLoadButton = el('gitDeployRestoreLoad');
    const restoreStartButton = el('gitDeployRestoreStart');
    const restoreConfirmInput = el('gitDeployRestoreConfirm');
    const restoreTokenInput = el('gitDeployRestoreToken');
    const restoreTokenWrap = el('gitDeployRestoreTokenWrap');
    const restoreMessageBox = el('gitDeployRestoreMessage');
    const restoreSummary = el('gitDeployRestoreSummary');

    const configServerSelect = el('gitDeployConfigServer');
    const configEditor = el('gitDeployConfigEditor');
    const configLoadButton = el('gitDeployConfigLoad');
    const configValidateButton = el('gitDeployConfigValidate');
    const configSaveButton = el('gitDeployConfigSave');
    const configBackupSelect = el('gitDeployConfigBackup');
    const configLoadBackupsButton = el('gitDeployConfigLoadBackups');
    const configRestoreButton = el('gitDeployConfigRestore');
    const configMessageBox = el('gitDeployConfigMessage');
    const configSummary = el('gitDeployConfigSummary');


    let inventory = [];
    let busy = false;
    let configBusy = false;
    let configLoaded = false;
    let configExpectedSha256 = '';
    let restoreBusy = false;
    let commitHistoryBusy = false;
    let diffPreviewBusy = false;
    let approvedDiff = null;

    function escapeHtml(value) {
        return String(value ?? '')
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    function jsonPretty(value) {
        try {
            return JSON.stringify(value, null, 2);
        } catch (_) {
            return String(value ?? '');
        }
    }

    function showMessage(type, text) {
        messageBox.className = `alert alert-${type}`;
        messageBox.textContent = text;
        messageBox.classList.remove('d-none');
    }

    function clearMessage() {
        messageBox.classList.add('d-none');
        messageBox.textContent = '';
    }

    function showRestoreMessage(type, text) {
        restoreMessageBox.className = `alert alert-${type}`;
        restoreMessageBox.textContent = text;
        restoreMessageBox.classList.remove('d-none');
    }

    function clearRestoreMessage() {
        restoreMessageBox.classList.add('d-none');
        restoreMessageBox.textContent = '';
    }

    function showConfigMessage(type, text) {
        configMessageBox.className = `alert alert-${type}`;
        configMessageBox.textContent = text;
        configMessageBox.classList.remove('d-none');
    }

    function clearConfigMessage() {
        configMessageBox.classList.add('d-none');
        configMessageBox.textContent = '';
    }





    async function fetchJson(url, options = {}) {
        const response = await fetch(url, {
            cache: 'no-store',
            credentials: 'same-origin',
            ...options,
            headers: {
                'Accept': 'application/json',
                ...(options.headers || {}),
            },
        });
        let data;
        try {
            data = await response.json();
        } catch (_) {
            throw new Error(`Ungültige Portal-Antwort (HTTP ${response.status}).`);
        }
        if (!response.ok && !data) {
            throw new Error(`HTTP ${response.status}`);
        }
        return data;
    }

    async function fetchCommitStatusItem(idx, deployment, deployToken = '') {
        let data;
        if (deployToken) {
            data = await fetchJson(endpoint, {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken},
                body: JSON.stringify({action: 'status', csrf_token: csrfToken, server_idx: idx, deployment, deploy_token: deployToken}),
            });
        } else {
            data = await fetchJson(`${endpoint}?api=status&server_idx=${encodeURIComponent(idx)}&deployment=${encodeURIComponent(deployment)}`);
        }
        const envelope = data.response && typeof data.response === 'object' ? data.response : {};
        const persisted = envelope.status && typeof envelope.status === 'object' ? envelope.status : null;
        return {
            server_idx: idx,
            server_name: data.server_name || serverByIndex(idx)?.name || '',
            http_code: data.http_code || 0,
            ok: Boolean(data.ok && persisted?.ok),
            has_deploy_status: Boolean(persisted),
            response: {
                ...(persisted || {}),
                active_commit: envelope.active_commit || persisted?.active_commit || null,
                repository_commit: envelope.repository_commit || null,
                repository_comparison: envelope.comparison || '',
                repository_ref: envelope.allowed_ref || '',
                repository_error: envelope.repository_error || '',
                repository_error_stage: envelope.repository_error_stage || '',
                repository_token_required: Boolean(envelope.repository_token_required),
            },
        };
    }

    async function enrichResultsWithCommitStatus(items, deployment, deployToken = '') {
        return Promise.all(items.map(async (item) => {
            try {
                const commitStatus = await fetchCommitStatusItem(Number(item.server_idx), deployment, deployToken);
                return {
                    ...item,
                    response: {
                        ...(item.response || {}),
                        active_commit: commitStatus.response.active_commit || item.response?.active_commit || null,
                        repository_commit: commitStatus.response.repository_commit || null,
                        repository_comparison: commitStatus.response.repository_comparison || '',
                        repository_ref: commitStatus.response.repository_ref || '',
                        repository_error: commitStatus.response.repository_error || '',
                        repository_error_stage: commitStatus.response.repository_error_stage || '',
                        repository_token_required: Boolean(commitStatus.response.repository_token_required),
                    },
                };
            } catch (error) {
                return {
                    ...item,
                    response: {
                        ...(item.response || {}),
                        repository_commit: null,
                        repository_error: error.message || String(error),
                        repository_error_stage: 'portal_repository_status',
                    },
                };
            }
        }));
    }

    function selectedIndices() {
        return Array.from(serverList.querySelectorAll('input[data-server-index]:checked'))
            .map((node) => Number(node.dataset.serverIndex))
            .filter(Number.isInteger);
    }

    function serverByIndex(idx) {
        return inventory.find((server) => Number(server.idx) === Number(idx));
    }

    function profileById(server, id) {
        return Array.isArray(server?.profiles)
            ? server.profiles.find((profile) => String(profile.id) === String(id))
            : null;
    }

    function renderInventory() {
        const previousSelection = new Set(selectedIndices());
        serverList.innerHTML = '';

        inventory.forEach((server) => {
            const online = Boolean(server.online);
            const enabled = online && Boolean(server.git_enabled);
            const degraded = online && (Boolean(server.git_degraded) || server.config_valid === false);
            const profileCount = Array.isArray(server.profiles)
                ? server.profiles.filter((p) => p && p.enabled !== false).length
                : 0;

            const row = document.createElement('div');
            row.className = `git-deploy-server-row git-deploy-server${online ? '' : ' is-offline'}`;
            row.dataset.serverCard = String(server.idx);
            row.dataset.serverSearch = [server.name, server.url, server.version, online ? 'online' : 'offline',
                degraded ? 'degraded' : (enabled ? 'aktiv' : 'inaktiv'), server.requires_deploy_token ? 'request token' : 'lokal']
                .join(' ').toLocaleLowerCase('de-CH');
            row.setAttribute('role', 'option');
            row.innerHTML = `
                <span class="git-deploy-server-check">
                    <input class="form-check-input" type="checkbox"
                           data-server-index="${Number(server.idx)}"
                           id="gitDeployServer${Number(server.idx)}"
                           aria-label="${escapeHtml(server.name)} auswählen"
                           ${enabled && profileCount > 0 ? '' : 'disabled'}>
                </span>
                <span class="git-deploy-server-identity">
                    <label class="fw-semibold" for="gitDeployServer${Number(server.idx)}">${escapeHtml(server.name)}</label>
                    <small class="git-deploy-server-url text-body-secondary">${escapeHtml(server.url)}</small>
                    <small class="text-body-secondary">Agent ${escapeHtml(server.version || '?')} · Token ${server.requires_deploy_token ? 'pro Request' : 'lokal'}</small>
                    ${server.error ? `<small class="text-danger" title="${escapeHtml(server.error)}">${escapeHtml(server.error)}</small>` : ''}
                </span>
                <span><span class="badge ${online ? 'text-bg-success' : 'text-bg-danger'}">${online ? 'online' : 'offline'}</span></span>
                <span><span class="badge ${degraded ? 'text-bg-warning' : (enabled ? 'text-bg-primary' : 'text-bg-secondary')}">${degraded ? 'degraded' : (enabled ? 'aktiv' : 'inaktiv')}</span></span>
                <span class="text-nowrap">${profileCount}</span>`;
            serverList.appendChild(row);

            const checkbox = row.querySelector('input[data-server-index]');
            if (checkbox && !checkbox.disabled && previousSelection.has(Number(server.idx))) checkbox.checked = true;
        });

        const firstAvailable = serverList.querySelector('input[data-server-index]:not(:disabled)');
        if (firstAvailable && selectedIndices().length === 0) {
            firstAvailable.checked = true;
        }

        serverList.querySelectorAll('input[data-server-index]').forEach((input) => {
            input.addEventListener('change', () => {
                updateSelectedCards();
                rebuildProfiles();
            });
        });

        applyServerFilter();
        updateSelectedCards();
        rebuildProfiles();
        populateConfigServers();
        populateRestoreServers();
    }

    function selectedRestoreServerIndex() {
        const value = restoreServerSelect?.value || '';
        return /^\d+$/.test(value) ? Number(value) : null;
    }

    function restoreNeedsToken() {
        const idx = selectedRestoreServerIndex();
        return idx !== null && Boolean(serverByIndex(idx)?.requires_deploy_token);
    }

    function resetRestoreReleases() {
        restoreReleaseSelect.innerHTML = '<option value="">Zuerst Releases laden …</option>';
        restoreReleaseSelect.disabled = true;
        restoreConfirmInput.checked = false;
        restoreSummary.textContent = 'Noch keine Releases geladen.';
    }

    function populateRestoreServers() {
        if (!restoreServerSelect) return;
        const previous = restoreServerSelect.value;
        const servers = inventory.filter((server) => Boolean(server.online && server.git_enabled));
        restoreServerSelect.innerHTML = '';
        if (!servers.length) {
            restoreServerSelect.disabled = true;
            restoreServerSelect.append(new Option('Kein aktiver Git-Deploy-Agent', ''));
        } else {
            restoreServerSelect.disabled = false;
            servers.forEach((server) => restoreServerSelect.append(new Option(server.name, String(server.idx))));
            if (servers.some((server) => String(server.idx) === previous)) restoreServerSelect.value = previous;
        }
        populateRestoreProfiles();
    }

    function populateRestoreProfiles() {
        const idx = selectedRestoreServerIndex();
        const server = idx === null ? null : serverByIndex(idx);
        const profiles = Array.isArray(server?.profiles)
            ? server.profiles.filter((profile) => profile && profile.enabled !== false)
            : [];
        const previous = restoreProfileSelect.value;
        restoreProfileSelect.innerHTML = '';
        if (!profiles.length) {
            restoreProfileSelect.disabled = true;
            restoreProfileSelect.append(new Option('Kein aktives Profil', ''));
        } else {
            restoreProfileSelect.disabled = false;
            profiles.forEach((profile) => restoreProfileSelect.append(new Option(String(profile.id), String(profile.id))));
            if (profiles.some((profile) => String(profile.id) === previous)) restoreProfileSelect.value = previous;
        }
        const needsToken = restoreNeedsToken();
        restoreTokenWrap.classList.toggle('d-none', !needsToken);
        if (!needsToken) restoreTokenInput.value = '';
        resetRestoreReleases();
        updateRestoreButtons();
    }

    function restoreTokenIsValid() {
        if (!restoreNeedsToken()) return true;
        const token = restoreTokenInput.value;
        return token.length > 0 && token.length <= 4096 && !/[\x00-\x20\x7f]/.test(token);
    }

    function updateRestoreButtons() {
        const ready = selectedRestoreServerIndex() !== null && restoreProfileSelect.value !== '';
        restoreLoadButton.disabled = restoreBusy || !ready || !restoreTokenIsValid();
        restoreReleaseSelect.disabled = restoreBusy || restoreReleaseSelect.options.length <= 1;
        restoreStartButton.disabled = restoreBusy || !ready || restoreReleaseSelect.value === ''
            || !restoreConfirmInput.checked || !restoreTokenIsValid();
    }

    async function loadRestoreReleases(tokenOverride = null) {
        clearRestoreMessage();
        const idx = selectedRestoreServerIndex();
        const deployment = restoreProfileSelect.value;
        if (idx === null || !deployment) return;
        restoreBusy = true;
        restoreSummary.textContent = 'Release-Historie wird geladen …';
        updateRestoreButtons();
        try {
            const historyPayload = {
                action: 'release_history', csrf_token: csrfToken,
                server_idx: idx, deployment,
            };
            if (restoreNeedsToken()) {
                const token = tokenOverride === null ? restoreTokenInput.value : String(tokenOverride || '');
                historyPayload.deploy_token = token;
            }
            const data = await fetchJson(endpoint, {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken},
                body: JSON.stringify(historyPayload),
            });
            if (!data.ok || !data.releases || !Array.isArray(data.releases.releases)) {
                throw new Error(data.error || 'Release-Historie konnte nicht geladen werden.');
            }
            const activeCommit = String(data.releases.active_commit || '');
            const candidates = data.releases.releases.filter((item) => item && !item.active && item.commit);
            restoreReleaseSelect.innerHTML = '<option value="">Früheren Commit wählen …</option>';
            candidates.forEach((item) => {
                const commit = String(item.commit);
                const when = item.commit_date || item.recorded_at || '';
                const subject = item.subject ? ` · ${item.subject}` : '';
                const author = item.author ? ` · ${item.author}` : '';
                const source = item.deployed ? ' · früher deployt' : '';
                restoreReleaseSelect.append(new Option(`${commit.slice(0, 10)}${subject}${author}${when ? ` · ${when}` : ''}${source}`, commit));
            });
            restoreSummary.textContent = candidates.length
                ? `${candidates.length} frühere Commit(s) verfügbar. Aktiv: ${activeCommit ? activeCommit.slice(0, 10) : 'unbekannt'}`
                : `Kein früherer Commit verfügbar. Aktiv: ${activeCommit ? activeCommit.slice(0, 10) : 'unbekannt'}`;
            if (!candidates.length) showRestoreMessage('info', 'Für dieses Profil ist kein früherer Commit verfügbar.');
            if (data.releases.history_error) showRestoreMessage('warning', `Repository-Historie unvollständig: ${data.releases.history_error}`);
        } catch (error) {
            resetRestoreReleases();
            showRestoreMessage('danger', error.message || String(error));
        } finally {
            restoreBusy = false;
            updateRestoreButtons();
        }
    }

    async function startRestore() {
        clearRestoreMessage();
        updateRestoreButtons();
        if (restoreStartButton.disabled) return;
        const idx = selectedRestoreServerIndex();
        const deployment = restoreProfileSelect.value;
        const commitSha = restoreReleaseSelect.value;
        const server = serverByIndex(idx);
        const restoreDeployToken = restoreNeedsToken() ? restoreTokenInput.value : '';

        restoreBusy = true;
        updateRestoreButtons();
        try {
            const comparePayload = {action:'compare', csrf_token:csrfToken, server_idx:idx, deployment, commit_sha:commitSha};
            if (restoreDeployToken) comparePayload.deploy_token = restoreDeployToken;
            const compareData = await fetchJson(endpoint, {
                method:'POST', headers:{'Content-Type':'application/json','X-CSRF-Token':csrfToken}, body:JSON.stringify(comparePayload),
            });
            if (!compareData.ok || !compareData.compare) throw new Error(compareData.error || 'Restore-Vorschau konnte nicht erstellt werden.');
            const cmp = compareData.compare;
            const previewToken = String(cmp.preview_token || '');
            if (!/^[0-9a-f]{64}$/i.test(previewToken)) throw new Error('Agent lieferte kein gültiges Restore-Preview-Token.');
            const filesChanged = Number(cmp.files_changed || 0);
            const direction = String(cmp.direction || 'change');
            const question = `Älteren Commit ${commitSha.slice(0, 10)} für ${deployment} auf ${server?.name || 'dem Server'} installieren?\n\nDiff: ${filesChanged} Datei(en), Richtung: ${direction}.\nPersistente Preserve-Dateien bleiben auf ihrem aktuellen Stand.`;
            if (!window.confirm(question)) return;

            restoreConfirmInput.checked = false;
            setBusy(true, `Commit ${commitSha.slice(0, 10)} wird wiederhergestellt …`);
            const payload = {
                action: 'restore', csrf_token: csrfToken, server_indices: [idx],
                deployment, commit_sha: commitSha,
                diff_previews: {[String(idx)]: {token: previewToken, files_changed: filesChanged, direction}},
            };
            if (restoreDeployToken) payload.deploy_token = restoreDeployToken;
            const data = await fetchJson(endpoint, {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken},
                body: JSON.stringify(payload),
            });
            if (!Array.isArray(data.results)) throw new Error(data.error || 'Kein Restore-Ergebnis erhalten.');
            const enrichedResults = await enrichResultsWithCommitStatus(data.results, deployment, restoreDeployToken);
            renderResults(enrichedResults, data.ok ? 'Restore erfolgreich' : 'Restore fehlgeschlagen');
            showRestoreMessage(data.ok ? 'success' : 'danger', data.ok
                ? `Commit ${commitSha.slice(0, 10)} wurde erfolgreich wiederhergestellt.`
                : `Commit ${commitSha.slice(0, 10)} konnte nicht wiederhergestellt werden. Details unten prüfen.`);
            if (data.ok) await loadRestoreReleases(restoreDeployToken);
        } catch (error) {
            showRestoreMessage('danger', error.message || String(error));
        } finally {
            if (restoreDeployToken) restoreTokenInput.value = '';
            restoreBusy = false;
            setBusy(false);
            updateRestoreButtons();
        }
    }

    function updateSelectedCards() {
        serverList.querySelectorAll('[data-server-card]').forEach((card) => {
            const checkbox = card.querySelector('input[data-server-index]');
            card.classList.toggle('is-selected', Boolean(checkbox?.checked));
            card.setAttribute('aria-selected', checkbox?.checked ? 'true' : 'false');
        });
        updateServerSummary();
    }

    function applyServerFilter() {
        const query = String(serverSearch?.value || '').trim().toLocaleLowerCase('de-CH');
        let visible = 0;
        serverList.querySelectorAll('[data-server-card]').forEach((row) => {
            const show = query === '' || String(row.dataset.serverSearch || '').includes(query);
            row.classList.toggle('d-none', !show);
            if (show) visible += 1;
        });
        serverEmpty?.classList.toggle('d-none', visible !== 0);
        updateServerSummary();
    }

    function updateServerSummary() {
        if (!serverSummary) return;
        const available = serverList.querySelectorAll('input[data-server-index]:not(:disabled)').length;
        const selected = selectedIndices().length;
        const visible = Array.from(serverList.querySelectorAll('[data-server-card]'))
            .filter((row) => !row.classList.contains('d-none')).length;
        serverSummary.textContent = `${selected} ausgewählt · ${available} verfügbar · ${visible} angezeigt`;
        clearServersButton.disabled = selected === 0;
        selectVisibleButton.disabled = !serverList.querySelector('[data-server-card]:not(.d-none) input[data-server-index]:not(:disabled)');
    }

    function setVisibleServerSelection(checked) {
        serverList.querySelectorAll('[data-server-card]:not(.d-none) input[data-server-index]:not(:disabled)')
            .forEach((input) => { input.checked = checked; });
        updateSelectedCards();
        rebuildProfiles();
    }

    function commonProfiles(indices) {
        if (!indices.length) {
            return [];
        }

        const first = serverByIndex(indices[0]);
        const candidates = (first?.profiles || []).filter((p) => p && p.enabled !== false);

        return candidates.filter((profile) => indices.every((idx) => {
            const match = profileById(serverByIndex(idx), profile.id);
            return match && match.enabled !== false;
        })).sort((a, b) => String(a.id).localeCompare(String(b.id)));
    }

    function rebuildProfiles() {
        const previous = profileSelect.value;
        const indices = selectedIndices();
        const profiles = commonProfiles(indices);

        profileSelect.innerHTML = '';
        if (!indices.length) {
            profileSelect.disabled = true;
            profileSelect.innerHTML = '<option value="">Zuerst Zielserver auswählen …</option>';
        } else if (!profiles.length) {
            profileSelect.disabled = true;
            profileSelect.innerHTML = '<option value="">Kein gemeinsames aktives Profil</option>';
        } else {
            profileSelect.disabled = false;
            profileSelect.append(new Option('Profil wählen …', ''));
            profiles.forEach((profile) => profileSelect.append(new Option(String(profile.id), String(profile.id))));
            if (profiles.some((profile) => String(profile.id) === previous)) {
                profileSelect.value = previous;
            } else if (profiles.length === 1) {
                profileSelect.value = String(profiles[0].id);
            }
        }

        renderProfileDetails();
        updateTokenVisibility();
        resetDeployCommits();
        updateButtons();
    }

    function renderProfileDetails() {
        const profileId = profileSelect.value;
        const indices = selectedIndices();
        if (!profileId || !indices.length) {
            profileDetails.classList.add('d-none');
            profileDetails.innerHTML = '';
            return;
        }

        const cards = indices.map((idx) => {
            const server = serverByIndex(idx);
            const profile = profileById(server, profileId) || {};
            const preserved = Array.isArray(profile.preserve_paths) ? profile.preserve_paths : [];
            const preservedText = preserved.length
                ? preserved.map((item) => `${item.path} (${item.policy})`).join(', ')
                : 'keine';
            return `<article class="git-deploy-profile-card">
                <div class="git-deploy-profile-card-head">
                    <strong>${escapeHtml(server?.name || '')}</strong>
                    <span class="badge text-bg-light border">${profile.require_signed_commit ? 'Signatur Pflicht' : 'Signatur optional'}</span>
                </div>
                <dl class="git-deploy-profile-summary mb-0">
                    <div><dt>Repository</dt><dd><code>${escapeHtml(profile.git_url || '')}</code></dd></div>
                    <div><dt>Ref</dt><dd><code>${escapeHtml(profile.allowed_ref || '')}</code><small>${escapeHtml(profile.ref_policy || '')}</small></dd></div>
                    <div><dt>Zielpfad</dt><dd><code>${escapeHtml(profile.target_path || '')}</code></dd></div>
                    <div><dt>Deploy-Modus</dt><dd>${escapeHtml(profile.deploy_mode || 'symlink_release')}</dd></div>
                    <div><dt>Service</dt><dd>${escapeHtml(profile.restart_service || 'kein Restart')}</dd></div>
                    <div><dt>Healthcheck</dt><dd>${escapeHtml(profile.healthcheck_type || 'none')}</dd></div>
                </dl>
                <details class="git-deploy-profile-tech mt-2">
                    <summary>Technische Details</summary>
                    <div class="small text-body-secondary mt-2">Releases: <code>${escapeHtml(profile.releases_dir || '')}</code></div>
                    <div class="small text-body-secondary">State: <code>${escapeHtml(server?.state_dir || '')}</code></div>
                    <div class="small text-body-secondary">Persistente Pfade: ${escapeHtml(preservedText)}</div>
                </details>
            </article>`;
        }).join('');

        profileDetails.innerHTML = `<div class="git-deploy-profile-cards">${cards}</div>`;
        profileDetails.classList.remove('d-none');
    }

    function requestTokenRequired() {
        return selectedIndices().some((idx) => Boolean(serverByIndex(idx)?.requires_deploy_token));
    }

    function updateTokenVisibility() {
        const required = requestTokenRequired();
        tokenWrap.classList.toggle('d-none', !required);
        if (!required) {
            tokenInput.value = '';
            tokenInput.type = 'password';
            tokenToggle.innerHTML = '<i class="bi bi-eye"></i>';
        }
    }

    function tokenIsValid() {
        if (!requestTokenRequired()) return true;
        const value = tokenInput.value;
        return value.length > 0 && value.length <= 4096 && !/[\x00-\x20\x7f]/.test(value);
    }

    function resetDeployCommits() {
        if (!commitSelect) return;
        commitSelect.innerHTML = '';
        commitSelect.append(new Option('Aktueller Branch-Stand (automatisch)', 'auto'));
        commitSelect.value = 'auto';
        commitSummary.textContent = 'Aktueller Branch-Stand ausgewählt. Vor dem Deploy muss die Diff-Vorschau erfolgreich erstellt werden.';
        clearDiffPreview();
    }

    function clearDiffPreview() {
        approvedDiff = null;
        if (!diffPreview) return;
        diffPreview.innerHTML = '';
        diffPreview.classList.add('d-none');
    }

    function diffStatusLabel(status) {
        const code = String(status || '');
        if (code.startsWith('A')) return ['Neu', 'success'];
        if (code.startsWith('M')) return ['Geändert', 'primary'];
        if (code.startsWith('D')) return ['Gelöscht', 'danger'];
        if (code.startsWith('R')) return ['Umbenannt', 'warning'];
        if (code.startsWith('C')) return ['Kopiert', 'info'];
        return [code || 'Sonstiges', 'secondary'];
    }

    async function previewDeployDiff() {
        clearMessage();
        const indices = selectedIndices();
        const deployment = profileSelect.value;
        const commitSha = commitSelect?.value || 'auto';
        if (!indices.length || !deployment || !tokenIsValid()) return;
        diffPreviewBusy = true;
        clearDiffPreview();
        updateButtons();
        if (diffPreview) {
            diffPreview.classList.remove('d-none');
            diffPreview.innerHTML = '<div class="border rounded p-3 text-body-secondary"><span class="spinner-border spinner-border-sm me-2"></span>Diff wird für alle Zielserver berechnet …</div>';
        }
        try {
            const previews = {};
            const cards = [];
            const deployToken = requestTokenRequired() ? tokenInput.value : '';
            for (const idx of indices) {
                const payload = {action:'compare', csrf_token:csrfToken, server_idx:idx, deployment, commit_sha:commitSha};
                if (deployToken) payload.deploy_token = deployToken;
                const data = await fetchJson(endpoint, {
                    method:'POST', headers:{'Content-Type':'application/json','X-CSRF-Token':csrfToken}, body:JSON.stringify(payload),
                });
                if (!data.ok || !data.compare) throw new Error(`${serverByIndex(idx)?.name || `Server ${idx}`}: ${data.error || 'Diff-Vorschau fehlgeschlagen.'}`);
                const cmp = data.compare;
                const token = String(cmp.preview_token || '');
                if (!/^[0-9a-f]{64}$/i.test(token)) throw new Error(`${serverByIndex(idx)?.name || `Server ${idx}`}: ungültiges Preview-Token.`);
                previews[String(idx)] = {token, direction:String(cmp.direction || 'change'), files_changed:Number(cmp.files_changed || 0)};
                const files = Array.isArray(cmp.files) ? cmp.files : [];
                const directionLabels = {initial:'Erstinstallation', upgrade:'Update', downgrade:'Downgrade', same:'Identischer Stand', change:'Änderung'};
                const direction = directionLabels[cmp.direction] || 'Änderung';
                const rows = files.map((item) => {
                    const [label, badge] = diffStatusLabel(item.status);
                    const path = escapeHtml(item.path || '');
                    const oldPath = item.old_path ? `<div class="small text-body-secondary">von ${escapeHtml(item.old_path)}</div>` : '';
                    return `<tr><td><span class="badge text-bg-${badge}">${escapeHtml(label)}</span></td><td><code>${path}</code>${oldPath}</td></tr>`;
                }).join('');
                cards.push(`<div class="card border-primary-subtle mb-3">
                    <div class="card-header d-flex flex-wrap justify-content-between align-items-center gap-2">
                        <span class="fw-semibold"><i class="bi bi-file-diff me-1"></i>${escapeHtml(data.server_name || serverByIndex(idx)?.name || `Server ${idx}`)}</span>
                        <span class="badge ${cmp.direction === 'downgrade' ? 'text-bg-warning' : 'text-bg-primary'}">${escapeHtml(direction)}</span>
                    </div>
                    <div class="card-body">
                        <div class="row g-2 mb-3">
                            <div class="col-6 col-md-3"><div class="border rounded p-2"><div class="small text-body-secondary">Dateien</div><div class="fs-5 fw-semibold">${Number(cmp.files_changed || 0)}</div></div></div>
                            <div class="col-6 col-md-3"><div class="border rounded p-2"><div class="small text-body-secondary">Einfügungen</div><div class="fs-5 fw-semibold text-success">+${Number(cmp.insertions || 0)}</div></div></div>
                            <div class="col-6 col-md-3"><div class="border rounded p-2"><div class="small text-body-secondary">Löschungen</div><div class="fs-5 fw-semibold text-danger">-${Number(cmp.deletions || 0)}</div></div></div>
                            <div class="col-6 col-md-3"><div class="border rounded p-2"><div class="small text-body-secondary">Binärdateien</div><div class="fs-5 fw-semibold">${Number(cmp.binary_files || 0)}</div></div></div>
                        </div>
                        <div class="small text-body-secondary mb-2"><code>${escapeHtml(String(cmp.from_commit || 'nicht installiert').slice(0,10))}</code> → <code>${escapeHtml(String(cmp.to_commit || '').slice(0,10))}</code></div>
                        ${rows ? `<div class="table-responsive" style="max-height:320px"><table class="table table-sm align-middle mb-0"><thead class="sticky-top bg-body"><tr><th>Status</th><th>Datei</th></tr></thead><tbody>${rows}</tbody></table></div>` : '<div class="alert alert-success mb-0">Keine Dateiänderungen.</div>'}
                        ${cmp.direction === 'downgrade' ? '<div class="alert alert-warning mt-3 mb-0"><strong>Downgrade:</strong> Der Programmstand wird zurückgesetzt. Preserve-Dateien bleiben auf dem aktuellen Stand.</div>' : ''}
                        ${cmp.truncated ? '<div class="alert alert-warning mt-2 mb-0">Die Dateiliste wurde begrenzt.</div>' : ''}
                    </div>
                </div>`);
            }
            approvedDiff = {deployment, commitSha, servers:indices.join(','), previews};
            if (diffPreview) diffPreview.innerHTML = cards.join('');
        } catch (error) {
            approvedDiff = null;
            if (diffPreview) diffPreview.innerHTML = `<div class="alert alert-danger mb-0">${escapeHtml(error.message || String(error))}</div>`;
        } finally {
            diffPreviewBusy = false;
            updateButtons();
        }
    }

    function commitHistoryReferenceServer() {
        const indices = selectedIndices();
        return indices.length ? indices[0] : null;
    }

    async function loadDeployCommits() {
        clearMessage();
        const idx = commitHistoryReferenceServer();
        const deployment = profileSelect.value;
        if (idx === null || !deployment || !tokenIsValid()) return;

        commitHistoryBusy = true;
        updateButtons();
        commitSummary.textContent = 'Repository-Historie und Tags werden geladen …';
        try {
            const payload = {
                action: 'release_history',
                csrf_token: csrfToken,
                server_idx: idx,
                deployment,
            };
            if (requestTokenRequired()) payload.deploy_token = tokenInput.value;
            const data = await fetchJson(endpoint, {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken},
                body: JSON.stringify(payload),
            });
            const envelope = data.releases && typeof data.releases === 'object' ? data.releases : {};
            const releases = Array.isArray(envelope.releases) ? envelope.releases : [];
            resetDeployCommits();
            releases.forEach((item) => {
                const commit = normalizedCommit(item.commit || item.sha || item.commit_sha);
                if (!commit) return;
                const subject = String(item.subject || item.message || '').trim();
                const author = String(item.author || '').trim();
                const date = String(item.commit_date || item.date || item.committed_at || '').trim();
                const active = Boolean(item.active);
                const tags = Array.isArray(item.tags) ? item.tags.map((tag) => String(tag).trim()).filter(Boolean) : [];
                const tagLabel = tags.length ? `Tag: ${tags.join(', ')}` : '';
                const labels = [commit.slice(0, 10), tagLabel, subject, author, date, active ? 'aktiv' : ''].filter(Boolean);
                commitSelect.append(new Option(labels.join(' · '), commit));
            });
            commitSelect.disabled = false;
            const count = Math.max(0, commitSelect.options.length - 1);
            commitSummary.textContent = count
                ? `${count} freigegebene bzw. verfügbare Commits geladen. Tags werden direkt am Commit angezeigt. „Aktueller Ref-Stand“ bleibt die Standardauswahl.`
                : 'Keine zusätzlichen Commits gefunden; der aktuelle freigegebene Ref-Stand bleibt auswählbar.';
            if (envelope.history_error) showMessage('warning', `Commit-Historie nur teilweise geladen: ${envelope.history_error}`);
        } catch (error) {
            resetDeployCommits();
            commitSelect.disabled = false;
            commitSummary.textContent = 'Repository-Historie konnte nicht geladen werden; der automatische freigegebene Ref-Stand bleibt verfügbar.';
            showMessage('danger', error.message || String(error));
        } finally {
            commitHistoryBusy = false;
            updateButtons();
        }
    }

    function activateTab(name) {
        Object.entries(tabPanels).forEach(([key, panel]) => {
            if (panel) panel.classList.toggle('d-none', key !== name);
        });
        tabButtons.forEach((button) => {
            const active = button.dataset.gdTab === name;
            button.classList.toggle('is-active', active);
            button.setAttribute('aria-selected', active ? 'true' : 'false');
        });
    }

    function setWorkflowState(step, text, tone = 'primary') {
        workflowSteps.forEach((node, index) => {
            if (!node) return;
            const number = index + 1;
            node.classList.toggle('is-done', number < step);
            node.classList.toggle('is-active', number === step);
        });
        if (nextAction) {
            nextAction.className = `git-deploy-next-action mb-3 is-${tone}`;
            const span = nextAction.querySelector('span');
            if (span) span.textContent = text;
        }
    }

    function updateWorkflow(selectionReady, selectedCommit, diffApproved, tokenValid) {
        if (busy || commitHistoryBusy || diffPreviewBusy) {
            setWorkflowState(diffPreviewBusy ? 3 : 4, 'Vorgang läuft. Bitte warten …', 'info');
            return;
        }
        if (selectedIndices().length === 0) {
            setWorkflowState(1, 'Zuerst mindestens einen aktiven Zielserver auswählen.', 'primary');
            return;
        }
        if (!selectionReady || !selectedCommit || !tokenValid) {
            setWorkflowState(2, 'Profil und Version wählen. Falls erforderlich das Deploy-Token eingeben.', 'primary');
            return;
        }
        if (!diffApproved) {
            setWorkflowState(3, 'Als Nächstes die Änderungen prüfen. Ohne erfolgreiche Diff-Prüfung ist kein Deploy möglich.', 'warning');
            return;
        }
        if (!confirmInput.checked) {
            setWorkflowState(4, 'Diff geprüft. Deploy bestätigen, danach kann die Ausführung gestartet werden.', 'success');
            return;
        }
        setWorkflowState(4, 'Bereit zum Deploy. Die ausgewählte Version kann jetzt ausgerollt werden.', 'success');
    }

    function updateButtons() {
        const selectionReady = selectedIndices().length > 0 && profileSelect.value !== '';
        const selectedCommit = commitSelect ? commitSelect.value : 'auto';
        const diffApproved = approvedDiff && approvedDiff.deployment === profileSelect.value && approvedDiff.commitSha === selectedCommit && approvedDiff.servers === selectedIndices().join(',');
        const tokenValid = tokenIsValid();
        const blocked = busy || commitHistoryBusy || diffPreviewBusy || !selectionReady || !selectedCommit || !tokenValid || !confirmInput.checked || !diffApproved;
        updateWorkflow(selectionReady, selectedCommit, diffApproved, tokenValid);
        startButton.disabled = blocked;
        statusButton.disabled = busy || commitHistoryBusy || diffPreviewBusy || !selectionReady;
        if (commitLoadButton) commitLoadButton.disabled = busy || commitHistoryBusy || diffPreviewBusy || !selectionReady || !tokenValid;
        if (commitSelect) commitSelect.disabled = busy || commitHistoryBusy || diffPreviewBusy || !selectionReady;
        if (diffPreviewButton) diffPreviewButton.disabled = busy || commitHistoryBusy || diffPreviewBusy || !selectionReady || !tokenValid;

        if (blockReason) {
            let reason = '';
            if (busy || commitHistoryBusy || diffPreviewBusy) reason = 'Vorgang läuft …';
            else if (!selectionReady) reason = 'Deploy gesperrt: Zielserver und Deployment-Profil auswählen.';
            else if (!selectedCommit) reason = 'Deploy gesperrt: Commit/Release auswählen.';
            else if (!tokenValid) reason = 'Deploy gesperrt: gültiges Deploy-Token eingeben.';
            else if (!diffApproved) reason = 'Nächster Schritt: „Änderungen prüfen“. Bei Erstinstallation wird der komplette neue Stand geprüft.';
            else if (!confirmInput.checked) reason = 'Diff geprüft: Deploy jetzt bestätigen.';
            else reason = 'Bereit zum Deploy.';
            blockReason.textContent = reason;
            blockReason.className = `small ${blocked ? 'text-body-secondary' : 'text-success fw-semibold'}`;
            startButton.title = blocked ? reason : 'Deployment starten';
        }
    }

    function statusBadge(ok, httpCode, hasDeployStatus = true) {
        if (!hasDeployStatus) {
            return '<span class="badge text-bg-secondary">Noch nicht installiert</span>';
        }
        if (ok) {
            return '<span class="badge text-bg-success">Erfolgreich</span>';
        }
        if (Number(httpCode) === 404) {
            return '<span class="badge text-bg-secondary">Kein Status</span>';
        }
        return '<span class="badge text-bg-danger">Deploy fehlgeschlagen</span>';
    }

    function normalizedCommit(commit) {
        const value = String(commit || '').trim().toLowerCase();
        return /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(value) ? value : '';
    }

    function installedCommit(item, response) {
        const explicit = normalizedCommit(response.active_commit || response.status?.active_commit);
        if (explicit) return explicit;

        // Kompatibilität mit älteren erfolgreichen Agent-Antworten. Bei einem
        // Fehler darf response.commit niemals als installierter Stand gelten.
        return item.ok ? normalizedCommit(response.commit || response.status?.commit) : '';
    }

    function repositoryCommit(item, response) {
        const repository = normalizedCommit(response.repository_commit || response.status?.repository_commit);
        if (repository) return repository;
        if (response.repository_error || response.status?.repository_error) return '';

        // Kompatibilitaet fuer eine direkte Deploy-Antwort, falls der separate
        // Repository-Status eines aelteren Agents noch nicht verfuegbar ist.
        const explicit = normalizedCommit(response.requested_commit || response.status?.requested_commit);
        if (explicit) return explicit;

        const resolved = normalizedCommit(response.commit || response.status?.commit);
        if (resolved) return resolved;

        const portalRequest = normalizedCommit(item.requested_commit);
        if (portalRequest) return portalRequest;

        return '';
    }

    function commitCell(commit, unknownLabel) {
        const value = normalizedCommit(commit);
        if (!value) {
            return `<span class="text-body-secondary">${escapeHtml(unknownLabel)}</span>`;
        }
        return `<code class="git-deploy-commit" title="${escapeHtml(value)}">${escapeHtml(value.slice(0, 10))}</code>`;
    }

    function comparisonBadge(activeCommit, desiredCommit) {
        if (!activeCommit && desiredCommit) {
            return '<span class="badge text-bg-info">Erstinstallation</span>';
        }
        if (!activeCommit) {
            return '<span class="badge text-bg-secondary">Installiert unbekannt</span>';
        }
        if (!desiredCommit) {
            return '<span class="badge text-bg-secondary">Repository unbekannt</span>';
        }
        if (activeCommit === desiredCommit) {
            return '<span class="badge text-bg-success">Aktuell</span>';
        }
        return '<span class="badge text-bg-warning">Update verfügbar</span>';
    }

    function rollbackText(response) {
        const rollback = response && typeof response.rollback === 'object' ? response.rollback : null;
        if (!rollback) return '—';
        if (rollback.ok) return '<span class="badge text-bg-warning">Rollback erfolgreich</span>';
        if (rollback.attempted) return '<span class="badge text-bg-danger">Rollback fehlgeschlagen</span>';
        return '<span class="badge text-bg-secondary">Kein Rollback</span>';
    }

    function resultRow(item) {
        const response = item.response || {};
        const ok = Boolean(item.ok);
        const activeCommit = installedCommit(item, response);
        const desiredCommit = repositoryCommit(item, response);
        const action = response.action || response.status?.action || '';
        const stage = response.error_stage || response.status?.error_stage || '';
        const service = response.restart_service || response.restarted || response.status?.restart_service || '';
        const error = response.error || response.message || '';
        const repositoryError = response.repository_error || '';
        const repositoryRef = response.repository_ref || '';
        const detailPayload = item.response || item;

        return `<tr>
            <td><strong>${escapeHtml(item.server_name || '')}</strong><div class="small text-body-secondary">HTTP ${escapeHtml(item.http_code ?? 0)}</div></td>
            <td>${statusBadge(ok, item.http_code, item.has_deploy_status !== false)}</td>
            <td>${commitCell(activeCommit, 'unbekannt')}</td>
            <td>${commitCell(desiredCommit, 'nicht abrufbar')}${repositoryRef ? `<div class="small text-body-secondary">${escapeHtml(repositoryRef)}</div>` : ''}</td>
            <td>${comparisonBadge(activeCommit, desiredCommit)}</td>
            <td>${escapeHtml(action || '—')}<div class="small ${stage ? 'text-danger' : 'text-body-secondary'}">${escapeHtml(stage || '—')}</div></td>
            <td>${escapeHtml(service || '—')}<div class="mt-1">${rollbackText(response)}</div>${response.error_stage ? `<div class="small text-danger mt-1">Stufe: ${escapeHtml(response.error_stage)}</div>` : ''}</td>
            <td class="git-deploy-result-detail">
                ${error ? `<div class="text-danger small mb-1">${escapeHtml(error)}</div>` : ''}
                ${repositoryError ? `<div class="text-warning small mb-1">Repository: ${escapeHtml(repositoryError)}</div>` : ''}
                ${item.audit_error ? `<div class="text-warning small mb-1">Audit: ${escapeHtml(item.audit_error)}</div>` : ''}
                <details><summary>JSON</summary><pre>${escapeHtml(jsonPretty(detailPayload))}</pre></details>
            </td>
        </tr>`;
    }

    function renderResults(items, summary) {
        resultsBody.innerHTML = items.map(resultRow).join('');
        resultEmpty.classList.add('d-none');
        resultBusy.classList.add('d-none');
        resultsWrap.classList.remove('d-none');
        resultSummary.textContent = summary;
    }

    function setBusy(value, statusText = '') {
        busy = value;
        updateButtons();
        if (value) {
            resultEmpty.classList.add('d-none');
            resultsWrap.classList.add('d-none');
            resultBusy.classList.remove('d-none');
            resultSummary.textContent = statusText || 'Vorgang läuft …';
        } else {
            resultBusy.classList.add('d-none');
        }
    }

    function selectedConfigServerIndex() {
        const value = configServerSelect.value;
        return /^\d+$/.test(value) ? Number(value) : null;
    }

    function populateConfigServers() {
        if (!configServerSelect || !configEditor) return;
        const previousConfig = configServerSelect.value;
        const onlineServers = inventory.filter((server) => Boolean(server.online));
        configServerSelect.innerHTML = '';
        if (!onlineServers.length) {
            configServerSelect.disabled = true;
            configServerSelect.append(new Option('Kein erreichbarer Agent', ''));
        } else {
            configServerSelect.disabled = false;
            onlineServers.forEach((server) => {
                const suffix = server.version ? ` (Agent ${server.version})` : '';
                configServerSelect.append(new Option(`${server.name}${suffix}`, String(server.idx)));
            });
            if (onlineServers.some((server) => String(server.idx) === previousConfig)) configServerSelect.value = previousConfig;
        }
        configLoaded = false;
        configExpectedSha256 = '';
        configEditor.value = '';
        configEditor.disabled = true;
        configSummary.textContent = 'Noch keine Datei geladen';
        configBackupSelect.innerHTML = '<option value="">Keine Backups geladen</option>';
        updateConfigButtons();
    }

    function updateConfigButtons() {
        const hasServer = selectedConfigServerIndex() !== null;
        configLoadButton.disabled = configBusy || !hasServer;
        configLoadBackupsButton.disabled = configBusy || !hasServer;
        configEditor.disabled = configBusy || !configLoaded;
        configValidateButton.disabled = configBusy || !configLoaded || configEditor.value.trim() === '';
        configSaveButton.disabled = configBusy || !configLoaded || configEditor.value.trim() === '';
        configBackupSelect.disabled = configBusy || !hasServer || configBackupSelect.options.length <= 1;
        configRestoreButton.disabled = configBusy || !hasServer || configBackupSelect.value === '';
    }

    function setConfigBusy(value, text = '') {
        configBusy = value;
        if (text) configSummary.textContent = text;
        updateConfigButtons();
    }

    async function loadGitConfig() {
        clearConfigMessage();
        const idx = selectedConfigServerIndex();
        if (idx === null) return;
        setConfigBusy(true, 'Deployment-Profile werden geladen …');
        try {
            const data = await fetchJson(`${endpoint}?api=config_get&server_idx=${encodeURIComponent(idx)}`);
            if (!data.ok || !data.config) {
                throw new Error(data.error || 'git_deploy.json konnte nicht geladen werden.');
            }
            const cfgData = data.config;
            configEditor.value = String(cfgData.content || '');
            configExpectedSha256 = String(cfgData.sha256 || '').toLowerCase();
            configLoaded = true;
            const summary = cfgData.summary || {};
            configSummary.textContent = `${data.server_name}: ${cfgData.exists ? 'vorhanden' : 'noch nicht angelegt'}, Generation ${cfgData.generation || 0}, ${summary.profile_count || 0} Profile`;
            showConfigMessage('success', 'Deployment-Profile wurden geladen. Allgemeine Git-Einstellungen in global.json sind über das Portal nicht editierbar.');
            await loadGitConfigBackups(false);
        } catch (error) {
            configLoaded = false;
            configExpectedSha256 = '';
            configEditor.value = '';
            showConfigMessage('danger', error.message || String(error));
            configSummary.textContent = 'Laden fehlgeschlagen';
        } finally {
            setConfigBusy(false);
        }
    }

    async function validateGitConfig() {
        clearConfigMessage();
        const idx = selectedConfigServerIndex();
        if (idx === null || !configLoaded) return;
        setConfigBusy(true, 'Konfiguration wird validiert …');
        try {
            const data = await fetchJson(endpoint, {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken},
                body: JSON.stringify({
                    action: 'config_validate',
                    csrf_token: csrfToken,
                    server_idx: idx,
                    content: configEditor.value,
                    expected_sha256: configExpectedSha256,
                }),
            });
            if (!data.ok) throw new Error(data.error || 'Validierung fehlgeschlagen.');
            const summary = data.result?.summary || {};
            showConfigMessage('success', `Konfiguration gültig: ${summary.profile_count || 0} Profile, ${summary.preserve_path_count || 0} persistente Pfade, ${summary.allowed_root_count || 0} erlaubte Roots, ${summary.allowed_host_count || 0} Git-Hosts.`);
            configSummary.textContent = 'Validierung erfolgreich';
        } catch (error) {
            showConfigMessage('danger', error.message || String(error));
            configSummary.textContent = 'Validierung fehlgeschlagen';
        } finally {
            setConfigBusy(false);
        }
    }

    async function saveGitConfig() {
        clearConfigMessage();
        const idx = selectedConfigServerIndex();
        if (idx === null || !configLoaded) return;
        const server = serverByIndex(idx);
        if (!window.confirm(`git_deploy.json auf ${server?.name || 'dem Server'} speichern? Vorher wird automatisch ein Backup erstellt.`)) {
            return;
        }
        setConfigBusy(true, 'Konfiguration wird atomar gespeichert …');
        try {
            const data = await fetchJson(endpoint, {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken},
                body: JSON.stringify({
                    action: 'config_save',
                    csrf_token: csrfToken,
                    server_idx: idx,
                    content: configEditor.value,
                    expected_sha256: configExpectedSha256,
                }),
            });
            if (!data.ok) throw new Error(data.error || 'Speichern fehlgeschlagen.');
            const result = data.result || {};
            const backupText = result.backup ? ` Backup: ${result.backup}.` : ' Erstes Speichern ohne vorherigen Dateistand.';
            await loadInventory();
            configServerSelect.value = String(idx);
            await loadGitConfig();
            showConfigMessage(data.audit_error ? 'warning' : 'success', data.audit_error
                ? `Datei gespeichert; Audit-Warnung: ${data.audit_error}`
                : `git_deploy.json wurde gespeichert und sofort neu geladen.${backupText}`);
            configSummary.textContent = `${data.server_name}: gespeichert, Generation ${result.generation || 0}`;
        } catch (error) {
            showConfigMessage('danger', error.message || String(error));
            configSummary.textContent = 'Speichern fehlgeschlagen';
        } finally {
            setConfigBusy(false);
        }
    }

    async function loadGitConfigBackups(showSuccess = true) {
        const idx = selectedConfigServerIndex();
        if (idx === null) return;
        try {
            const data = await fetchJson(`${endpoint}?api=config_backups&server_idx=${encodeURIComponent(idx)}`);
            if (!data.ok || !Array.isArray(data.backups)) {
                throw new Error(data.error || 'Backups konnten nicht geladen werden.');
            }
            configBackupSelect.innerHTML = '<option value="">Backup wählen …</option>';
            data.backups.forEach((filename) => configBackupSelect.append(new Option(String(filename), String(filename))));
            if (showSuccess) showConfigMessage('success', `${data.backups.length} Backup(s) geladen.`);
        } catch (error) {
            configBackupSelect.innerHTML = '<option value="">Backups nicht verfügbar</option>';
            if (showSuccess) showConfigMessage('danger', error.message || String(error));
        } finally {
            updateConfigButtons();
        }
    }

    async function restoreGitConfig() {
        clearConfigMessage();
        const idx = selectedConfigServerIndex();
        const filename = configBackupSelect.value;
        if (idx === null || !filename) return;
        const server = serverByIndex(idx);
        if (!window.confirm(`${filename} auf ${server?.name || 'dem Server'} wiederherstellen? Der aktuelle Stand wird vorher erneut gesichert.`)) {
            return;
        }
        setConfigBusy(true, 'Backup wird wiederhergestellt …');
        try {
            const data = await fetchJson(endpoint, {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken},
                body: JSON.stringify({
                    action: 'config_restore',
                    csrf_token: csrfToken,
                    server_idx: idx,
                    filename,
                }),
            });
            if (!data.ok) throw new Error(data.error || 'Restore fehlgeschlagen.');
            await loadInventory();
            configServerSelect.value = String(idx);
            await loadGitConfig();
            showConfigMessage('success', `${filename} wurde wiederhergestellt und sofort aktiviert.`);
        } catch (error) {
            showConfigMessage('danger', error.message || String(error));
            configSummary.textContent = 'Restore fehlgeschlagen';
        } finally {
            setConfigBusy(false);
        }
    }


















    async function loadInventory() {
        clearMessage();
        inventoryBusy.classList.remove('d-none');
        serverPanel.classList.add('d-none');
        try {
            const data = await fetchJson(`${endpoint}?api=inventory`);
            if (!data.ok || !Array.isArray(data.servers)) {
                throw new Error(data.error || 'Inventar konnte nicht geladen werden.');
            }
            inventory = data.servers;
            renderInventory();
            serverPanel.classList.remove('d-none');
        } catch (error) {
            inventory = [];
            serverList.innerHTML = '';
            populateConfigServers();
            showMessage('danger', error.message || String(error));
        } finally {
            inventoryBusy.classList.add('d-none');
        }
    }

    async function startDeploy() {
        clearMessage();
        updateButtons();
        if (startButton.disabled) return;

        const indices = selectedIndices();
        const deployment = profileSelect.value;
        const commitSha = commitSelect?.value || 'auto';
        const needsToken = requestTokenRequired();
        const deployToken = needsToken ? tokenInput.value : '';
        const requestPayload = {
            action: 'deploy', csrf_token: csrfToken, server_indices: indices,
            deployment, commit_sha: commitSha,
            diff_previews: approvedDiff?.previews || {},
        };
        if (needsToken) requestPayload.deploy_token = deployToken;

        setBusy(true, `Deploy ${deployment} auf ${indices.length} Server(n) läuft …`);
        confirmInput.checked = false;
        try {
            const data = await fetchJson(endpoint, {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken},
                body: JSON.stringify(requestPayload),
            });
            if (!Array.isArray(data.results)) throw new Error(data.error || 'Keine Deployment-Ergebnisse erhalten.');
            const okCount = data.results.filter((item) => item.ok).length;
            const enrichedResults = await enrichResultsWithCommitStatus(data.results, deployment, deployToken);
            renderResults(enrichedResults, `${okCount}/${data.results.length} Server erfolgreich`);
            activateTab('history');
            if (data.ok) showMessage('success', `Deployment ${deployment} war auf allen ausgewählten Servern erfolgreich.`);
            else if (data.partial) showMessage('warning', `Deployment ${deployment} war nur teilweise erfolgreich. Details pro Server prüfen.`);
            else showMessage('danger', `Deployment ${deployment} ist auf allen ausgewählten Servern fehlgeschlagen.`);
        } catch (error) {
            showMessage('danger', error.message || String(error));
            resultSummary.textContent = 'Deploy fehlgeschlagen';
            resultEmpty.classList.remove('d-none');
        } finally {
            if (needsToken) tokenInput.value = '';
            clearDiffPreview();
            setBusy(false);
            updateButtons();
        }
    }

    async function loadStatus() {
        clearMessage();
        const indices = selectedIndices();
        const deployment = profileSelect.value;
        if (!indices.length || !deployment) return;
        if (!tokenIsValid()) {
            showMessage('warning', 'Für den Live-Repository-Status wird ein gültiges Deploy-Token benötigt.');
            return;
        }
        const deployToken = requestTokenRequired() ? tokenInput.value : '';
        setBusy(true, `Letzter Status für ${deployment} wird geladen …`);
        const items = [];
        try {
            for (const idx of indices) {
                try {
                    items.push(await fetchCommitStatusItem(idx, deployment, deployToken));
                } catch (error) {
                    items.push({
                        server_idx: idx, server_name: serverByIndex(idx)?.name || '', http_code: 0,
                        ok: false, has_deploy_status: false,
                        response: {ok:false, error:error.message || String(error), error_stage:'portal'},
                    });
                }
            }
            const repositoryCount = items.filter((item) => normalizedCommit(item.response?.repository_commit)).length;
            renderResults(items, `${repositoryCount}/${items.length} Repository-Stand/Staende geladen`);
            activateTab('history');
        } finally {
            setBusy(false);
            updateButtons();
        }
    }

    serverSearch.addEventListener('input', applyServerFilter);
    selectVisibleButton.addEventListener('click', () => setVisibleServerSelection(true));
    clearServersButton.addEventListener('click', () => {
        serverList.querySelectorAll('input[data-server-index]').forEach((input) => { input.checked = false; });
        updateSelectedCards();
        rebuildProfiles();
    });
    profileSelect.addEventListener('change', () => {
        renderProfileDetails();
        resetDeployCommits();
        updateButtons();
    });
    tokenInput.addEventListener('input', updateButtons);
    if (commitSelect) commitSelect.addEventListener('change', () => { clearDiffPreview(); updateButtons(); });
    if (commitLoadButton) commitLoadButton.addEventListener('click', loadDeployCommits);
    tabButtons.forEach((button) => {
        button.addEventListener('click', () => activateTab(button.dataset.gdTab || 'deploy'));
    });
    if (diffPreviewButton) diffPreviewButton.addEventListener('click', previewDeployDiff);
    confirmInput.addEventListener('change', updateButtons);
    startButton.addEventListener('click', startDeploy);
    statusButton.addEventListener('click', loadStatus);
    tokenToggle.addEventListener('click', () => {
        const show = tokenInput.type === 'password';
        tokenInput.type = show ? 'text' : 'password';
        tokenToggle.innerHTML = show ? '<i class="bi bi-eye-slash"></i>' : '<i class="bi bi-eye"></i>';
    });

    restoreServerSelect.addEventListener('change', () => {
        clearRestoreMessage();
        populateRestoreProfiles();
    });
    restoreProfileSelect.addEventListener('change', () => {
        clearRestoreMessage();
        resetRestoreReleases();
        updateRestoreButtons();
    });
    restoreReleaseSelect.addEventListener('change', updateRestoreButtons);
    restoreConfirmInput.addEventListener('change', updateRestoreButtons);
    restoreTokenInput.addEventListener('input', updateRestoreButtons);
    restoreLoadButton.addEventListener('click', loadRestoreReleases);
    restoreStartButton.addEventListener('click', startRestore);

    if (configServerSelect && configEditor && configBackupSelect && configLoadButton && configValidateButton && configSaveButton && configLoadBackupsButton && configRestoreButton) {
        configServerSelect.addEventListener('change', () => {
            configLoaded = false;
            configExpectedSha256 = '';
            configEditor.value = '';
            configSummary.textContent = 'Noch keine Datei geladen';
            configBackupSelect.innerHTML = '<option value="">Keine Backups geladen</option>';
            clearConfigMessage();
            updateConfigButtons();
        });
        configEditor.addEventListener('input', updateConfigButtons);
        configBackupSelect.addEventListener('change', updateConfigButtons);
        configLoadButton.addEventListener('click', loadGitConfig);
        configValidateButton.addEventListener('click', validateGitConfig);
        configSaveButton.addEventListener('click', saveGitConfig);
        configLoadBackupsButton.addEventListener('click', () => loadGitConfigBackups(true));
        configRestoreButton.addEventListener('click', restoreGitConfig);
    }

    loadInventory();
})();
