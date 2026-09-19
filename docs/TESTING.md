# Tests

## 1. Testebenen

### Repository-Check

```bash
./tools/repo-check.sh
```

Der Repository-Check prueft den Source-Tree ohne Installation. Er kontrolliert
unter anderem:

- keine Cache-/Bytecode-/Editor-Artefakte
- keine historische Root-History oder alte Validierungsreports
- nur kanonische Beispielkonfigurationen
- keine produktiven Secret-Dateien
- JSON-, Shell-, Python- und PHP-Syntax
- Git-Whitespace nach Initialisierung des Repositories

Kompletter portabler Testlauf:

```bash
./tools/run-all-tests.sh
```

Der maschinenlesbare Bericht wird nach `reports/TEST_RESULTS.json` geschrieben.
Das Verzeichnis ist generiert und wird nicht eingecheckt. Fehlende optionale
Interpreter werden als `SKIP` ausgewiesen; fuer eine Freigabe soll der Lauf in
der vollstaendigen CI-Umgebung ohne `FAIL` abgeschlossen werden.

### Git-Deploy-/Git-Upload-Regressionen

```bash
python3 tests/git_deploy_feature_test.py
python3 tests/git_deploy_hardening_test.py
python3 tests/git_upload_hardening_test.py
python3 tests/git_deploy_gui_backend_test.py
./tests/git_deploy_allowed_root_regression_test.sh
./tests/git_deploy_versioned_integration.sh
```

`git_deploy_versioned_integration.sh` arbeitet mit echten temporaeren
Git-Repositories, Commits, Branches und Tags. Getestet werden insbesondere:

- Branch-Head und Ancestor-Regel
- Fremd-Commit ausserhalb des erlaubten Refs
- Annotated und Lightweight Tags
- Exact-Tag-Aufloesung
- Erstdeploy
- Update mit geaenderten/neuen Dateien
- Rollback auf einen frueheren Commit
- Release-Historie

Die Hardening-Tests pruefen zusaetzlich die Verdrahtung fuer:

- zustandsgebundene, einmalige Preview-Tokens
- per-Server Diff-Vorschau
- Preflight-Integritaetsfingerprint
- Request-Token fuer Status/History
- strikte JSON-Booleans und bekannte Felder
- read-only Repository-Browser getrennt von Upload/Push
- sichere interne Repository-Symlinks
- Stale-Editor-/SHA-256-Schutz

### Sandbox-Test

```bash
./tests/sandbox_test.sh
```

Der Sandbox-Test fuehrt die breite Plattformintegration aus. Er prueft Shell,
PHP, Python, JSON, Host-/Apache-Transformationen, Config Manager,
Observability, Git Deploy, Desired State, Fleet, Enrollment, Package
Management, ModSecurity und Monit Exporter.

Einzelne Tests koennen auf einer Entwickler-Sandbox uebersprungen werden, wenn
optionale Runtime-Module fehlen. Der Test meldet diese Faelle explizit als
`SKIP`, nicht als `PASS`.

### Zielsystemtest

Nach Installation:

```bash
sudo ./bin/teko-health.sh
sudo ./bin/teko-postinstall-test.sh
```

Dieser Lauf ist fuer die finale Betriebsfreigabe entscheidend, weil systemd,
Podman, Apache, Postfix, Monit und die Ziel-Perl/PHP-Module nur auf einem
passenden Linux-Testsystem realistisch vollstaendig validiert werden koennen.

## 2. JavaScript- und PHP-Syntax

Bei Aenderungen am Portal zusaetzlich:

```bash
node --check config-manager-standalone/public/assets/js/git_deploy.js
node --check config-manager-standalone/public/assets/js/git_deploy_overview.js
php -l config-manager-standalone/public/git_deploy.php
php -l config-manager-standalone/public/git_deploy_overview.php
```

## 3. Was nicht ins Git gehoert

Testergebnisse gehoeren in CI-Logs oder einen externen Artefaktbereich, nicht
als fortlaufend neue Dateien in den Source-Root.

Nicht committen:

```text
VALIDATION_v*.json
*_TEST_REPORT_v*.md
SANDBOX_TEST_REPORT*.md
.pytest_cache/
__pycache__/
*.pyc
```

Die **produktive** Git-Deploy-Release-Historie, Audit-Daten und Runtime-Backups
sind davon nicht betroffen. Sie liegen ausserhalb des Source-Repositories und
sind Teil des Betriebsmodells.
