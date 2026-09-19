/* Config Manager Portal 3.0.22 - Git Repository Upload */
(() => {
    'use strict';

    const cfg = window.GIT_UPLOAD_PAGE || {};
    const byId = (id) => document.getElementById(id);
    const state = {
        info: null,
        repositories: [],
        repository: null,
        branches: [],
        stage: null,
        preview: null,
        busy: false,
    };

    const els = {
        message: byId('gitUploadMessage'),
        server: byId('gitUploadServer'),
        repository: byId('gitUploadRepository'),
        branch: byId('gitUploadBranch'),
        newBranch: byId('gitUploadNewBranch'),
        reload: byId('gitUploadReload'),
        createRepoToggle: byId('gitUploadCreateRepoToggle'),
        createRepoPanel: byId('gitUploadCreateRepoPanel'),
        createRepoClose: byId('gitUploadCreateRepoClose'),
        createOwner: byId('gitUploadCreateOwner'),
        createName: byId('gitUploadCreateName'),
        createDescription: byId('gitUploadCreateDescription'),
        createDefaultBranch: byId('gitUploadCreateDefaultBranch'),
        createPrivate: byId('gitUploadCreatePrivate'),
        createRepoButton: byId('gitUploadCreateRepo'),
        directory: byId('gitUploadDirectory'),
        zip: byId('gitUploadZip'),
        directoryWrap: byId('gitUploadDirectoryWrap'),
        zipWrap: byId('gitUploadZipWrap'),
        selectionInfo: byId('gitUploadSelectionInfo'),
        commitMessage: byId('gitUploadCommitMessage'),
        mode: byId('gitUploadMode'),
        stripTop: byId('gitUploadStripTop'),
        previewButton: byId('gitUploadPreview'),
        pushButton: byId('gitUploadPush'),
        discardButton: byId('gitUploadDiscard'),
        agentState: byId('gitUploadAgentState'),
        forgejoState: byId('gitUploadForgejoState'),
        agentLimit: byId('gitUploadAgentLimit'),
        progressWrap: byId('gitUploadProgressWrap'),
        progress: byId('gitUploadProgress'),
        previewSummary: byId('gitUploadPreviewSummary'),
        previewEmpty: byId('gitUploadPreviewEmpty'),
        warnings: byId('gitUploadWarnings'),
        changesWrap: byId('gitUploadChangesWrap'),
        changesBody: byId('gitUploadChangesBody'),
        result: byId('gitUploadResult'),
    };

    const escapeHtml = (value) => String(value ?? '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#039;');

    const formatBytes = (bytes) => {
        let value = Number(bytes || 0);
        const units = ['B', 'KiB', 'MiB', 'GiB'];
        let idx = 0;
        while (value >= 1024 && idx < units.length - 1) {
            value /= 1024;
            idx += 1;
        }
        return `${value.toFixed(idx === 0 ? 0 : 1)} ${units[idx]}`;
    };

    function showMessage(type, text) {
        els.message.className = `alert alert-${type}`;
        els.message.textContent = text;
        els.message.classList.remove('d-none');
    }

    function clearMessage() {
        els.message.classList.add('d-none');
        els.message.textContent = '';
    }

    function setBusy(busy, label = '') {
        state.busy = busy;
        els.server.disabled = busy;
        els.repository.disabled = busy || state.repositories.length === 0;
        els.branch.disabled = busy || !state.repository;
        els.reload.disabled = busy;
        if (els.createRepoToggle) els.createRepoToggle.disabled = busy || !state.info?.enabled || !state.info?.valid;
        if (els.createRepoButton) els.createRepoButton.disabled = busy;
        els.directory.disabled = busy;
        els.zip.disabled = busy;
        els.previewButton.disabled = busy || !canPreview();
        els.pushButton.disabled = busy || !state.preview || !state.preview.has_changes;
        els.discardButton.disabled = busy || !state.stage;
        if (busy && label) {
            els.result.textContent = label;
        }
    }

    function apiUrl(action, params = {}) {
        const url = new URL(cfg.endpoint, window.location.href);
        url.searchParams.set('api', action);
        Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, String(value)));
        return url.toString();
    }

    async function jsonRequest(action, payload = null, params = {}) {
        const options = {
            method: payload === null ? 'GET' : 'POST',
            headers: {
                'Accept': 'application/json',
                'X-CSRF-Token': cfg.csrfToken || '',
            },
            credentials: 'same-origin',
            cache: 'no-store',
        };
        if (payload !== null) {
            options.headers['Content-Type'] = 'application/json';
            if (payload && typeof payload.upload_id === 'string' && payload.upload_id !== '') {
                options.headers['X-TEKO-Upload-ID'] = payload.upload_id;
            }
            options.body = JSON.stringify(payload);
        }
        const response = await fetch(apiUrl(action, params), options);
        const data = await response.json().catch(() => ({ok: false, error: `Ungültige Serverantwort (${response.status})`}));
        if (!response.ok || data.ok === false) {
            throw new Error(data.error || `HTTP ${response.status}`);
        }
        return data;
    }

    function uploadType() {
        return document.querySelector('input[name="gitUploadType"]:checked')?.value || 'directory';
    }

    function selectedFiles() {
        return uploadType() === 'zip'
            ? Array.from(els.zip.files || [])
            : Array.from(els.directory.files || []);
    }

    function selectedPaths(files) {
        if (uploadType() === 'zip') {
            return files.map((file) => file.name);
        }
        return files.map((file) => file.webkitRelativePath || file.name);
    }

    function selectedBranch() {
        if (els.branch.value === '__new__') {
            return els.newBranch.value.trim();
        }
        return els.branch.value.trim();
    }

    function baseBranch() {
        return state.repository?.default_branch || '';
    }

    function canPreview() {
        const files = selectedFiles();
        return Boolean(
            state.info?.enabled && state.info?.valid &&
            state.repository && selectedBranch() && files.length > 0
        );
    }

    function invalidatePreview(discardStage = false) {
        state.preview = null;
        els.pushButton.disabled = true;
        els.previewSummary.textContent = 'Noch keine Vorschau';
        els.previewEmpty.classList.remove('d-none');
        els.changesWrap.classList.add('d-none');
        els.warnings.classList.add('d-none');
        els.changesBody.innerHTML = '';
        if (discardStage && state.stage) {
            const old = state.stage.stage_id;
            state.stage = null;
            els.discardButton.disabled = true;
            jsonRequest('discard', {server_idx: Number(els.server.value), stage_id: old}).catch(() => {});
        }
        setBusy(false);
    }

    function updateSelectionInfo() {
        const files = selectedFiles();
        const bytes = files.reduce((sum, file) => sum + Number(file.size || 0), 0);
        if (files.length === 0) {
            els.selectionInfo.textContent = uploadType() === 'zip'
                ? 'Noch kein ZIP ausgewählt.'
                : 'Noch kein Verzeichnis ausgewählt.';
        } else {
            els.selectionInfo.textContent = `${files.length} Datei(en), ${formatBytes(bytes)}`;
        }
        invalidatePreview(true);
    }

    function renderInfo() {
        if (!state.info) {
            els.agentState.textContent = 'nicht verfügbar';
            els.forgejoState.textContent = '–';
            els.agentLimit.textContent = '–';
            return;
        }
        const ready = state.info.enabled && state.info.valid && !state.info.degraded;
        els.agentState.textContent = ready ? 'bereit' : 'degraded';
        els.agentState.className = ready ? 'text-success' : 'text-danger';
        els.forgejoState.textContent = state.info.base_url || '–';
        els.agentLimit.textContent = `${formatBytes(state.info.max_upload_bytes)} / ${state.info.max_files} Dateien`;
        if (els.createOwner) { const owners = Array.isArray(state.info.allowed_owners) ? state.info.allowed_owners : []; if (owners.length === 1) els.createOwner.value = owners[0]; }
        const mirrorOption = Array.from(els.mode.options).find((option) => option.value === 'mirror');
        if (mirrorOption) {
            mirrorOption.disabled = !state.info.allow_mirror;
            if (!state.info.allow_mirror && els.mode.value === 'mirror') {
                els.mode.value = 'update';
            }
        }
        if (!ready && state.info.error) {
            showMessage('danger', state.info.error);
        }
    }

    function renderRepositories() {
        els.repository.innerHTML = '<option value="">Repository auswählen …</option>';
        state.repositories.forEach((repo) => {
            const option = document.createElement('option');
            option.value = repo.full_name;
            option.textContent = `${repo.full_name}${repo.private ? ' (privat)' : ''}`;
            els.repository.appendChild(option);
        });
        els.repository.disabled = state.repositories.length === 0;
        state.repository = null;
        renderBranches();
    }

    function renderBranches() {
        els.branch.innerHTML = '<option value="">Branch auswählen …</option>';
        if (state.repository) {
            state.branches.forEach((branch) => {
                const option = document.createElement('option');
                option.value = branch.name;
                option.textContent = branch.name + (branch.name === state.repository.default_branch ? ' (Default)' : '');
                els.branch.appendChild(option);
            });
            const newOption = document.createElement('option');
            newOption.value = '__new__';
            newOption.textContent = '+ neuen Upload-Branch anlegen';
            els.branch.appendChild(newOption);
            if (state.repository.default_branch && state.branches.some((b) => b.name === state.repository.default_branch)) {
                els.branch.value = state.repository.default_branch;
            }
        }
        els.branch.disabled = !state.repository;
        if (state.repository && state.branches.length === 0) {
            els.branch.value = '__new__';
            els.newBranch.classList.remove('d-none');
            els.newBranch.value = state.repository.default_branch || 'main';
        } else {
            els.newBranch.classList.add('d-none');
            els.newBranch.value = '';
        }
        invalidatePreview(false);
    }

    async function loadServer(force = false) {
        clearMessage();
        state.info = null;
        state.repositories = [];
        state.repository = null;
        state.branches = [];
        invalidatePreview(true);
        setBusy(true, 'Config Agent und Forgejo werden geprüft …');
        try {
            const serverIdx = Number(els.server.value);
            const [infoData, repoData] = await Promise.all([
                jsonRequest('info', null, {server_idx: serverIdx}),
                jsonRequest('repositories', null, {server_idx: serverIdx, refresh: force ? 1 : 0}),
            ]);
            state.info = infoData.info || {};
            state.repositories = Array.isArray(repoData.repositories) ? repoData.repositories : [];
            renderInfo();
            renderRepositories();
            els.result.textContent = `${state.repositories.length} beschreibbare Repository(s) geladen.`;
        } catch (error) {
            showMessage('danger', error.message);
            els.result.textContent = error.message;
            renderInfo();
            renderRepositories();
        } finally {
            setBusy(false);
        }
    }

    function toggleCreateRepository(show) {
        if (!els.createRepoPanel) return;
        els.createRepoPanel.classList.toggle('d-none', !show);
        if (show) { clearMessage(); els.createName?.focus(); }
    }

    async function createRepository() {
        clearMessage();
        const owner = (els.createOwner?.value || '').trim();
        const name = (els.createName?.value || '').trim();
        const description = (els.createDescription?.value || '').trim();
        const defaultBranch = (els.createDefaultBranch?.value || 'main').trim();
        const nameOk = /^[A-Za-z0-9_.-]{1,128}$/.test(name);
        const ownerOk = /^[A-Za-z0-9_.-]{1,128}$/.test(owner);
        const branchOk = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/.test(defaultBranch) && !defaultBranch.includes('..') && !defaultBranch.includes('//');
        if (!ownerOk) { showMessage('warning', 'Organisation ist ungültig.'); els.createOwner?.focus(); return; }
        if (!nameOk) { showMessage('warning', 'Repository-Name ist ungültig.'); els.createName?.focus(); return; }
        if (!branchOk) { showMessage('warning', 'Default-Branch ist ungültig.'); els.createDefaultBranch?.focus(); return; }
        setBusy(true, 'Forgejo-Repository wird erstellt …');
        try {
            const data = await jsonRequest('create_repository', {server_idx:Number(els.server.value), owner, name, description, default_branch:defaultBranch, private:Boolean(els.createPrivate?.checked)});
            const created = data.repository || {};
            await loadServer(true);
            if (created.full_name) {
                els.repository.value = created.full_name;
                await loadBranches();
                if (!state.branches.length) { els.branch.value='__new__'; els.newBranch.classList.remove('d-none'); els.newBranch.value=defaultBranch; }
            }
            toggleCreateRepository(false);
            if (els.createName) els.createName.value='';
            if (els.createDescription) els.createDescription.value='';
            showMessage('success', `Repository ${created.full_name || `${owner}/${name}`} wurde erstellt und ausgewählt.`);
            els.result.textContent = JSON.stringify(data, null, 2);
        } catch (error) { showMessage('danger', error.message); els.result.textContent=error.message; }
        finally { setBusy(false); }
    }

    async function loadBranches() {
        const fullName = els.repository.value;
        state.repository = state.repositories.find((repo) => repo.full_name === fullName) || null;
        state.branches = [];
        renderBranches();
        if (!state.repository) {
            return;
        }
        setBusy(true, 'Branches werden geladen …');
        try {
            const data = await jsonRequest('branches', null, {
                server_idx: Number(els.server.value),
                owner: state.repository.owner,
                repository: state.repository.name,
            });
            state.repository = data.repository || state.repository;
            state.branches = Array.isArray(data.branches) ? data.branches : [];
            renderBranches();
            els.result.textContent = `${state.branches.length} Branch(es) geladen.`;
        } catch (error) {
            showMessage('danger', error.message);
            els.result.textContent = error.message;
        } finally {
            setBusy(false);
        }
    }

    function validateClientSelection() {
        if (!state.repository) {
            throw new Error('Repository auswählen.');
        }
        const branch = selectedBranch();
        if (!branch) {
            throw new Error('Branch auswählen oder neuen Branch eingeben.');
        }
        if (!/^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/.test(branch) || branch.includes('..') || branch.includes('//')) {
            throw new Error('Branchname ist ungültig.');
        }
        const files = selectedFiles();
        if (files.length === 0) {
            throw new Error('Verzeichnis oder ZIP auswählen.');
        }
        if (uploadType() === 'zip' && files.length !== 1) {
            throw new Error('Für ZIP genau eine Datei auswählen.');
        }
        if (state.info?.max_files && files.length > Number(state.info.max_files)) {
            throw new Error(`Zu viele Dateien. Agent-Maximum: ${state.info.max_files}.`);
        }
        const bytes = files.reduce((sum, file) => sum + Number(file.size || 0), 0);
        if (state.info?.max_upload_bytes && bytes > Number(state.info.max_upload_bytes)) {
            throw new Error(`Upload zu gross. Agent-Maximum: ${formatBytes(state.info.max_upload_bytes)}.`);
        }
        return {files, bytes, branch};
    }

    function setUploadProgress(percent) {
        const value = Math.max(0, Math.min(100, Math.round(Number(percent) || 0)));
        els.progressWrap.classList.remove('d-none');
        els.progress.style.width = `${value}%`;
        els.progress.textContent = `${value}%`;
        els.progressWrap.setAttribute('aria-valuenow', String(value));
    }

    function multipartRequest(action, form, progressCallback = null, control = {}) {
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('POST', apiUrl(action), true);
            xhr.setRequestHeader('X-CSRF-Token', cfg.csrfToken || '');
            xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
            const localUploadId = String(control.uploadId || form.get('upload_id') || '');
            if (localUploadId !== '') {
                xhr.setRequestHeader('X-TEKO-Upload-ID', localUploadId);
            }
            if (Number.isInteger(control.chunkIndex) && control.chunkIndex >= 0) {
                xhr.setRequestHeader('X-TEKO-Chunk-Index', String(control.chunkIndex));
            }
            if (typeof control.chunkToken === 'string' && /^[0-9a-f]{32}$/.test(control.chunkToken)) {
                xhr.setRequestHeader('X-TEKO-Chunk-Token', control.chunkToken);
            }
            xhr.responseType = 'json';
            xhr.upload.onprogress = (event) => {
                if (event.lengthComputable && typeof progressCallback === 'function') {
                    progressCallback(event.loaded, event.total);
                }
            };
            xhr.onload = () => {
                const data = xhr.response || {};
                if (xhr.status < 200 || xhr.status >= 300 || data.ok === false) {
                    reject(new Error(data.error || `Upload HTTP ${xhr.status}`));
                    return;
                }
                resolve(data);
            };
            xhr.onerror = () => reject(new Error('Netzwerkfehler beim Upload.'));
            xhr.onabort = () => reject(new Error('Upload wurde abgebrochen.'));
            xhr.send(form);
        });
    }

    function binaryRequest(action, file, progressCallback = null, control = {}) {
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('POST', apiUrl(action), true);
            xhr.setRequestHeader('X-CSRF-Token', cfg.csrfToken || '');
            xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
            xhr.setRequestHeader('Content-Type', 'application/octet-stream');
            if (typeof control.uploadId === 'string' && /^[0-9a-f]{32}$/.test(control.uploadId)) {
                xhr.setRequestHeader('X-TEKO-Upload-ID', control.uploadId);
            }
            if (Number.isInteger(control.chunkIndex) && control.chunkIndex >= 0) {
                xhr.setRequestHeader('X-TEKO-Chunk-Index', String(control.chunkIndex));
            }
            if (typeof control.chunkToken === 'string' && /^[0-9a-f]{32}$/.test(control.chunkToken)) {
                xhr.setRequestHeader('X-TEKO-Chunk-Token', control.chunkToken);
            }
            if (Number.isInteger(control.fileIndex) && control.fileIndex >= 0) {
                xhr.setRequestHeader('X-TEKO-File-Index', String(control.fileIndex));
            }
            xhr.responseType = 'json';
            xhr.upload.onprogress = (event) => {
                if (event.lengthComputable && typeof progressCallback === 'function') {
                    progressCallback(event.loaded, event.total);
                }
            };
            xhr.onload = () => {
                const data = xhr.response || {};
                if (xhr.status < 200 || xhr.status >= 300 || data.ok === false) {
                    reject(new Error(data.error || `Upload HTTP ${xhr.status}`));
                    return;
                }
                resolve(data);
            };
            xhr.onerror = () => reject(new Error('Netzwerkfehler beim Upload.'));
            xhr.onabort = () => reject(new Error('Upload wurde abgebrochen.'));
            xhr.send(file);
        });
    }

    function stageSingleRequest(files) {
        const form = new FormData();
        form.append('csrf_token', cfg.csrfToken || '');
        form.append('server_idx', String(Number(els.server.value)));
        form.append('upload_type', uploadType());
        form.append('strip_top_level', els.stripTop.checked ? '1' : '0');
        form.append('expected_count', String(files.length));
        form.append('relative_paths', JSON.stringify(selectedPaths(files)));
        files.forEach((file) => form.append('files[]', file, file.name));
        return multipartRequest('stage', form, (loaded, total) => {
            setUploadProgress(total > 0 ? (loaded / total) * 100 : 0);
        });
    }

    async function stageDirectoryChunked(files, totalBytes) {
        const paths = selectedPaths(files);
        const chunkSize = Math.max(1, Math.min(Number(cfg.directoryChunkFiles || 10), 20));
        let uploadId = '';
        try {
            const begin = await jsonRequest('local_stage_begin', {
                server_idx: Number(els.server.value),
                expected_count: files.length,
                total_bytes: totalBytes,
            });
            uploadId = String(begin.upload_id || '');
            if (!/^[0-9a-f]{32}$/.test(uploadId)) {
                throw new Error('Lokales Upload-Staging konnte nicht initialisiert werden.');
            }

            let completedBytes = 0;
            for (let offset = 0, chunkIndex = 0; offset < files.length; offset += chunkSize, chunkIndex += 1) {
                const chunkFiles = files.slice(offset, offset + chunkSize);
                const chunkPaths = paths.slice(offset, offset + chunkSize);
                const chunkBytes = chunkFiles.reduce((sum, file) => sum + Number(file.size || 0), 0);
                const prepared = await jsonRequest('local_stage_chunk_prepare', {
                    upload_id: uploadId,
                    chunk_index: chunkIndex,
                    files: chunkFiles.map((file, i) => ({
                        relative_path: chunkPaths[i],
                        name: file.name,
                        size: Number(file.size || 0),
                    })),
                });
                const chunkToken = String(prepared.chunk_token || '');
                if (!/^[0-9a-f]{32}$/.test(chunkToken) || Number(prepared.chunk_index) !== chunkIndex) {
                    throw new Error(`Upload-Chunk ${chunkIndex} konnte nicht vorbereitet werden.`);
                }
                let completedChunkBytes = 0;
                for (let fileIndex = 0; fileIndex < chunkFiles.length; fileIndex += 1) {
                    const file = chunkFiles[fileIndex];
                    const fileBytes = Number(file.size || 0);
                    const uploaded = await binaryRequest('local_stage_file', file, (loaded, requestTotal) => {
                        const logicalLoaded = requestTotal > 0 ? (loaded / requestTotal) * fileBytes : 0;
                        const denominator = totalBytes > 0 ? totalBytes : files.length;
                        const numerator = totalBytes > 0
                            ? completedBytes + completedChunkBytes + logicalLoaded
                            : Math.min(files.length, offset + fileIndex + (loaded >= requestTotal ? 1 : 0));
                        setUploadProgress((numerator / denominator) * 92);
                    }, {
                        uploadId,
                        chunkIndex,
                        chunkToken,
                        fileIndex,
                    });
                    if (Number(uploaded.file_index) !== fileIndex) {
                        throw new Error(`Upload-Datei ${fileIndex + 1} im Chunk ${chunkIndex} wurde serverseitig nicht bestätigt.`);
                    }
                    completedChunkBytes += fileBytes;
                }
                completedBytes += chunkBytes;
                const fileProgress = totalBytes > 0
                    ? (completedBytes / totalBytes) * 92
                    : ((offset + chunkFiles.length) / files.length) * 92;
                setUploadProgress(fileProgress);
            }

            setUploadProgress(94);
            const staged = await jsonRequest('local_stage_finalize', {
                upload_id: uploadId,
                strip_top_level: Boolean(els.stripTop.checked),
            });
            setUploadProgress(100);
            uploadId = '';
            return staged;
        } catch (error) {
            if (uploadId) {
                await jsonRequest('local_stage_abort', {upload_id: uploadId}).catch(() => {});
            }
            throw error;
        }
    }

    function stageUpload(files, bytes) {
        return uploadType() === 'directory'
            ? stageDirectoryChunked(files, bytes)
            : stageSingleRequest(files);
    }

    function renderWarnings(warnings = [], ignored = []) {
        const items = [];
        warnings.forEach((warning) => items.push(`<li class="text-warning-emphasis">${escapeHtml(warning)}</li>`));
        ignored.slice(0, 100).forEach((entry) => items.push(`<li class="text-body-secondary">Ignoriert: ${escapeHtml(entry)}</li>`));
        if (ignored.length > 100) {
            items.push(`<li class="text-body-secondary">… weitere ${ignored.length - 100} ignorierte Einträge</li>`);
        }
        if (items.length === 0) {
            els.warnings.classList.add('d-none');
            els.warnings.innerHTML = '';
            return;
        }
        els.warnings.classList.remove('d-none');
        els.warnings.innerHTML = `<div class="alert alert-warning mb-0"><strong>Hinweise vor dem Commit</strong><ul class="mb-0 mt-2">${items.join('')}</ul></div>`;
    }

    function statusLabel(status) {
        const key = String(status || '').charAt(0);
        return {
            A: ['Neu', 'success'],
            M: ['Geändert', 'primary'],
            D: ['Gelöscht', 'danger'],
            R: ['Umbenannt', 'warning'],
            C: ['Kopiert', 'info'],
            T: ['Typ geändert', 'warning'],
        }[key] || [status || 'Andere', 'secondary'];
    }

    function renderPreview(data) {
        state.preview = data;
        const changes = Array.isArray(data.changes) ? data.changes : [];
        const counts = data.counts || {};
        els.previewSummary.textContent = `${changes.length} Änderung(en): ${counts.added || 0} neu, ${counts.modified || 0} geändert, ${counts.deleted || 0} gelöscht`;
        els.previewEmpty.classList.toggle('d-none', changes.length > 0);
        els.changesWrap.classList.toggle('d-none', changes.length === 0);
        els.changesBody.innerHTML = changes.map((change) => {
            const [label, color] = statusLabel(change.status);
            return `<tr>
                <td><span class="badge text-bg-${color}">${escapeHtml(label)}</span></td>
                <td><code>${escapeHtml(change.path)}</code></td>
                <td>${change.old_path ? `<code>${escapeHtml(change.old_path)}</code>` : '<span class="text-body-secondary">–</span>'}</td>
            </tr>`;
        }).join('');
        renderWarnings(data.warnings || [], data.ignored || []);
        els.pushButton.disabled = !data.has_changes;
        els.discardButton.disabled = !state.stage;
        els.result.textContent = JSON.stringify({
            repository: data.repository,
            branch: data.branch,
            branch_exists: data.branch_exists,
            remote_head: data.remote_head,
            mode: data.mode,
            files: data.file_count,
            bytes: data.bytes,
            counts: data.counts,
        }, null, 2);
    }

    async function preview() {
        clearMessage();
        let selection;
        try {
            selection = validateClientSelection();
        } catch (error) {
            showMessage('warning', error.message);
            return;
        }
        setBusy(true, 'Dateien werden zum Config Agent übertragen …');
        els.progressWrap.classList.remove('d-none');
        els.progress.style.width = '0%';
        els.progress.textContent = '0%';
        try {
            if (state.stage) {
                await jsonRequest('discard', {server_idx: Number(els.server.value), stage_id: state.stage.stage_id}).catch(() => {});
                state.stage = null;
            }
            const staged = await stageUpload(selection.files, selection.bytes);
            state.stage = staged.stage;
            els.progress.style.width = '100%';
            els.progress.textContent = '100%';
            els.result.textContent = 'Git-Vorschau wird erzeugt …';
            const data = await jsonRequest('preview', {
                server_idx: Number(els.server.value),
                stage_id: state.stage.stage_id,
                owner: state.repository.owner,
                repository: state.repository.name,
                branch: selection.branch,
                base_branch: selection.branch === els.branch.value ? '' : baseBranch(),
                mode: els.mode.value,
            });
            renderPreview(data);
            showMessage(data.has_changes ? 'success' : 'info', data.has_changes ? 'Vorschau erfolgreich. Änderungen können jetzt committed und gepusht werden.' : 'Keine Änderungen gegenüber dem Repository erkannt.');
        } catch (error) {
            state.preview = null;
            showMessage('danger', error.message);
            els.result.textContent = error.message;
        } finally {
            setBusy(false);
            window.setTimeout(() => els.progressWrap.classList.add('d-none'), 1200);
        }
    }

    async function push() {
        if (!state.stage || !state.preview) {
            showMessage('warning', 'Zuerst eine aktuelle Vorschau erzeugen.');
            return;
        }
        const message = els.commitMessage.value.trim();
        if (!message) {
            showMessage('warning', 'Commit-Nachricht eingeben.');
            els.commitMessage.focus();
            return;
        }
        const isDefault = state.preview.branch === state.preview.default_branch;
        const isMirror = state.preview.mode === 'mirror';
        const warning = [
            `Repository: ${state.preview.repository}`,
            `Branch: ${state.preview.branch}`,
            `Änderungen: ${(state.preview.changes || []).length}`,
            isDefault ? 'Achtung: direkter Push auf den Default-Branch.' : '',
            isMirror ? 'Achtung: Spiegelmodus löscht nicht mehr vorhandene Repository-Dateien.' : '',
            '',
            'Commit und Push jetzt ausführen?',
        ].filter(Boolean).join('\n');
        if (!window.confirm(warning)) {
            return;
        }
        setBusy(true, 'Commit und Push laufen …');
        clearMessage();
        try {
            const data = await jsonRequest('push', {
                server_idx: Number(els.server.value),
                stage_id: state.stage.stage_id,
                stage_digest: state.preview.stage_digest,
                owner: state.repository.owner,
                repository: state.repository.name,
                branch: state.preview.branch,
                base_branch: state.preview.base_branch || '',
                mode: state.preview.mode,
                expected_remote_head: state.preview.remote_head || '',
                expected_base_head: state.preview.base_head || '',
                expected_branch_exists: Boolean(state.preview.branch_exists),
                commit_message: message,
            });
            els.result.textContent = JSON.stringify(data, null, 2);
            showMessage('success', data.noop ? 'Keine Änderungen erkannt; es wurde kein Commit erstellt.' : `Commit ${data.commit || ''} wurde erfolgreich nach Forgejo gepusht.`);
            state.stage = null;
            state.preview = null;
            els.pushButton.disabled = true;
            els.discardButton.disabled = true;
            await loadBranches();
        } catch (error) {
            showMessage('danger', error.message);
            els.result.textContent = error.message;
        } finally {
            setBusy(false);
        }
    }

    async function discard() {
        if (!state.stage) return;
        setBusy(true, 'Temporärer Upload wird entfernt …');
        try {
            await jsonRequest('discard', {server_idx: Number(els.server.value), stage_id: state.stage.stage_id});
            state.stage = null;
            state.preview = null;
            invalidatePreview(false);
            showMessage('info', 'Temporärer Upload wurde entfernt.');
            els.result.textContent = 'Upload verworfen.';
        } catch (error) {
            showMessage('danger', error.message);
        } finally {
            setBusy(false);
        }
    }

    document.querySelectorAll('input[name="gitUploadType"]').forEach((input) => {
        input.addEventListener('change', () => {
            const zip = uploadType() === 'zip';
            els.directoryWrap.classList.toggle('d-none', zip);
            els.zipWrap.classList.toggle('d-none', !zip);
            updateSelectionInfo();
        });
    });
    els.directory.addEventListener('change', updateSelectionInfo);
    els.zip.addEventListener('change', updateSelectionInfo);
    els.server.addEventListener('change', () => loadServer(false));
    els.repository.addEventListener('change', loadBranches);
    els.branch.addEventListener('change', () => {
        const isNew = els.branch.value === '__new__';
        els.newBranch.classList.toggle('d-none', !isNew);
        if (isNew) els.newBranch.focus();
        invalidatePreview(false);
    });
    els.newBranch.addEventListener('input', () => invalidatePreview(false));
    els.mode.addEventListener('change', () => invalidatePreview(false));
    els.stripTop.addEventListener('change', () => invalidatePreview(true));
    els.reload.addEventListener('click', () => loadServer(true));
    els.createRepoToggle?.addEventListener('click', () => toggleCreateRepository(true));
    els.createRepoClose?.addEventListener('click', () => toggleCreateRepository(false));
    els.createRepoButton?.addEventListener('click', createRepository);
    els.previewButton.addEventListener('click', preview);
    els.pushButton.addEventListener('click', push);
    els.discardButton.addEventListener('click', discard);
    els.commitMessage.addEventListener('input', () => setBusy(false));

    window.addEventListener('beforeunload', () => {
        if (!state.stage || !navigator.sendBeacon) return;
        // Stage wird ohnehin nach TTL entfernt. Kein unsicherer Beacon ohne CSRF/JSON.
    });

    updateSelectionInfo();
    loadServer(false);
})();
