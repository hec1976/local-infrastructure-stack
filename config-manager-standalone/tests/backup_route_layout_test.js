'use strict';

const fs = require('fs');
const path = require('path');

const portal = path.join(__dirname, '..');
const packageRoot = path.join(portal, '..');
const managedPage = fs.readFileSync(path.join(portal, 'public', 'configs_editor.php'), 'utf8');
const profilePage = fs.readFileSync(path.join(portal, 'public', 'git_config_editor.php'), 'utf8');
const profileJs = fs.readFileSync(path.join(portal, 'public', 'assets', 'js', 'git_config_editor.js'), 'utf8');
const configFiles = fs.readFileSync(path.join(packageRoot, 'config-agent', 'lib', 'ConfigFiles.pm'), 'utf8');
const gitDeploy = fs.readFileSync(path.join(packageRoot, 'config-agent', 'lib', 'GitDeploy.pm'), 'utf8');

function assert(value, message) {
    if (!value) throw new Error(message);
}

function count(text, needle) {
    return text.split(needle).length - 1;
}

assert(configFiles.includes("get '/raw/managed-configs/backup/#filename'"), 'Managed-Configs-Vorschau erlaubt keine Punkte im Backupnamen.');
assert(configFiles.includes("post '/raw/managed-configs/restore/#filename'"), 'Managed-Configs-Restore erlaubt keine Punkte im Backupnamen.');
assert(gitDeploy.includes("get '/git_deploy/config/backup/#filename'"), 'Deploy-Profil-Vorschau erlaubt keine Punkte im Backupnamen.');
assert(gitDeploy.includes("post '/git_deploy/config/restore/#filename'"), 'Deploy-Profil-Restore erlaubt keine Punkte im Backupnamen.');
assert(gitDeploy.includes("post '/git_deploy/settings/restore/#filename'"), 'Git-Einstellungs-Restore erlaubt keine Punkte im Backupnamen.');
assert(!configFiles.includes("managed-configs/backup/:filename") && !gitDeploy.includes("config/backup/:filename"), 'Fehlerhafte Standard-Platzhalter sind noch vorhanden.');

assert(count(managedPage, 'id="cfgBackupMessage"') === 1, 'Managed-Configs-Meldungsbereich fehlt oder ist doppelt.');
assert(count(profilePage, 'id="gceEditorMessage"') === 1, 'Deploy-Profil-Meldungsbereich fehlt oder ist doppelt.');
assert(managedPage.indexOf('id="cfgBackupMessage"') < managedPage.indexOf('<form class="mt-3" id="cfgForm"'), 'Managed-Configs-Meldung steht nicht oberhalb des Inhalts.');
assert(profilePage.indexOf('id="gceEditorMessage"') < profilePage.indexOf('<div class="tab-content mt-3">'), 'Deploy-Profil-Meldung steht nicht oberhalb des Inhalts.');
assert(managedPage.includes("cfgBackupPreview.textContent = 'Die Backup-Vorschau konnte nicht geladen werden.'"), 'Managed-Configs-Vorschau besitzt keinen neutralen Fehlerzustand.');
assert(profileJs.includes("backupPreview.textContent = 'Die Backup-Vorschau konnte nicht geladen werden.'"), 'Deploy-Profil-Vorschau besitzt keinen neutralen Fehlerzustand.');
assert(!managedPage.includes('cfgBackupPreview.textContent = error.message'), 'Managed-Configs zeigt den Fehler noch doppelt in der Vorschau.');
assert(!profileJs.includes('backupPreview.textContent = error.message'), 'Deploy-Profile zeigt den Fehler noch doppelt in der Vorschau.');

console.log('backup_route_layout_test: OK');
