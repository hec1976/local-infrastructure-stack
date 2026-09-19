'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const sourcePath = path.join(__dirname, '..', 'public', 'assets', 'js', 'git_deploy_overview.js');
const source = fs.readFileSync(sourcePath, 'utf8');

function extract(startName, endName) {
    const start = source.indexOf(`function ${startName}`);
    const endFunction = source.indexOf(`function ${endName}`, start + 1);
    if (start < 0 || endFunction < 0) throw new Error(`Funktion ${startName} konnte nicht extrahiert werden.`);
    const end = source.lastIndexOf('\n', endFunction) + 1;
    return source.slice(start, end);
}

const context = {
    escapeHtml(value) { return String(value ?? ''); },
};
vm.createContext(context);
vm.runInContext(
    `${extract('normalizedCommit', 'showMessage')}\n${extract('classify', 'checkProfile')}\n` +
    'this.api = {normalizedCommit, shortCommit, classify};',
    context
);

const {normalizedCommit, shortCommit, classify} = context.api;
const installed = '6b36a6409e6bf750107b63906acc135cc0148758';
const newer = '7bdc03b987209dc18d67419dbcdcc89112a6ab22';

function assert(value, message) {
    if (!value) throw new Error(message);
}

assert(normalizedCommit(installed) === installed, 'Vollstaendige SHA wird nicht akzeptiert.');
assert(shortCommit(installed).includes('>6b36a6409e</code>'), 'Kurz-SHA ist nicht exakt 10 Zeichen lang.');
assert(shortCommit(installed).includes(`title="${installed}"`), 'Vollstaendige SHA fehlt im Tooltip.');
assert(classify(installed, installed, '') === 'current', 'Gleiche Commits muessen aktuell sein.');
assert(classify(installed, newer, '') === 'update', 'Verschiedene Commits muessen ein Update melden.');
assert(classify('', newer, '') === 'not_installed', 'Fehlender aktiver Commit muss nicht installiert melden.');
assert(classify(installed, '', '') === 'error', 'Fehlender Repository-Commit muss Fehler melden.');
assert(classify(installed, newer, 'Zugriff verweigert') === 'error', 'Repository-Fehler muss Vorrang haben.');
assert(
    source.includes('setBusy(false);\n            await checkAllProfiles();'),
    'Die automatische Erstpruefung muss nach dem Laden freigegeben werden.'
);
assert(source.includes('mapWithConcurrency(profiles, 4,'), 'Parallelitaetsgrenze muss vier Profile betragen.');

console.log('git_deploy_overview_logic_test: OK');
