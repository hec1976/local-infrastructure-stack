'use strict';

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const profilePage = fs.readFileSync(path.join(root, 'public', 'git_config_editor.php'), 'utf8');
const managedPage = fs.readFileSync(path.join(root, 'public', 'configs_editor.php'), 'utf8');
const managedCss = fs.readFileSync(path.join(root, 'public', 'assets', 'css', 'configs_editor.css'), 'utf8');
const managedLateCss = fs.readFileSync(path.join(root, 'public', 'assets', 'css', 'configs_editor_late.css'), 'utf8');
const sharedCss = fs.readFileSync(path.join(root, 'public', 'assets', 'css', 'configuration_workspace.css'), 'utf8');
const profileJs = fs.readFileSync(path.join(root, 'public', 'assets', 'js', 'git_config_editor.js'), 'utf8');
const jsonEditorJs = fs.readFileSync(path.join(root, 'public', 'assets', 'js', 'configuration_json_editor.js'), 'utf8');
const moduleNavigation = JSON.parse(fs.readFileSync(path.join(root, 'config', 'module_navigation.json'), 'utf8'));
const deployPage = fs.readFileSync(path.join(root, 'public', 'git_deploy.php'), 'utf8');
const uploadPage = fs.readFileSync(path.join(root, 'public', 'git_upload.php'), 'utf8');
const servicesPage = fs.readFileSync(path.join(root, 'public', 'index.php'), 'utf8');

function assert(value, message) {
    if (!value) throw new Error(message);
}

function count(text, needle) {
    return text.split(needle).length - 1;
}

function assertBalancedHtml(source) {
    const html = source.replace(/<\?[\s\S]*?\?>/g, '');
    const voidTags = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
    const stack = [];
    for (const match of html.matchAll(/<(\/)?([a-z][a-z0-9-]*)\b[^>]*>/gi)) {
        const closing = Boolean(match[1]);
        const tag = match[2].toLowerCase();
        if (voidTags.has(tag) || match[0].endsWith('/>')) continue;
        if (!closing) {
            stack.push(tag);
            continue;
        }
        const opened = stack.pop();
        assert(opened === tag, `HTML-Struktur fehlerhaft: </${tag}> schließt <${opened || 'nichts'}>.`);
    }
    assert(stack.length === 0, `HTML-Struktur nicht geschlossen: ${stack.join(', ')}.`);
}

const tabs = [
    ['gceDetailGeneralTab', 'gceDetailGeneral'],
    ['gceDetailRightsTab', 'gceDetailRights'],
    ['gceDetailActionsTab', 'gceDetailActions'],
];

tabs.forEach(([button, pane]) => {
    assert(count(profilePage, `id="${button}"`) === 1, `${button} fehlt oder ist doppelt.`);
    assert(count(profilePage, `id="${pane}"`) === 1, `${pane} fehlt oder ist doppelt.`);
    assert(profilePage.includes(`data-bs-target="#${pane}"`), `${button} verweist nicht auf ${pane}.`);
    assert(profilePage.includes(`aria-labelledby="${button}"`), `${pane} besitzt keine eindeutige Beschriftung.`);
});

['gceExtraFields', 'gceAddPreserve', 'gcePreserveList', 'gcePreflightEnabled', 'gcePostDeployEnabled', 'gceHealthType']
    .forEach((id) => assert(count(profilePage, `id="${id}"`) === 1, `${id} fehlt oder ist doppelt.`));
assert(count(profilePage, 'id="gceModeState"') === 1, 'Die kompakte Modusanzeige fehlt oder ist doppelt.');
assert(/configuration_workspace\.css\?v=[0-9.]+/.test(profilePage), 'Cache-Buster für die Layoutdatei fehlt.');
assert(/git_config_editor\.js\?v=[0-9.]+/.test(profilePage), 'Cache-Buster für den Profil-Editor fehlt.');
assert(/configs_editor\.css\?v=[0-9.]+/.test(managedPage), 'Cache-Buster für Managed Configs fehlt.');
assert(/configuration_workspace\.css\?v=[0-9.]+/.test(managedPage), 'Gemeinsamer Cache-Buster für Managed Configs fehlt.');
assert(profilePage.includes('configuration_json_editor.js?v=3.10.0'), 'Gemeinsamer JSON-Editor fehlt bei Deployment-Profilen.');
assert(managedPage.includes('configuration_json_editor.js?v=3.10.0'), 'Gemeinsamer JSON-Editor fehlt bei Managed Configs.');

const general = profilePage.indexOf('id="gceDetailGeneral"');
const extra = profilePage.indexOf('id="gceExtraFields"');
const rights = profilePage.indexOf('id="gceDetailRights"');
const preserve = profilePage.indexOf('id="gceAddPreserve"');
const actions = profilePage.indexOf('id="gceDetailActions"');
const preflight = profilePage.indexOf('id="gcePreflightEnabled"');
const postDeploy = profilePage.indexOf('id="gcePostDeployEnabled"');
const health = profilePage.indexOf('id="gceHealthType"');

assert(general < extra && extra < rights, 'Allgemeine Profilfelder sind nicht im Tab Allgemein gebündelt.');
assert(rights < preserve && preserve < actions, 'Persistente Pfade sind nicht im Tab Rechte gebündelt.');
assert(actions < preflight && preflight < postDeploy && postDeploy < health, 'Deployment-Aktionen sind nicht in Ablaufreihenfolge angeordnet.');
const detailHeaderEnd = profilePage.indexOf('</header>', profilePage.indexOf('id="gceProfileDetail"'));
const detailTabs = profilePage.indexOf('class="configuration-detail-tabs');
const detailContent = profilePage.indexOf('class="configuration-detail-content', detailTabs);
assert(detailHeaderEnd < detailTabs && detailTabs < detailContent, 'Profil-Tabs müssen wie bei Managed Configs zwischen Kopf und Inhalt liegen.');
assert(!profilePage.includes('gce-tab-intro'), 'Unter den kompakten Tabs darf keine zusätzliche Bereichsbeschreibung stehen.');

assert(!/^\.container\s*\{/m.test(managedCss), 'configs_editor.css darf Bootstrap-Container nicht global verändern.');
assert(profilePage.includes('<body class="configuration-editor-page git-config-editor-page">'), 'Deployment-Profile verwendet nicht die gemeinsame Seitenklasse.');
assert(managedPage.includes('<body class="configuration-editor-page cfg-editor-page">'), 'Managed Configs verwendet nicht die gemeinsame Seitenklasse.');
assert(profilePage.includes('<div class="container mmbb-main py-3">'), 'Deployment-Profile verwendet nicht den Standard-Seitencontainer des Portals.');
assert(managedPage.includes('<div class="container mmbb-main py-3">'), 'Managed Configs verwendet nicht den Standard-Seitencontainer des Portals.');
assert(!managedCss.includes('container.mmbb-main'), 'Managed Configs besitzt noch eine eigene Breitenregel.');
assert(!managedLateCss.includes('container.mmbb-main'), 'Managed Configs besitzt noch eine späte eigene Breitenregel.');
assert(!sharedCss.includes('.configuration-editor-page .mmbb-main'), 'Die gemeinsame CSS-Datei darf die Standardbreite des Portals nicht überschreiben.');
const navigationByKey = Object.fromEntries(moduleNavigation.items.map((item) => [item.key, item]));
assert(navigationByKey.configs_editor?.label === 'Managed Configs', 'Managed Configs ist nicht sauber in der Modulnavigation beschriftet.');
assert(navigationByKey.configs_editor?.href === 'configs_editor', 'Navigationsziel für Managed Configs ist falsch.');
assert(navigationByKey.git_config_editor?.label === 'Deploy-Profile', 'Deploy-Profile ist nicht in die Modulnavigation integriert.');
assert(navigationByKey.git_config_editor?.href === 'git_config_editor', 'Navigationsziel für Deploy-Profile ist falsch.');
assert(Number(navigationByKey.git_config_editor?.order) === 40, 'Deploy-Profile besitzt nicht die erwartete Deployment-Reihenfolge.');
assert(navigationByKey.git_config_editor?.group === 'Deployment', 'Deploy-Profile ist nicht der Deployment-Gruppe zugeordnet.');
assert(navigationByKey.overview?.label === 'Services & Configs', 'Die bisherige Übersicht ist nicht passend als Services & Configs bezeichnet.');
assert(navigationByKey.overview?.href === 'index', 'Navigationsziel für Services & Configs ist falsch.');
assert(navigationByKey.overview?.icon === 'bi bi-hdd-network', 'Services & Configs besitzt kein passendes Server-Symbol.');
assert(servicesPage.includes('<title>Services &amp; Configs – Config Manager</title>'), 'Browser-Titel von Services & Configs ist nicht konsistent.');
assert(servicesPage.includes('Service- und Config-Status'), 'Statusbereich von Services & Configs ist nicht sauber bezeichnet.');
assert(!servicesPage.includes('Status Übersicht'), 'Die irreführende Bezeichnung Status Übersicht ist noch vorhanden.');
assert(!servicesPage.includes('mmbb-page-header mb-3'), 'Der leere zusätzliche Seitenkopf ist noch vorhanden.');
assert(managedPage.includes('<title>Managed Configs</title>'), 'Browser-Titel von Managed Configs ist nicht konsistent.');
assert(profilePage.includes('<title>Deploy-Profile</title>'), 'Browser-Titel der Deploy-Profile ist nicht konsistent.');
assert(!managedPage.includes('configuration-subnav') && !profilePage.includes('configuration-subnav'), 'Die alte separate Editor-Navigation ist noch vorhanden.');
assert(!sharedCss.includes('.configuration-subnav'), 'CSS der alten separaten Editor-Navigation ist noch vorhanden.');
assert(!managedPage.includes('configuration-editor-heading') && !profilePage.includes('configuration-editor-heading'), 'Die redundante zweite Seitenüberschrift ist noch vorhanden.');
assert(!sharedCss.includes('.configuration-editor-heading'), 'CSS der redundanten zweiten Seitenüberschrift ist noch vorhanden.');
['gceAgentState', 'gceActiveFile', 'gceEditState'].forEach((id) => assert(!profilePage.includes(`id="${id}"`), `${id} ist als redundanter Kopfstatus noch vorhanden.`));
['cfgAgentState', 'cfgActiveFile', 'cfgEditState'].forEach((id) => assert(!managedPage.includes(`id="${id}"`), `${id} ist als redundanter Kopfstatus noch vorhanden.`));
assert(!sharedCss.includes('.configuration-editor-status'), 'CSS der entfernten Kopfstatus-Badges ist noch vorhanden.');
assert(!profilePage.includes('Im einfachen Modus werden nur Repository') && !managedPage.includes('Verwaltete Dateien, Rechte'), 'Überflüssige Erklärungstexte im Editorkopf sind noch vorhanden.');
assert(count(sharedCss, '.configuration-editor-page .configuration-detail-tabs {\n  display: flex;') === 1, 'Die gemeinsame Tab-Geometrie muss zentral genau einmal definiert sein.');
assert(profilePage.includes('class="configuration-detail-tabs nav nav-pills"'), 'Deployment-Profile verwendet nicht die gemeinsame Tab-Komponente.');
assert(managedPage.includes('class="configuration-detail-tabs nav nav-pills"'), 'Managed Configs verwendet nicht die gemeinsame Tab-Komponente.');
assert(profilePage.includes('class="configuration-detail-content"'), 'Deployment-Profile verwendet nicht die gemeinsame Inhaltskomponente.');
assert(managedPage.includes('class="tab-content configuration-detail-content"'), 'Managed Configs verwendet nicht die gemeinsame Inhaltskomponente.');
assert(!sharedCss.includes('.gce-detail-tabs'), 'Alte Deployment-spezifische Tab-CSS-Regeln sind noch vorhanden.');
assert(!managedCss.includes('.cfg-detail-tabs') && !managedLateCss.includes('.cfg-detail-tabs'), 'Alte Managed-Configs-spezifische Tab-CSS-Regeln sind noch vorhanden.');
assert(!sharedCss.includes('.gce-detail-footer') && !managedLateCss.includes('.cfg-detail-footer'), 'Alte Detailfuss-Regeln sind noch vorhanden.');
assert(profilePage.includes('> Speichern') && profilePage.includes('Änderungen speichern'), 'Deployment-Profile muss einen klaren Speichern-Button in Formular und JSON besitzen.');
assert(count(managedPage, 'Änderungen speichern') === 2, 'Managed Configs muss genau einen Speichern-Button je bearbeitbarer Ansicht besitzen.');
assert(profilePage.includes('id="gceSave"') && profilePage.includes('id="gceSaveJson"'), 'Speichern in Formular oder JSON fehlt bei Deployment-Profilen.');
assert(managedPage.includes('id="btnSaveManaged"') && managedPage.includes('id="btnSaveManagedJson"'), 'Speichern in Formular oder JSON fehlt bei Managed Configs.');
['gceSaveInline', 'gceSaveFooter', 'gceSaveFooterWrap'].forEach((id) => assert(!profilePage.includes(`id="${id}"`), `${id} darf nicht mehr vorhanden sein.`));
['btnSaveManagedFooter', 'cfgSaveFooter', 'btn-save-inline'].forEach((id) => assert(!managedPage.includes(id), `${id} darf nicht mehr vorhanden sein.`));
assert(!profilePage.includes('Änderungen werden gesammelt') && !managedPage.includes('Änderungen werden gesammelt'), 'Der überflüssige Speicherhinweis ist noch vorhanden.');
assert(profilePage.includes('id="gceProfilesEditor" class="configuration-json-editor"'), 'Deployment-Profile verwendet nicht die gemeinsame JSON-Editor-Komponente.');
assert(managedPage.includes('id="jsonEditor" class="configuration-json-editor"'), 'Managed Configs verwendet nicht die gemeinsame JSON-Editor-Komponente.');
assert(!profilePage.includes('<textarea id="gceProfilesEditor"'), 'Deployment-Profile verwendet noch das alte JSON-Textarea.');
assert(sharedCss.includes('.configuration-editor-page .configuration-json-editor'), 'Gemeinsame JSON-Editor-Geometrie fehlt.');
assert(!sharedCss.includes('.git-config-editor-page #gceProfilesEditor'), 'Seitenspezifische JSON-Editor-Grösse ist noch vorhanden.');
assert(jsonEditorJs.includes("window.ace.edit(elementId)"), 'Gemeinsame Ace-Initialisierung fehlt.');
assert(jsonEditorJs.includes("editor.session.setMode('ace/mode/json')"), 'Gemeinsamer JSON-Syntaxmodus fehlt.');
assert(jsonEditorJs.includes("ace/theme/tomorrow_night") && jsonEditorJs.includes("ace/theme/tomorrow"), 'Gemeinsame Hell-/Dunkel-Themen fehlen.');
assert(profileJs.includes("window.MMBBConfigurationJsonEditor.create('gceProfilesEditor')"), 'Deployment-Profile initialisiert den gemeinsamen JSON-Editor nicht.');
assert(managedPage.includes("window.MMBBConfigurationJsonEditor.create('jsonEditor')"), 'Managed Configs initialisiert den gemeinsamen JSON-Editor nicht.');

const managedActions = managedPage.slice(managedPage.indexOf('class="cfg-command-actions"'), managedPage.indexOf('</div>', managedPage.indexOf('class="cfg-command-actions"')));
const profileActions = profilePage.slice(profilePage.indexOf('class="gce-command-actions"'), profilePage.indexOf('</div>', profilePage.indexOf('class="gce-command-actions"')));
assert(managedActions.indexOf('<button') < managedActions.indexOf('id="btnReloadServer"') && managedActions.indexOf('id="btnReloadServer"') < managedActions.indexOf('id="btnRefreshServers"'), '„Vom Server laden“ ist bei Managed Configs nicht die erste Aktion.');
assert(profileActions.indexOf('<button') < profileActions.indexOf('id="gceLoad"') && profileActions.indexOf('id="gceLoad"') < profileActions.indexOf('id="gceReloadInventory"'), '„Vom Server laden“ ist bei Deployment-Profilen nicht die erste Aktion.');
assert(managedPage.includes('id="btnReloadServer"') && profilePage.includes('id="gceLoad"'), 'Ladeaktionen fehlen in einem der Editoren.');
assert(count(managedPage, 'class="tab-pane fade configuration-backup-pane"') === 1, 'Gemeinsame Backup-Ansicht fehlt bei Managed Configs.');
assert(count(profilePage, 'class="tab-pane fade configuration-backup-pane"') === 1, 'Gemeinsame Backup-Ansicht fehlt bei Deployment-Profilen.');
assert(managedPage.includes('Automatische Sicherungen vor Änderungen und Restore') && profilePage.includes('Automatische Sicherungen vor Änderungen und Restore'), 'Backup-Beschriftung ist nicht vereinheitlicht.');
assert(sharedCss.includes('.configuration-backup-pane > .configuration-backup-layout') && sharedCss.includes('align-items: stretch'), 'Gemeinsame Backup-Ausrichtung fehlt.');
assert(profilePage.includes('gce-master-detail configuration-editor-workarea'), 'Abstand vor dem Deploy-Profil-Arbeitsbereich fehlt.');
assert(managedPage.includes('cfg-editor-layout configuration-editor-workarea'), 'Abstand vor dem Managed-Configs-Arbeitsbereich fehlt.');
assert(profilePage.includes('gce-master-list configuration-master-scroll'), 'Scrollklasse der Deploy-Profil-Liste fehlt.');
assert(managedPage.includes('cfg-master-list configuration-master-scroll'), 'Scrollklasse der Managed-Configs-Liste fehlt.');
assert(sharedCss.includes('.configuration-editor-page .configuration-editor-workarea') && sharedCss.includes('margin-top: 1rem !important'), 'Gemeinsamer Arbeitsbereich-Abstand fehlt.');
assert(sharedCss.includes('.cfg-master-list.configuration-master-scroll') && sharedCss.includes('.gce-master-list.configuration-master-scroll'), 'Gemeinsame Master-Scroll-Komponente fehlt.');
assert(sharedCss.includes('min-height: 0') && sharedCss.includes('scrollbar-gutter: stable'), 'Stabile interne Scrollfläche fehlt.');
assert(sharedCss.includes('.gce-profile-tab-content'), 'Layoutregeln für die Profil-Tabs fehlen.');
assert(sharedCss.includes('.configuration-detail-tabs {\n  display: flex;'), 'Beide Seiten verwenden nicht dieselbe kompakte Tab-Darstellung.');
assert(sharedCss.includes('border-bottom: 2px solid transparent'), 'Grundlinie der kompakten Tabs fehlt.');
assert(sharedCss.includes('border-bottom-color: var(--cm-config-accent)'), 'Aktive rote Tab-Unterstreichung fehlt.');
assert(!sharedCss.includes('.gce-profile-form::before'), 'Der einfache Modus darf keine eigene Formularzeile belegen.');
assert(profileJs.includes("sessionStorage.setItem('gitConfigEditor.detailTab'"), 'Der gewählte Detail-Tab wird nicht gemerkt.');
assert(profileJs.includes("document.querySelectorAll('.configuration-detail-tabs"), 'Der Profil-Editor verwendet nicht den gemeinsamen Tab-Selektor.');
assert(profileJs.includes("saveJsonButton?.addEventListener('click', saveProfiles)"), 'Der einzige JSON-Speichern-Button ist nicht verbunden.');
assert(!profileJs.includes('git_deploy.json wurde geladen. Eingabemaske und JSON-Ansicht sind synchron.'), 'Die redundante Erfolgsmeldung nach dem Laden ist noch vorhanden.');
assert(profileJs.includes('Der zentrale Profilkatalog wurde geladen, ist aber aktuell ungültig:'), 'Die wichtige Warnung für einen ungültigen geladenen Profilkatalog muss erhalten bleiben.');
assert(!deployPage.includes('Profilgebundener Pull-Deploy:'), 'Der überflüssige Pull-Deploy-Infobanner ist noch vorhanden.');
assert(!uploadPage.includes('Kontrollierter Import nach Forgejo:'), 'Der überflüssige Forgejo-Import-Infobanner ist noch vorhanden.');
assert(profileJs.includes("const modeState = byId('gceModeState')"), 'Die Modusanzeige wird nicht vom Editor aktualisiert.');
assertBalancedHtml(profilePage);
[managedCss, managedLateCss, sharedCss].forEach((css) => {
    assert(count(css, '{') === count(css, '}'), 'CSS-Klammern sind nicht ausgeglichen.');
});

console.log('editor_layout_test: OK');
