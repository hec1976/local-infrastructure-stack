# TEKO Forgejo Local

Lokaler Forgejo-Git-Dienst fuer den Local Infrastructure Stack.

## Standardmodell

```text
Server            teko / teko.local
Forgejo           https://git.local/
Interner HTTP     127.0.0.1:3000
Git SSH           TCP/2222
Container         Podman rootless image
Systemd           Quadlet
Daten             /srv/forgejo/data
Backups           /srv/forgejo/backup
```

## Installation

```bash
sudo ./setup_forgejo_teko.sh
```

Der Greenfield-Bootstrap richtet soweit erforderlich automatisch ein:

- Forgejo-Datenbank/Install-Lock
- lokalen Administrator
- Organisation `teko`
- privates Repository `teko/config-deploy`
- Deployment-Team
- technischen Service-User
- Service-Token fuer Config-Agent/Config Manager

## Credentials

Admin-Daten:

```text
/opt/service/env/forgejo-admin.env
```

Service-Token:

```text
/opt/service/env/forgejo-api.token
```

Beide Dateien sind Runtime-Secrets und gehoeren nicht ins Git-Repository.

## Quadlet

Forgejo wird aus einer Podman-Quadlet-Datei als `forgejo.service` generiert.
Nach Aenderungen:

```bash
systemctl daemon-reload
systemctl restart forgejo.service
```

Der Boot-Start wird ueber die `[Install]`-Sektion der Quadlet-Datei definiert.

## Betrieb

```bash
./bin/forgejo-health.sh
./bin/forgejo-backup.sh
./bin/forgejo-update.sh
```

## Security

- interner Webport nur Loopback
- externer Browserzugriff nur ueber Apache HTTPS
- private Repositories als Default
- separater technischer Service-User
- Backups root-only
- Major-Upgrades nicht unkontrolliert automatisch
