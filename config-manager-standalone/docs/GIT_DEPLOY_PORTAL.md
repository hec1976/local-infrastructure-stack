# Config Manager – Git Deploy Portal

Diese Datei beschreibt die Portal-spezifische Bedienung von Git Deploy. Das
vollständige Sicherheits-, Agent- und Deployment-Modell steht in
[`../../docs/GIT_DEPLOY.md`](../../docs/GIT_DEPLOY.md).

## Konfigurationsmodell

Der Stack trennt globale Sicherheitsgrenzen und einzelne Deploy-Profile:

```text
global.json
  └─ git_deploy                 globale Sicherheits-/Runtime-Grenzen

git_deploy.json
  └─ schema_version + profiles  einzelne Deployment-Profile
```

Die globale Git-Deploy-Konfiguration wird **nicht** auf der normalen
`git_deploy.php`-Seite editiert. Die Deploy-Seite arbeitet mit Profilen,
Compare, Deploy, Restore, Status und History. Die Agent-Routen fuer globale
Settings bleiben fuer kontrollierte Administration und Lifecycle-Funktionen
vorhanden.

Kanonische Beispiele:

```text
config-agent/example/global.json.example
config-agent/example/git_deploy.json.example
config-manager-standalone/config/global.example.json
config-manager-standalone/config/git_deploy.example.json
```

## Profil-Editor

`git_config_editor.php` verwaltet `git_deploy.json`. Der Editor bietet eine
strukturierte Formularansicht und eine vollstaendige JSON-Ansicht. Beim Laden
merkt sich das Portal den SHA-256-Stand der Datei. Beim Speichern wird dieser
Stand als `expected_sha256` an den Agenten uebergeben.

Wurde die Datei inzwischen von einem anderen Browser oder Prozess geaendert,
antwortet der Agent mit HTTP 409. Ein veralteter Editorstand ueberschreibt damit
keine neuere Konfiguration.

Der Agent validiert Profile fail-closed. Unbekannte Felder, falsche JSON-Typen,
ungueltige Roots, Hosts, Refs, Hooks, Healthchecks oder Limits werden vor dem
Speichern abgewiesen.

## Repository-Assistent

Der Assistent verwendet die read-only Deploy-Routen:

```text
GET /git_deploy/repositories
GET /git_deploy/repositories/:owner/:repository/branches
GET /git_deploy/repositories/:owner/:repository/scan
```

Diese Funktionen bleiben auch bei `git_upload.enabled=false` verfuegbar. Ein
Repository mit Leserecht, aber ohne Push-Recht, kann fuer ein Deploy-Profil
analysiert werden. Schreiboperationen bleiben gesperrt.

## Deploy mit Diff-Freigabe

Bei `require_diff_preview=true` ist die Vorschau Teil der
Sicherheitsentscheidung. Das Portal erzeugt **fuer jeden ausgewaehlten
Zielserver eine eigene Compare-Vorschau**. Der Agent liefert ein einmaliges,
servergebundenes Preview-Token.

```text
Server A -> Compare -> Preview A -> Deploy A
Server B -> Compare -> Preview B -> Deploy B
Server C -> Compare -> Preview C -> Deploy C
```

Eine Vorschau von Server A wird nicht fuer Server B oder C wiederverwendet.
Der Agent prueft das Token erneut, bindet es an Ziel-Commit, Konfigurationsstand
und aktiven Dateibaum und verbraucht es beim Deploy.

## Restore

Ein Restore erzeugt eine **eigene** Compare-Vorschau fuer den gewaehlten
frueheren Commit:

```text
Release waehlen
  -> Compare
  -> eigenes Preview-Token
  -> Bestaetigung
  -> Restore
  -> Live-Status
  -> Release-History neu laden
```

Ein Token einer normalen Deploy-Vorschau wird fuer Restore nicht verwendet.

## Request-Token-Modus

Bei `deploy_token_source=request` wird ein kurzlebiges Forgejo-Token fuer den
kompletten Portalvorgang im Speicher gehalten:

```text
Compare -> Deploy/Restore -> Status -> History -> Token verwerfen
```

Es wird nicht in eine URL geschrieben. Die serverweite read-only
Deploy-Uebersicht zeigt ohne dieses Token `Token erforderlich`, nicht einen
technischen Deploy-Fehler. Der lokal installierte Commit kann trotzdem
angezeigt werden.

## Ergebnis- und Statusdarstellung

Das Portal unterscheidet mindestens:

- aktuell
- Update verfuegbar
- nicht installiert
- Token erforderlich
- Deploy fehlgeschlagen
- Repository-/Agent-Fehler
- deaktiviert

`active_commit` ist der lokal verifizierte Installationsstand.
`repository_commit` ist der live aufgeloeste Stand des freigegebenen Refs.

## Git Repository Upload

Repository-Upload und Deploy-Assistent sind absichtlich getrennt. Upload kann
Dateien stagen, vergleichen, committen und pushen. Der Schreibpfad benoetigt
`git_upload.enabled=true` und Push-Recht. Die read-only Analyse benoetigt dies
nicht.

Auch Git Upload validiert seine Konfiguration fail-closed: unbekannte Felder,
String-Booleans wie `"false"`, ungueltige Limits und nicht erlaubte
Schreiboperationen werden abgewiesen.

## Fehlerdiagnose

Bei Meldungen wie

```text
Profil postfix-agent: releases_dir liegt nicht unter allowed_roots
```

muessen `target_path`/`target`, `releases_dir` und
`global.json -> git_deploy.allowed_roots` zueinander passen. `path_guard` soll
nicht zur Fehlerumgehung deaktiviert werden.

Weitere Details, insbesondere Ref-Policy, Preflight-Integritaet, Preserve,
Symlink-Regeln, Healthcheck und Rollback:
[`../../docs/GIT_DEPLOY.md`](../../docs/GIT_DEPLOY.md).
