'use strict';

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const page = fs.readFileSync(path.join(root, 'public', 'git_deploy.php'), 'utf8');
const script = fs.readFileSync(path.join(root, 'public', 'assets', 'js', 'git_deploy.js'), 'utf8');
const css = fs.readFileSync(path.join(root, 'public', 'assets', 'css', 'git_deploy.css'), 'utf8');

function assert(value, message) {
    if (!value) throw new Error(message);
}

['gitDeployServerPanel', 'gitDeployServerSearch', 'gitDeploySelectVisible', 'gitDeployClearServers',
    'gitDeployServerSummary', 'gitDeployServerList', 'gitDeployServerEmpty']
    .forEach((id) => assert(page.includes(`id="${id}"`), `${id} fehlt.`));

assert(page.includes('aria-multiselectable="true"'), 'Mehrfachauswahl ist nicht barrierearm gekennzeichnet.');
assert(page.includes('git_deploy.css?v=3.25.0'), 'CSS-Cache-Buster 3.25.0 fehlt.');
assert(page.includes('git_deploy.js?v=3.25.0'), 'JavaScript-Cache-Buster 3.25.0 fehlt.');
assert(!page.includes('git-deploy-server-grid'), 'Das nicht skalierbare Kartenraster ist noch vorhanden.');
assert(script.includes('function applyServerFilter()'), 'Serverfilter fehlt.');
assert(script.includes('function setVisibleServerSelection(checked)'), 'Sichtbare Mehrfachauswahl fehlt.');
assert(script.includes('const previousSelection = new Set(selectedIndices())'), 'Serverauswahl bleibt beim Neuladen nicht erhalten.');
assert(script.includes('verfügbar · ${visible} angezeigt'), 'Kompakte Auswahlzusammenfassung fehlt.');
assert(css.includes('max-height: 360px'), 'Serverliste besitzt keine begrenzte Höhe.');
assert(css.includes('overflow: auto'), 'Serverliste ist nicht scrollbar.');
assert(css.includes('position: sticky') && css.includes('.git-deploy-server-columns'), 'Spaltenkopf bleibt beim Scrollen nicht sichtbar.');
assert(css.includes('min-width: 920px'), 'Tabellengeometrie für schmale Ansichten fehlt.');
assert(!page.includes('href="git_config_editor.php"'), 'Der redundante Profile-verwalten-Abschnitt ist noch vorhanden.');
assert(!page.includes('Allgemeine Git-Sicherheitsvorgaben verbleiben'), 'Der redundante Profil-Infokasten ist noch vorhanden.');

console.log('git_deploy_server_selector_test: OK');
