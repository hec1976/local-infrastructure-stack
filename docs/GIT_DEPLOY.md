# Git Deploy – Architektur, Betrieb und Sicherheitsmodell

## 1. Zweck

Git Deploy verteilt versionierte Inhalte aus einem freigegebenen Forgejo-/Git-
Repository auf definierte Linux-Zielpfade. Der Browser darf weder beliebige
Shell-Kommandos noch beliebige Repository- oder Dateipfade an den Agenten
übergeben. Alle wirksamen Parameter stammen aus einem serverseitig validierten
Deployment-Profil.

Die Funktion ist für Konfigurationspakete, Skripte, kleine Services und andere
versionierbare Betriebsartefakte gedacht. Persistente Laufzeitdaten gehören
nicht in den Release-Baum und werden über `preserve` explizit behandelt.

## 2. Trennung der Konfiguration

Git Deploy verwendet zwei Konfigurationsquellen:

- `global.json -> git_deploy`: globale Sicherheits- und Laufzeiteinstellungen
- `git_deploy.json`: ausschliesslich Deployment-Profile

Die Trennung ist absichtlich. Globale Sicherheitsgrenzen wie erlaubte Roots,
Git-Hosts, Token-Modus oder `path_guard` sollen nicht zusammen mit einzelnen
Anwendungsprofilen verändert werden.

Ein minimales Profil:

```json
{
  "schema_version": 2,
  "profiles": {
    "teko-config-deploy": {
      "enabled": true,
      "repository": "https://git.local/teko/config-deploy.git",
      "branch": "main",
      "target": "/opt/service/config-deploy",
      "owner": "root",
      "group": "root",
      "preserve": [],
      "require_diff_preview": true,
      "allow_symlinks": false,
      "reject_hardlinks": true,
      "reject_lfs_pointers": true
    }
  }
}
```

## 3. Deployment-Ablauf

Der produktive Ablauf ist:

```text
Browser
  │
  ├─ Repository/Ref auswählen
  │
  ├─ Compare pro Zielserver
  │      └─ Agent erzeugt einmaliges Preview-Token
  │
  ├─ Benutzer bestätigt
  │
  └─ Deploy pro Zielserver
         ├─ Preview-Token prüfen und verbrauchen
         ├─ Ref/Commit serverseitig erneut prüfen
         ├─ Git-Baum prüfen
         ├─ Release vorbereiten
         ├─ Preserve-Daten übernehmen
         ├─ Preflight
         ├─ Release-Integrität erneut prüfen
         ├─ atomar aktivieren
         ├─ optional Service neu laden/starten
         ├─ Healthcheck
         └─ Status/History schreiben
```

Die Diff-Vorschau ist **pro Zielserver**. Mehrere Server können unterschiedliche
aktive Stände haben; deshalb darf eine Vorschau nicht für alle ausgewählten
Server wiederverwendet werden.

## 4. Preview-Token und TOCTOU-Schutz

Bei `require_diff_preview=true` erzeugt der Agent für einen Compare-Vorgang ein
zufälliges, serverseitig gespeichertes Preview-Token. Es ist gebunden an:

- Deployment-Profil
- Ziel-Commit
- Zielpfad
- aktuelle Config-Generation und Config-Digest
- Fingerprint des aktuell installierten Dateibaums
- Ablaufzeit

Das Token ist nur einmal verwendbar. Vor dem Deploy wird es verbraucht und alle
Bindungen werden erneut geprüft. Wurde zwischen Vorschau und Deploy der aktive
Dateibaum oder die Konfiguration verändert, wird der Vorgang abgebrochen.

Damit ist die Vorschau nicht nur UI-Information, sondern Teil der
Server-Sicherheitsentscheidung.

## 5. Ref- und Commit-Regeln

Unterstützt werden zwei Policies:

### `ancestor`

Typisch für Branches. Ein expliziter Commit muss ein Vorfahr des erlaubten
Branch-Refs sein. Ein Commit aus einem fremden Branch wird abgewiesen.

### `exact`

Typisch für freigegebene Tags. Der Ziel-Commit muss exakt dem aufgelösten Ref
entsprechen. Annotated und Lightweight Tags werden auf den tatsächlichen Commit
aufgelöst.

`commit_sha=auto` bedeutet nicht „beliebiger neuester Commit“, sondern den
aktuellen Commit des **serverseitig erlaubten Refs**.

## 6. Deployment-Modi

### `directory_swap`

Ein neues Release wird in einem separaten Pfad vorbereitet und anschliessend
atomar gegen den aktiven Verzeichnisbaum getauscht. Der vorherige Stand bleibt
für Rollback/History erhalten.

### `symlink_release`

Releases liegen getrennt; der aktive Pfad ist ein verwalteter Symlink auf das
aktuelle Release. Die Aktivierung erfolgt durch atomaren Symlink-Wechsel.

`target_path` und `releases_dir` müssen innerhalb von
`git_deploy.allowed_roots` liegen. `path_guard=enforce` bleibt aktiv.

## 7. Preserve-Daten

`preserve`/`preserve_paths` sind für lokale Daten vorgesehen, die einen
Programmstandwechsel überleben müssen, z. B.:

- lokale Konfiguration
- Runtime-Verzeichnisse
- Eingangs-/Datenverzeichnisse
- definierte Backups

Preserve-Pfade werden serverseitig normalisiert. Symlink-Pfade oder
Pfadtraversal werden nicht akzeptiert. `required` ist ein echtes JSON-Boolean;
Strings wie `"false"` sind ungültig.

## 8. Preflight-Integrität

Preflight-Kommandos dürfen den vorbereiteten Release **prüfen**, aber nicht
verändern.

Vor und nach dem Preflight wird ein SHA-256-Fingerprint über den Release-Baum
gebildet. Einbezogen werden unter anderem:

- relative Pfade
- Dateityp
- Dateirechte
- UID/GID
- Dateigrösse
- SHA-256 des Dateiinhalts
- Symlink-Ziel

Eine Inhaltsänderung gleicher Dateigrösse oder ein reines `chmod` wird dadurch
erkannt. Ein veränderter Release wird vor der Aktivierung abgewiesen.

## 9. Symlinks, Hardlinks, LFS und Submodule

Je nach Profil können sichere relative Symlinks zugelassen werden. Ein
Symlink-Ziel darf den Release-Baum nicht verlassen. Absolute oder aus dem Baum
herausführende Links werden blockiert.

Zusätzlich können bzw. sollen blockiert werden:

- Hardlinks
- Git-LFS-Pointer statt tatsächlicher Inhalte
- Gitlinks/Submodule
- unsignierte Commits bei `require_signed_commit=true`

Der read-only Repository-Assistent kann sichere interne relative Symlinks
analysieren. Der Browser-Dateiupload selbst übernimmt weiterhin keine
Symlinks/Hardlinks.

## 10. Request-Token-Modus

Standardmässig liegt das Forgejo-Token geschützt auf dem Agenten
(`deploy_token_source=file`). Optional kann ein kurzlebiges Token pro Request
verwendet werden (`deploy_token_source=request`).

Im Request-Modus gilt:

- Token wird als Header/POST-Daten transportiert, nicht in URLs
- Compare, Deploy, Restore, Live-Status und Release-History verwenden denselben
  kurzlebigen Token nur für die Dauer des Vorgangs
- das Portal löscht den Token nach Abschluss der kompletten Kette
- die read-only Übersicht zeigt ohne Token `Token erforderlich` und behandelt
  dies nicht als technischen Deploy-Fehler

## 11. Restore/Rollback

Ein manueller Restore ist ein normaler geschützter Deploy auf einen bekannten
früheren Commit. Vor dem Restore wird eine **eigene** Compare-Vorschau erzeugt;
ein Preview-Token eines normalen Deploy-Vorgangs wird nicht wiederverwendet.

Ablauf:

```text
früheren Commit wählen
  -> Compare
  -> eigenes Preview-Token
  -> bestätigen
  -> Restore
  -> Live-Status
  -> Release-History aktualisieren
```

Bei einem Fehler nach Aktivierung – z. B. Service-Restart oder Healthcheck –
versucht der Agent den vorherigen Release kontrolliert wiederherzustellen.

## 12. Repository-Assistent und Git Upload

Die read-only Repository-Funktionen sind von der Schreibfunktion getrennt:

- `/git_deploy/repositories...`: Repositorys/Branches lesen und analysieren
- `/git_upload/...`: Stage, Preview, Commit und Push

Damit kann `git_upload.enabled=false` gesetzt werden, ohne den read-only
Deployment-Assistenten zu verlieren. Ein Repository ohne Push-Recht ist für
die Profilanalyse sichtbar, kann aber nicht für Upload/Push verwendet werden.

## 13. Fail-Closed-Konfiguration

Die Git-Konfiguration akzeptiert nur bekannte Felder und definierte Typen.
Beispiele für absichtlich abgewiesene Werte:

```json
{"allow_http": "false"}
{"schema_version": 999}
{"restart_services": "postfix.service"}
{"keep_releases": 1}
```

Warum: In Perl ist ein nichtleerer String wie `"false"` wahr. Ohne strikte
Typprüfung könnte eine vermeintlich deaktivierte Sicherheitsoption aktiviert
werden. Tippfehler sollen ebenfalls nicht als wirkungslose No-op-Konfiguration
gespeichert werden.

## 14. Konfigurations-Race-Schutz

Beim Bearbeiten von `git_deploy.json` merkt sich das Portal den SHA-256-Stand,
der geladen wurde. Der Save übermittelt `expected_sha256`.

Wurde die Datei inzwischen verändert, antwortet der Agent mit Conflict statt
den neueren Stand zu überschreiben. Settings- und Profil-Saves benutzen einen
gemeinsamen Lock und validieren die kombinierte Konfiguration innerhalb dieses
Locks erneut. Ein Save, der bestehende Profile durch neue Roots/Hosts ungültig
machen würde, wird abgewiesen.

## 15. Betriebsdiagnose

Typische Meldung:

```text
Profil postfix-agent: releases_dir liegt nicht unter allowed_roots
```

Prüfen:

1. `global.json -> git_deploy.allowed_roots`
2. `target_path` bzw. `target`
3. explizites oder abgeleitetes `releases_dir`
4. `path_guard=enforce`
5. erlaubten Git-Host und Ref
6. Agent-Service nach Konfigurationsänderung neu laden/neustarten, falls der
   laufende Prozess die Änderung noch nicht geladen hat

Die Sicherheitsgrenze sollte nicht durch Abschalten von `path_guard` repariert
werden. Pfade und Whitelist müssen konsistent sein.

## 16. Tests

Die Repository-Suite enthält unter anderem:

- reale Git-Commits, Branches und Tags
- Erstdeploy, Update und Rollback
- Fremd-Commit/Ref-Abweisung
- Allowed-Root-Regression
- per-Server Preview-Verdrahtung
- Preview-/Integritäts-/Request-Token-Härtung
- Git-Upload-/read-only-Repository-Trennung
- komplette Plattform-Sandbox

Siehe [TESTING.md](TESTING.md).
