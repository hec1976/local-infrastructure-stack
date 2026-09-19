# Konfiguration

## Zentrale Stack-Konfiguration

`teko-stack.conf` enthaelt Namen, Ports und globale Defaultwerte. Werte koennen
vor dem Aufruf als Environment-Variablen gesetzt werden.

Wichtige Variablen:

```text
SERVER_IP
SERVER_SHORTNAME
SERVER_FQDN
FORGEJO_FQDN
FORGEJO_HTTP_PORT
FORGEJO_SSH_PORT
FORGEJO_ORG
FORGEJO_REPO
CONFIG_MANAGER_FQDN
CONFIG_AGENT_PORT
CONFIG_AGENT_URL
GRAFANA_FQDN
GRAFANA_HTTP_PORT
LOKI_HTTP_PORT
```

## Config-Agent global.json

Kanonisches Beispiel:

```text
config-agent/example/global.json.example
```

Wichtige Bereiche:

### Listener

```json
"listen": "127.0.0.1:5008"
```

### IP ACL

```json
"allowed_ips": ["127.0.0.1/32"]
```

### TLS

```json
"ssl_enable": 1,
"ssl_cert_file": "/opt/service/ssl/agent.local.crt",
"ssl_key_file": "/opt/service/ssl/agent.local.key"
```

### Allgemeiner Path Guard

```json
"path_guard": "enforce",
"allowed_roots": [
  "/opt/service",
  "/etc",
  "/srv/observability"
]
```

### Git Deploy

```json
"git_deploy": {
  "enabled": true,
  "allowed_roots": [
    "/opt/service",
    "/opt/service_script",
    "/opt/mmbb_services",
    "/opt/mmbb_script"
  ]
}
```

### Git Upload

```json
"git_upload": {
  "enabled": true,
  "allowed_owners": ["teko"]
}
```

## managed_configs.json

Jeder Eintrag beschreibt genau eine verwaltete Datei.

Pflicht-/Kernfelder:

```text
path
category
user
group
mode
```

Fuer Serviceintegration:

```text
service
actions
```

Beispiel:

```json
"postfix-main": {
  "path": "/etc/postfix/main.cf",
  "category": "mail",
  "service": "postfix.service",
  "desired_status": "running",
  "user": "root",
  "group": "root",
  "mode": "0644",
  "actions": {
    "start": [],
    "stop": [],
    "status": [],
    "reload": [],
    "restart": [],
    "journal": [80]
  }
}
```

Die GUI soll Service und Aktionen direkt aus diesen Metadaten anzeigen.

`desired_status` ist optional und wird von der Betriebsuebersicht fuer den
Runtime-vs-Soll-Vergleich verwendet. Erlaubt sind `running`, `stopped` und `disabled`.
Bei einem Eintrag mit `service` und erlaubter `status`-Aktion setzt der Agent ohne
expliziten Wert den Portal-Sollwert auf `running`. Damit werden unerwartet gestoppte
verwaltete Services sofort als Drift sichtbar, ohne die vorhandene Registry migrieren zu
muessen.

## git_deploy.json

Kanonisches Beispiel:

```text
config-agent/example/git_deploy.json.example
```

Ein Profil wird nicht nur auf JSON-Syntax geprueft. Der Agent prueft ebenfalls
Repository, erlaubte Referenz, Zielpfade und Deployment-spezifische
Sicherheitsregeln.

## Config Manager Beispiele

Unter `config-manager-standalone/config/` gibt es bewusst nur noch kanonische
Beispieldateien:

```text
global.example.json
managed_configs.example.json
git_deploy.example.json
desired_state.example.json
server_registry.example.json
```

Alte parallel gepflegte `*_2_x_x.example.json`-Dateien wurden entfernt, weil
sie inhaltlich auseinanderlaufen koennen und im Git keine zweite Wahrheit
bilden sollen.
