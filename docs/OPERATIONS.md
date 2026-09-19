# Betrieb

## Standardpruefungen

```bash
sudo ./bin/teko-health.sh
sudo ./bin/teko-postinstall-test.sh
```

## systemd

Kernservices:

```bash
systemctl status apache2 --no-pager
systemctl status forgejo.service --no-pager
systemctl status config-agent.service --no-pager
systemctl status postfix.service --no-pager
systemctl status monit.service --no-pager
systemctl status monit-prometheus-exporter.service --no-pager
systemctl status loki.service --no-pager
systemctl status grafana.service --no-pager
```

## Journals

```bash
journalctl -u config-agent.service -n 100 --no-pager
journalctl -u forgejo.service -n 100 --no-pager
journalctl -u apache2 -n 100 --no-pager
journalctl -u postfix.service -n 100 --no-pager
journalctl -u monit.service -n 100 --no-pager
```

## Config-Agent Health

Lokal:

```bash
curl -k -H "Authorization: Bearer <TOKEN>" \
  https://127.0.0.1:5008/health
```

Der Browser selbst soll den Agent-Token nicht als frei sichtbare Konfiguration
verwenden. Das Portal liest ihn aus der geschuetzten Runtime-Konfiguration.

## Forgejo

```bash
sudo ./teko-forgejo-local/bin/forgejo-health.sh
sudo ./teko-forgejo-local/bin/forgejo-backup.sh
```

Der Backup-Timer kann mit systemd kontrolliert werden:

```bash
systemctl list-timers | grep -i forgejo
```

## Postfix

```bash
postfix check
systemctl status postfix.service --no-pager
journalctl -u postfix.service -n 100 --no-pager
```

## Monit

```bash
monit -t
monit status
curl -fsS http://127.0.0.1:2812/_status?format=xml\&level=full >/dev/null
```

## Monit Exporter

```bash
curl -fsS http://127.0.0.1:9108/healthz
curl -fsS http://127.0.0.1:9108/metrics | head
```

## Typische Git-Deploy-Fehler

### `releases_dir liegt nicht unter allowed_roots`

Pruefen:

1. aktives Profil in `git_deploy.json`
2. daraus berechnetes `releases_dir`
3. `global.json -> git_deploy.allowed_roots`
4. nach Aenderung Agent neu laden/neustarten

Nicht als Workaround verwenden:

- `path_guard=off`
- globale `/`-Freigabe
- beliebige Root-Pfade ohne fachliche Begruendung

### Repository nicht erreichbar

Pruefen:

```bash
getent hosts git.local
curl -k https://git.local/api/v1/version
```

Danach Token-Datei, Dateirechte und TLS-Policy kontrollieren.

## Backup und Restore

Runtime-Backups sind Bestandteil des Designs. Source-Code-History-Dateien sind
hingegen nicht Bestandteil des Repositories.

Bei Config-Restore zuerst Inhalt/Vorschau pruefen, danach Restore ausfuehren und
die zugehoerige Service-Konfiguration validieren.
