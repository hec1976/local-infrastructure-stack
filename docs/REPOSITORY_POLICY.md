# Repository Policy

## Grundsatz

Der Git-Tree repraesentiert den **aktuellen Sollstand**. Historische Staende
werden durch Git selbst abgebildet: Commits, Branches, Tags und Releases.

Deshalb werden keine separaten Historienkopien desselben Konfigurationsschemas
im Root oder in `config/` gepflegt.

## Kanonische Beispiele

Richtig:

```text
global.example.json
managed_configs.example.json
git_deploy.example.json
```

Nicht mehr verwenden:

```text
global_2_1_0.example.json
global_2_2_0.example.json
global_2_3_0.example.json
VALIDATION_v2.9.8.json
FIX_v2.9.2.md
```

## Runtime-Verzeichnisse

Leere Runtime-Zielverzeichnisse duerfen mit `.keep` im Repository existieren,
aber deren Inhalte werden ignoriert.

Beispiel:

```text
config-agent/backup/.keep
config-agent/tmp/.keep
```

## Generated Assets

Build-Outputs, Logs, Datenbanken und Testreports werden nicht versioniert. Der
Source muss reproduzierbar genug sein, um diese Artefakte neu zu erzeugen.

## Funktionale History bleibt erhalten

Die Cleanup-Regel betrifft den **Repository-Muell**, nicht betriebliche
Funktionen. Folgende Funktionen bleiben Teil des Produkts:

- Config-Backups und Restore
- Git-Deploy Releases
- Git-Deploy Commit-Vergleich
- Rollback
- Forgejo Backup
- Audit-Log

Diese Daten entstehen zur Laufzeit und gehoeren in die vorgesehenen
Runtime-Verzeichnisse oder Datenspeicher.
