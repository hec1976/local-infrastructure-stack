# Installation

## Voraussetzungen

Der Stack verwendet zypper und openSUSE-typische Apache-/systemd-Pfade. Die
Installationsscripts installieren benoetigte Pakete soweit vorgesehen selbst.
Typische Abhaengigkeiten sind:

- Bash
- systemd
- zypper
- Podman
- Apache 2
- PHP 8 mit curl/sqlite/openssl/ctype/mbstring
- Perl + Mojolicious
- Git
- curl
- openssl
- rsync
- Python 3
- Postfix
- Monit
- Go nur fuer einen lokalen Neubuild des Monit Exporters

## Vorbereitung des Repositories

```bash
git clone <repository-url> teko-local-stack
cd teko-local-stack
./tools/repo-check.sh
```

Alternativ kann ein sauberer Source-Export entpackt werden.

## Konfiguration vor Installation

Die meisten lokalen Namen koennen ueber `teko-stack.conf` oder Environment-
Variablen angepasst werden. Fuer eine Standard-Labinstallation ist keine
Aenderung zwingend.

Beispiel fuer explizite IP:

```bash
sudo SERVER_IP=192.168.121.20 ./setup_teko_local.sh
```

## Vollinstallation

```bash
sudo ./setup_teko_local.sh
```

Der Installer bricht bei nicht tolerierten Fehlern durch `set -euo pipefail` ab.
Komponentenscripts koennen einzeln wiederholt werden.

## Einzelkomponenten

Forgejo:

```bash
sudo ./teko-forgejo-local/setup_forgejo_teko.sh
```

Config-Agent:

```bash
sudo ./setup_config_agent.sh ./config-agent
```

Config Manager:

```bash
sudo ./setup_config_manager.sh \
  ./config-manager-standalone \
  /srv/www/config-manager-standalone
```

Enrollment Manager:

```bash
sudo ./setup_agent_enrollment_manager.sh
```

Observability:

```bash
sudo ./setup_observability.sh
```

Postfix + Monit:

```bash
sudo ./setup_postfix_monit.sh
```

Monit Exporter:

```bash
sudo ./setup_monit_exporter.sh
```

## Force-Modus

Der Master-Installer uebergibt `TEKO_FORCE=1` an die Komponenten:

```bash
sudo ./setup_teko_local.sh --force
```

Force ist fuer einen kontrollierten Redeploy vorgesehen. Vor einem produktiven
Force-Lauf sollen lokale Abweichungen erfasst werden. Insbesondere sollen keine
produktiven Aenderungen direkt in vom Installer verwalteten Dateien gepflegt
werden, wenn sie nicht im Source of Truth enthalten sind.

## Zertifikate

Der Stack kann fuer lokale Tests selbstsignierte Zertifikate erzeugen. Fuer
produktivere Umgebungen sollen diese durch Zertifikate einer internen CA ersetzt
werden. Danach sind `verify_tls` bzw. CA-Pfade entsprechend anzupassen.

## Nachkontrolle

```bash
sudo ./bin/teko-health.sh
sudo ./bin/teko-postinstall-test.sh
```

Zusätzlich:

```bash
systemctl --failed
systemctl status apache2 forgejo.service config-agent.service --no-pager
```

Bei Observability:

```bash
systemctl status loki.service grafana.service --no-pager
curl -fsS http://127.0.0.1:9108/healthz
```
