# Config Agent

Der Config Agent ist das privilegierte Backend des TEKO Config Managers. Er
verwaltet freigegebene Konfigurationsdateien, Backups/Restore, systemd Actions,
Git Deploy, Git Repository Upload, Packages, ModSecurity und Monit-Status.

Aktuelle Komponentenversion:

```bash
cat VERSION
```

## Installation

Im Gesamtstack:

```bash
sudo ../setup_config_agent.sh .
```

Als direkt entpacktes Agent-Paket:

```bash
sudo ./_install.sh
```

Pruefung:

```bash
./_analyze.sh
```

## Konfiguration

Produktive Konfigurationen werden bei der Installation aus Beispielen erzeugt
und danach nicht durch Source-Updates blind ueberschrieben.

```text
example/global.json.example
example/managed_configs.json.example
example/git_deploy.json.example
example/config-agent.env.example
example/forgejo-api.token.example
```

Runtime:

```text
/opt/service/config-agent/global.json
/opt/service/config-agent/managed_configs.json
/opt/service/config-agent/git_deploy.json
/opt/service/env/config-agent.env
/opt/service/env/forgejo-api.token
```

## Security

Wichtige Schutzmechanismen:

- verpflichtende API-Authentisierung
- getrennte Agent-Secrets
- IP ACL
- `path_guard=enforce`
- `allowed_roots`
- separate `git_deploy.allowed_roots`
- harte Sperre kritischer Systempfade
- atomare Writes
- Backup vor Aenderungen
- Script-Action-Whitelist
- Symlink-/Hardlink-Schutz
- kontrollierte Git Hosts/Refs/Pfade

## API-Bereiche

Wichtige Routen:

```text
GET  /health
GET  /configs
GET  /config/<id>
POST /config/<id>
GET  /backups/<id>
POST /restore/<id>/<backup>
POST /action/<id>/<action>

GET/POST /git_deploy/settings...
GET/POST /git_deploy/config...
GET      /git_deployments
GET      /git_deploy/status/<deployment>
GET      /git_deploy/releases/<deployment>
POST     /git_deploy/compare/<deployment>
POST     /git_deploy

GET/POST /git_upload/...
GET/POST /packages/...
GET/POST /modsecurity/...
GET      /monit/status
```

Die exakten Routen werden in `lib/*.pm` registriert.

## Git Deploy Roots

Aktueller Default:

```json
"git_deploy": {
  "allowed_roots": [
    "/opt/service",
    "/opt/service_script",
    "/opt/mmbb_services",
    "/opt/mmbb_script"
  ]
}
```

Diese Liste ist bewusst getrennt von den allgemeinen Managed-Config Roots.
