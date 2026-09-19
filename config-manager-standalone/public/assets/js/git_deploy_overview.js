(() => {
    'use strict';

    const cfg = window.GIT_DEPLOY_OVERVIEW_PAGE || {};
    const endpoint = String(cfg.endpoint || 'git_deploy.php');
    const el = (id) => document.getElementById(id);
    const serverSelect = el('gdoServer');
    const filterSelect = el('gdoFilter');
    const checkButton = el('gdoCheck');
    const reloadButton = el('gdoReload');
    const messageBox = el('gdoMessage');
    const meta = el('gdoMeta');
    const progress = el('gdoProgress');
    const empty = el('gdoEmpty');
    const tableWrap = el('gdoTableWrap');
    const body = el('gdoBody');
    const counters = {
        total: el('gdoTotal'), current: el('gdoCurrent'), update: el('gdoUpdate'),
        not_installed: el('gdoMissing'), token_required: el('gdoTokenRequired'), error: el('gdoErrors'), disabled: el('gdoDisabled'),
    };

    let inventory = [];
    let results = [];
    let busy = false;

    function escapeHtml(value) {
        return String(value ?? '')
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
    }

    function normalizedCommit(value) {
        const commit = String(value || '').trim().toLowerCase();
        return /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(commit) ? commit : '';
    }

    function shortCommit(value, emptyLabel = '—') {
        const commit = normalizedCommit(value);
        return commit
            ? `<code class="gdo-commit" title="${escapeHtml(commit)}">${escapeHtml(commit.slice(0, 10))}</code>`
            : `<span class="text-body-secondary">${escapeHtml(emptyLabel)}</span>`;
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

    async function fetchJson(url) {
        const response = await fetch(url, {cache: 'no-store', credentials: 'same-origin', headers: {'Accept': 'application/json'}});
        let data;
        try { data = await response.json(); }
        catch (_) { throw new Error(`Ungültige Portal-Antwort (HTTP ${response.status}).`); }
        if (!response.ok && !data) throw new Error(`HTTP ${response.status}`);
        return data;
    }

    function selectedServer() {
        const raw = String(serverSelect.value || '');
        if (!/^\d+$/.test(raw)) return null;
        const idx = Number(raw);
        return Number.isInteger(idx) ? inventory.find((item) => Number(item.idx) === idx) : null;
    }

    function setBusy(value) {
        busy = value;
        serverSelect.disabled = value || !inventory.length;
        filterSelect.disabled = value || !results.length;
        checkButton.disabled = value || !selectedServer();
        reloadButton.disabled = value;
    }

    function statusBadge(kind) {
        const map = {
            current: ['success', 'Aktuell'],
            update: ['warning', 'Update verfügbar'],
            not_installed: ['secondary', 'Nicht installiert'],
            token_required: ['info', 'Token erforderlich'],
            error: ['danger', 'Fehler'],
            disabled: ['light border text-body-secondary', 'Deaktiviert'],
        };
        const [style, label] = map[kind] || ['secondary', 'Unbekannt'];
        return `<span class="badge text-bg-${style}">${label}</span>`;
    }

    function deployBadge(row) {
        if (row.kind === 'disabled') return '—';
        if (!row.hasDeployStatus) return '<span class="text-body-secondary">kein Deploy</span>';
        if (row.deployOk) return '<span class="badge text-bg-success">Erfolgreich</span>';
        return `<span class="badge text-bg-danger">Fehlgeschlagen</span>${row.errorStage ? `<div class="small text-danger mt-1">${escapeHtml(row.errorStage)}</div>` : ''}`;
    }

    function rowHtml(row) {
        const error = row.error ? `<div class="small text-danger mt-1">${escapeHtml(row.error)}</div>` : '';
        return `<tr data-kind="${escapeHtml(row.kind)}">
            <td><strong>${escapeHtml(row.id)}</strong><div class="small text-body-secondary">${escapeHtml(row.ref || '—')}</div></td>
            <td>${escapeHtml(row.service || '—')}</td>
            <td>${shortCommit(row.activeCommit, 'unbekannt')}</td>
            <td>${shortCommit(row.repositoryCommit, row.kind === 'disabled' ? 'deaktiviert' : 'nicht abrufbar')}${error}</td>
            <td>${statusBadge(row.kind)}</td>
            <td>${deployBadge(row)}</td>
        </tr>`;
    }

    function render() {
        const filter = filterSelect.value || 'all';
        const visible = filter === 'all' ? results : results.filter((row) => row.kind === filter);
        body.innerHTML = visible.map(rowHtml).join('');
        empty.classList.toggle('d-none', results.length > 0);
        tableWrap.classList.toggle('d-none', results.length === 0);
        if (results.length && !visible.length) {
            body.innerHTML = '<tr><td colspan="6" class="text-center text-body-secondary py-4">Keine Profile für diesen Filter.</td></tr>';
        }

        const counts = {total: results.length, current: 0, update: 0, not_installed: 0, token_required: 0, error: 0, disabled: 0};
        results.forEach((row) => { if (Object.hasOwn(counts, row.kind)) counts[row.kind] += 1; });
        Object.entries(counters).forEach(([key, node]) => { node.textContent = String(counts[key] ?? 0); });
    }

    function classify(activeCommit, repositoryCommit, repositoryError, tokenRequired = false) {
        if (tokenRequired) return 'token_required';
        if (repositoryError) return 'error';
        if (!activeCommit) return 'not_installed';
        if (!repositoryCommit) return 'error';
        return activeCommit === repositoryCommit ? 'current' : 'update';
    }

    async function checkProfile(server, profile) {
        if (profile.enabled === false) {
            return {
                id: String(profile.id || ''), kind: 'disabled', service: profile.restart_service || '',
                ref: profile.allowed_ref || '', activeCommit: '', repositoryCommit: '', hasDeployStatus: false,
                deployOk: false, errorStage: '', error: '',
            };
        }

        const url = `${endpoint}?api=status&server_idx=${encodeURIComponent(server.idx)}&deployment=${encodeURIComponent(profile.id)}`;
        const data = await fetchJson(url);
        const envelope = data.response && typeof data.response === 'object' ? data.response : {};
        if (!data.ok) {
            throw new Error(String(envelope.error || data.error || `Statusabfrage fehlgeschlagen (HTTP ${data.http_code || 0}).`));
        }
        const persisted = envelope.status && typeof envelope.status === 'object' ? envelope.status : null;
        const activeCommit = normalizedCommit(envelope.active_commit || persisted?.active_commit);
        const repositoryCommit = normalizedCommit(envelope.repository_commit);
        const repositoryError = String(envelope.repository_error || '');
        const tokenRequired = Boolean(envelope.repository_token_required);
        return {
            id: String(profile.id || ''),
            kind: classify(activeCommit, repositoryCommit, repositoryError, tokenRequired),
            service: String(profile.restart_service || persisted?.restart_service || ''),
            ref: String(envelope.allowed_ref || profile.allowed_ref || ''),
            activeCommit,
            repositoryCommit,
            hasDeployStatus: Boolean(persisted),
            deployOk: Boolean(persisted?.ok),
            errorStage: String(persisted?.error_stage || ''),
            error: tokenRequired ? 'Live-Repository-Stand benötigt ein kurzlebiges Deploy-Token.' : repositoryError,
        };
    }

    async function mapWithConcurrency(items, limit, worker, onProgress) {
        const output = new Array(items.length);
        let next = 0;
        let done = 0;
        async function run() {
            while (true) {
                const index = next++;
                if (index >= items.length) return;
                try { output[index] = await worker(items[index], index); }
                catch (error) {
                    const profile = items[index] || {};
                    output[index] = {
                        id: String(profile.id || ''), kind: 'error', service: profile.restart_service || '',
                        ref: profile.allowed_ref || '', activeCommit: '', repositoryCommit: '', hasDeployStatus: false,
                        deployOk: false, errorStage: 'portal', error: error.message || String(error),
                    };
                }
                done += 1;
                onProgress(done, items.length);
            }
        }
        await Promise.all(Array.from({length: Math.min(limit, Math.max(1, items.length))}, run));
        return output;
    }

    async function checkAllProfiles() {
        clearMessage();
        const server = selectedServer();
        if (!server || busy) return;
        const profiles = Array.isArray(server.profiles) ? [...server.profiles].sort((a, b) => String(a.id).localeCompare(String(b.id))) : [];
        results = [];
        render();
        if (!profiles.length) {
            progress.textContent = 'Keine Deployment-Profile vorhanden';
            showMessage('info', `${server.name} besitzt keine Deployment-Profile.`);
            return;
        }

        setBusy(true);
        progress.textContent = `0/${profiles.length} Profile geprüft`;
        meta.textContent = `${server.name} · Agent ${server.version || '?'} · Live-Abfrage läuft …`;
        try {
            results = await mapWithConcurrency(profiles, 4, (profile) => checkProfile(server, profile), (done, total) => {
                progress.textContent = `${done}/${total} Profile geprüft`;
            });
            render();
            const errors = results.filter((row) => row.kind === 'error').length;
            meta.textContent = `${server.name} · Agent ${server.version || '?'} · zuletzt geprüft ${new Date().toLocaleString('de-CH')}`;
            if (errors) showMessage('warning', `${errors} Profil(e) konnten nicht vollständig geprüft werden. Die übrigen Ergebnisse sind gültig.`);
        } finally {
            setBusy(false);
        }
    }

    async function loadInventory() {
        clearMessage();
        setBusy(true);
        progress.textContent = 'Server und Profile werden geladen …';
        try {
            const data = await fetchJson(`${endpoint}?api=inventory`);
            if (!data.ok || !Array.isArray(data.servers)) throw new Error(data.error || 'Inventar konnte nicht geladen werden.');
            inventory = data.servers.filter((server) => server.online && server.git_enabled);
            serverSelect.innerHTML = '';
            if (!inventory.length) {
                serverSelect.append(new Option('Kein aktiver Git-Deploy-Server', ''));
                progress.textContent = 'Keine aktiven Server';
                return;
            }
            inventory.forEach((server) => {
                const count = Array.isArray(server.profiles) ? server.profiles.length : 0;
                serverSelect.append(new Option(`${server.name} · ${count} Profil(e)`, String(server.idx)));
            });
            serverSelect.value = String(inventory[0].idx);
            progress.textContent = 'Bereit';
            setBusy(false);
            await checkAllProfiles();
        } catch (error) {
            inventory = [];
            results = [];
            render();
            serverSelect.innerHTML = '<option value="">Laden fehlgeschlagen</option>';
            progress.textContent = 'Fehler';
            showMessage('danger', error.message || String(error));
        } finally {
            setBusy(false);
        }
    }

    serverSelect.addEventListener('change', checkAllProfiles);
    filterSelect.addEventListener('change', render);
    checkButton.addEventListener('click', checkAllProfiles);
    reloadButton.addEventListener('click', loadInventory);
    loadInventory();
})();
