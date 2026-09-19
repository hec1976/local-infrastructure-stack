# Config Manager Standalone

Das Verzeichnis enthaelt das lokale PHP-Webportal des Local Infrastructure Stack.

Aktuelle Komponentenversion:

```bash
cat VERSION
```

## Aufbau

```text
public/          Apache DocumentRoot und UI-Seiten
Controller/      Controllerlogik
Service/         Fachlogik
Repository/      Zugriff auf Config-Agent/Backend
Utils/           Hilfsfunktionen
lib/             Runtime-Helfer
config/          Portal- und Beispielkonfiguration
standalone/      Login, Environment, Audit, Layout und Runtime-Daten
```

## Installation

Im Gesamtstack:

```bash
sudo ../setup_config_manager.sh . /srv/www/config-manager-standalone
```

Die Installation richtet Apache, PHP, lokalen Admin-Zugang und die Verbindung
zum Config-Agent ein.

## Sicherheit

- Apache verwendet `public/` als DocumentRoot.
- Runtime-Secrets liegen unter `standalone/data/` ausserhalb des DocumentRoot.
- Login und Session-Schutz sind lokal integriert.
- Schreibende Systemaktionen gehen ueber den Config-Agent.
- Produktive Runtime-Dateien sind in `.gitignore` ausgeschlossen.

## Kanonische Beispiele

```text
config/global.example.json
config/managed_configs.example.json
config/git_deploy.example.json
config/desired_state.example.json
config/server_registry.example.json
```

Alte versionsspezifische Parallelkopien werden nicht mehr gepflegt.
