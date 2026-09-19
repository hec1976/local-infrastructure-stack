## 3.18.32

- Grafana Alloy Dashboard-Fix: Alloy/Loki-Panels filtern jetzt stabil ueber `source="alloy"` statt ueber `job="systemd-journal"`.
- Hintergrund: `loki.source.journal` liefert in der realen Laufzeit das `job`-Label z. B. als `loki.source.journal.system`; dadurch waren Daten in Loki/Explore sichtbar, aber das Dashboard blieb leer.
- Host-Auswahl verwendet jetzt `label_values({source="alloy"}, hostname)`.
- Auch die Alloy-Kachel in `TEKO Service Uebersicht` nutzt den stabilen `source="alloy"`-Selector.
- Regressionstest verhindert kuenftig wieder einen harten Dashboard-Filter auf `job="systemd-journal"`.


## 3.18.31
- Python 3.6 compatibility fix: removed invalid universal_newlines argument from tempfile.mkstemp() in teko-observability-auth-sync.py.
- Added regression check to ensure universal_newlines is used only with subprocess APIs, never tempfile.mkstemp().
## 3.18.31

- Python-3.6-Kompatibilitaet fuer Observability-Auth/Enrollment korrigiert: Laufzeitpfade verwenden bei `subprocess.run()` jetzt `universal_newlines=True` statt des erst ab Python 3.7 verfuegbaren `text=True`.
- Betroffen und korrigiert: Observability-Auth-Sync, Server-Registry-Write, Enrollment-Worker und Agent-Token-Manager.
- Regressionstest verhindert neue `subprocess.run(..., text=True)`-Vorkommen in produktiven Runtime-Skripten.

## 3.18.29

- Observability: lokaler Fleet-Host verwendet exakt die Config-Agent/Alloy Host-ID aus identity.json.
- Observability: apache2-utils wird mitinstalliert; Auth-Sync wird nach Setup hart auf lokalen Host geprüft.
- Grafana: neues provisioniertes Dashboard `TEKO Alloy · System Journal` mit Host-Auswahl, Aktivität und Live-Logs.
- Grafana: Service-Übersicht zeigt zusätzlich Alloy-Journal-Aktivität.
- Registry Writer: fehlenden subprocess-Import korrigiert.

# 3.18.28 - 2026-09-13

- Observability Data Plane vereinfacht: Apache proxyt Alloy-Ingest direkt auf Loki (`127.0.0.1:3100`) und Prometheus (`127.0.0.1:9090`).
- `observability-ingest.service`, Python-Proxy und Port 5081 entfernt. Upgrades deaktivieren und loeschen die Legacy-Komponente automatisch.
- Host-spezifische Config-Agent-Tokens bleiben erhalten und werden als Apache Basic-Auth-Hashes in `/opt/service/config-manager/observability.htpasswd` synchronisiert.
- Token-Rotation und Server-Registry-Aenderungen aktualisieren die Apache-Auth-Datei automatisch.
- Loki/Prometheus bleiben localhost-only; extern ist ausschliesslich Apache/HTTPS exponiert.
- End-to-End- und Regressionstests auf die Direct-Proxy-Architektur umgestellt.

## 3.18.27

- Fix Observability deploy failure `runuser: cannot set groups: Operation not permitted` in hardened Git-Deploy contexts.
- Alloy configuration validation no longer switches users with `runuser`; syntax is validated before activation and the effective service-user permissions are verified by a real systemd restart plus five-second stability check.
- `/etc/alloy/config.alloy` remains `root:root 0644`; secrets remain outside the config in the protected EnvironmentFile.
- `client-baseline` bumped to 1.2.8 so managed hosts receive the corrected configurator.

## 3.18.26

- Fix SUSE Alloy deployment: `client-baseline` may install its configurator below `/usr/lib/client-baseline/` because `%{_libexecdir}` is distribution-specific. The observability deployment now discovers both `/usr/lib` and `/usr/libexec` and falls back to the RPM file list.
- Remove the silent direct-restart fallback. If the package configurator is missing, deployment fails with a precise diagnostic instead of starting Alloy with stale permissions/configuration.
- Keep the package configurator's 5-second stable-service check as the authoritative Alloy healthcheck, preventing the post-deploy race that previously produced `rc=5` while systemd showed the service only milliseconds old.
- `client-baseline` bumped to 1.2.7 to force a clean repository update.

## 3.18.25 - Alloy Config Permission Fix

- Behebt `permission denied` beim Start von `alloy.service` auf `/etc/alloy/config.alloy`.
- Die Alloy-Konfiguration enthaelt keine Secrets und wird deshalb robust als `root:root 0644` installiert.
- Observability-Zugangsdaten bleiben ausschliesslich in der geschuetzten Environment-Datei.
- Beide Schreibpfade sind korrigiert: `client-baseline` und Config-Agent `/baseline/alloy-config`.
- `client-baseline` 1.2.6; Config-Agent 2.23.15.

## 3.18.24 - Alloy Observability Configuration Hardening

- Alloy-Konfiguration wird in beiden Erzeugungswegen konsistent und syntaktisch gueltig erzeugt.
- Config-Agent verwendet fuer Kommentare ausschliesslich `//`; kein `#` mehr in generierter `config.alloy`.
- Client-Baseline verwendet fuer Journal-Gruppen den tatsaechlich ermittelten Alloy-Serviceuser statt fest `alloy`.
- Loki-Labels `source=alloy` und `job=systemd-journal` werden standardmaessig gesetzt.
- Regressionstest verhindert Markdown-URLs (`[https://...](https://...)`) und ungueltige `#`-Kommentare.

## 3.18.23

- Fail2ban-Statusabruf beschleunigt: bei bereits installiertem Fail2ban keine Paket-/Repository-Prüfung mehr.
- Fail2ban-GUI zeigt Ladefortschritt, Langläufer-Hinweis ab 2 s und die gemessene Ladezeit.
- Config-Agent 2.23.13 / Config-Manager 2.33.4.

# 3.18.22

- Firewall-Status deutlich beschleunigt: bei installiertem firewalld wird keine Repository-Paketvorschau mehr bei jedem Seitenaufruf ausgefuehrt.
- Agent-seitiger Firewall-Statuscache mit 4 Sekunden TTL; jede Aenderung invalidiert den Cache sofort.
- Firewall-Aenderungen liefern nicht mehr zusaetzlich einen kompletten Status-Scan zurueck. Dadurch entfaellt der bisherige doppelte `--list-all-zones`-Durchlauf nach jeder Aktion.
- Sichtbare Lade- und Aktionsanzeige im Portal fuer Statusabfrage, Interface-Zuweisung, Regel-Aenderung, Zonenaktion und Dienststeuerung.
- Nach 2 Sekunden wird angezeigt, dass firewalld/D-Bus noch antwortet; nach erfolgreichem Laden wird die gemessene Dauer angezeigt.

# 3.18.21

- Firewall-Zonenparser korrigiert: Header wie `public (default, active)` werden jetzt als Zone erkannt und nicht mehr faelschlich als Rich Rule angezeigt.
- Interface-Zuweisung verwendet die kanonische firewalld-Syntax `--zone=<zone> --change-interface=<iface>`; Entfernen analog mit `--remove-interface=<iface>`.
- Port-, Service-, Source- und Rich-Rule-Aenderungen verwenden ebenfalls die eindeutige `--option=value`-Syntax; dadurch funktionieren insbesondere Loeschaktionen verlaesslicher.
- Regressionstest fuer default+active-Zonen, falsche Rich-Rule-Erkennung und Interface-Befehle ergaenzt.

## 3.18.20 - 2026-09-13
- Firewall-UI kompakter aufgebaut: zentrale Zonenauswahl mit direkter Interface- und Netz-Zuordnung.
- `Quelle / Netz` aus den Freigaberegeln entfernt; firewalld-Source wird korrekt als Zonenbindung behandelt.
- Unbenutzte Systemzonen standardmaessig ausgeblendet; eigene Zonen bleiben loeschbar.
- Kuenstliche `public`-Ergaenzung aus der Zonenauswahl entfernt.
- Kompakte Zonenuebersicht und direkte Regelliste fuer die ausgewaehlte Zone.

# Changelog
## 3.18.19

### Improved
- Firewall: Zonenverwaltung ist jetzt zonenzentriert. Interfaces werden direkt innerhalb der jeweiligen Zone angezeigt, zugewiesen, verschoben und entfernt.
- Firewall: klare Statusdarstellung fuer aktive und inaktive Zonen; konfigurierte, aber nicht wirksame Zonen erhalten eine Warnung.
- Firewall: neue Filter `Aktive`, `Konfigurierte` und `Alle` statt eines wenig eindeutigen Umschalters.
- Firewall: vorhandene Regeln werden nach Quellen/Netzen, Services, Ports und erweiterten Regeln gruppiert.
- Firewall: Interface-Zuweisung wird als `Zuweisen / aktivieren` direkt bei der Zielzone angeboten; die Wirkung eines Zonenwechsels wird vor der Aenderung erklaert.

## 3.18.18

### Fixed
- Firewall: leere Standardzonen werden ausgeblendet, mit Umschalter fuer die vollstaendige Liste.
- Firewall: falscher Warnhinweis zur Konfigurationsquelle bei aelteren Agent-Versionen.
- Firewall: "Keine Regeln in dieser Zone" trotz vorhandener Regeln.
- Firewall: Zonen-Target wird ohne `%%`-Markierung dargestellt.
- Firewall: leere Eingabefelder erzeugen keine Fehlermeldung mehr.

### Added
- Agent-Endpunkt `POST /firewall/zone` zum Anlegen und Loeschen von Zonen, mit Schutz eingebauter Zonen.
- Regeltyp `interface` zur Zuordnung von Netzwerkschnittstellen, inklusive Interfaceliste in `/firewall/info`.
- Audit-Eintrag `firewall_zone`.

## 3.18.17

### Fixed
- Firewall: Remote-Lockout durch automatischen firewalld-Start behoben; Selbstschutzregeln fuer Agent-Port und SSH werden vor dem Start per `firewall-offline-cmd` gesetzt.
- Firewall: permanente Konfiguration wird auch bei gestopptem Dienst gelesen und als solche gekennzeichnet.
- Firewall: Entfernen von Agent-Port oder `ssh` erfordert eine ausdrueckliche Bestaetigung.

### Added
- Agent-Endpunkt `POST /firewall/changes` fuer bis zu 32 Regeln in einem Vorgang mit Vorabvalidierung und einem einzigen Reload.
- Portal: Vormerkliste mit "Alle anwenden", Duplikaterkennung gegen den aktuellen Zonenstand und Ergebnisbilanz neu/bereits vorhanden.
- Audit-Eintrag `firewall_rules` fuer Sammelanwendungen.

## 3.18.16

### Fixed
- Firewall: Regeltyp `source_port` im Config-Manager-Service freigegeben (Tab "Port + Quelle" war funktionslos).
- Firewall: Portbereiche (`8000-8100/tcp`) in Agent und Rich-Rule-Pfad unterstuetzt, damit Anlegen und Loeschen konsistent sind.
- Firewall: `_fw_change` stellt einen laufenden firewalld sicher, bevor `firewall-cmd --permanent` aufgerufen wird.
- Firewall: alle definierten Zonen werden gelistet, nicht nur die aktiven.
- Firewall: Drift zwischen Runtime und permanenter Konfiguration wird erkannt und angezeigt.
- Agent-Enrollment: `CONFIG_AGENT_TOKEN_SCOPES` wird bei Updates um fehlende Pflicht-Scopes ergaenzt.
- Trust-Anchor: Enrollment- und Repair-Bundle scheitern hart, wenn das Manager-Zertifikat fehlt.

### Added
- Agent-Endpunkt `POST /firewall/service` (enable, restart, disable) inklusive Portal-Buttons und Audit-Eintrag `firewall_service`.

## 3.18.15

- P1: Agent Lifecycle Repair-Bundle enthaelt jetzt den aktuellen Config-Manager Trust-Anchor; Remote-Repair installiert ihn kanonisch als `/etc/pki/trust/anchors/infrastructure-config-manager.crt` und aktualisiert den System-Truststore.
- P1: Config-Agent-Basisupdate deaktiviert ein vorhandenes `infrastructure-baseline`-Repository robust ueber Alias-Erkennung statt fehlerhafter fester zypper-Spaltenposition. Dadurch blockiert ein defektes Workload-Repo den Agent-Repair nicht mehr.
- P1: Observability-Deploy-Preflight prueft nur gueltige X.509 Trust-Anker und liefert einen eindeutigen erwarteten Pfad bei TLS rc=60.


## 3.18.14
- **P1 Konsolidierung:** HTTPS-Repository-Preflight in `observability-client/install.sh` liefert bei `curl`-Fehlern jetzt garantiert den echten Return-Code zurück; der bisherige `if ! curl ...; rc=$?`-Fehler ist entfernt.
- **Agent Lifecycle:** Update/Repair kann nicht mehr durch ein defektes optionales `infrastructure-baseline`-Repository blockiert werden. Der Config-Agent-Basisschritt deaktiviert dieses Repo temporär, aktualisiert die notwendigen System-Repositories und stellt den vorherigen Repo-Status danach wieder her.
- **Remote Namensauflösung:** Enrollment/Repair prüft Management-FQDNs nicht nur auf irgendeine Auflösung, sondern auf die konfigurierte Manager-IP. Falsche/stale `/etc/hosts`-Zuordnungen für `config-manager.local`, `git.local` und `grafana.local` werden kontrolliert ersetzt.
- **Repository Publishing:** Nach dem Baseline-Repo-Build wird Apache `configtest` + Reload ausgeführt, bevor der HTTPS-Publishing-Test erfolgt.
- **Release Gate:** Zielsystem-End-to-End-Test prüft jetzt zusätzlich `alloy.service`, `prometheus.service`, `observability-ingest.service` sowie Prometheus-Readiness.
- **Regression Suite:** historische UI-/Baseline-Testannahmen wurden auf die aktuelle Architektur aktualisiert; fehlendes PHP-curl im lokalen Test-Runner wird als sauberer SKIP behandelt.

# 3.18.13

Remote-Observability-Deployment und Agent-Lifecycle konsolidiert. Der Config-Manager publiziert das interne Baseline-RPM-Repository als statischen Apache-Pfad mit deaktivierter ModSecurity-Pruefung fuer `/baseline-repo/`; der Repository-Build prueft `repodata/repomd.xml` lokal und ueber HTTPS. `observability-client/install.sh` fuehrt vor `zypper` einen TLS-/Metadata-Preflight mit dem beim Enrollment gepinnten Config-Manager-Zertifikat aus und aktualisiert den lokalen Trust Store. Dadurch werden DNS/TLS/Publishing-Fehler klar vor dem Package-Manager gemeldet. Der Agent-Lifecycle ist aus dem Token/SSH-Dialog herausgeloest: Update, Repair und Reset-to-Defaults sind eigene Lifecycle-Aktionen; Token/SSH bleibt nur fuer Authentisierung/Synchronisation/Rotation. Config Manager 2.32.9.

# 3.18.12

Serververwaltung: Agent Lifecycle aus dem Token/SSH-Dialog herausgeloest. Token/SSH verwaltet nur Authentisierung, Synchronisation und Rotation. Neuer eigener Agent-Lifecycle-Dialog bietet Aktualisieren, Reparieren und bewusst destruktives Zuruecksetzen auf zentrale Defaults. Der alte Force-Schalter im Auth-Dialog ist entfernt; Reset bleibt funktional ueber denselben gehärteten Repair-Pfad erhalten. Config Manager 2.32.8.

# 3.18.11

Config-Agent-Rollout vereinheitlicht: Management-Host und Remote-Clients verwenden jetzt dasselbe `global.json`-Schema und dieselben operativen Defaults fuer Git Deploy/Upload, Path Guards, Backups und Datei-Manager. Nur `listen` und die hostbezogene ACL unterscheiden sich. Der Management-Agent nimmt neben Loopback auch seine eigene Management-IP als `/32` in `allowed_ips` auf. Enrollment und Repair uebertragen den Forgejo-Service-Token separat ueber den gepinnten SSH-Kanal; der Token liegt nicht im Bootstrap-Bundle. Remote-Hosts erhalten bei fehlendem DNS Bootstrap-Eintraege fuer Config Manager, Forgejo und Grafana. Legacy `file_manager_roots` wird beim Rollout entfernt. Config Manager 2.32.7, Config Agent 2.23.6.

# 3.18.10

Config-Agent Deployment-Sandbox korrigiert: Der Agent ist neben File-API auch Package-/Git-Deploy-Executor. Systemd-`ReadOnlyPaths` fuer `/etc/shadow`, `/etc/gshadow`, `/etc/sudoers*`, `/etc/ssh`, `/etc/pam.d`, `/etc/security` und `/etc/ssl/private` wurden aus der Service-Sandbox entfernt, weil sie legitime RPM-Skriptlets und freigegebene `install.sh`-Hooks (z. B. `useradd alloy`) mit `EROFS` blockierten. Der generische Datei-Manager und direkte File-APIs bleiben ueber `HARD_PROTECTED_PATHS` und Scopes fuer diese Pfade hart gesperrt. Agent-eigene Secrets unter `/opt/service/env` und `/opt/service/ssl` bleiben systemd-seitig read-only. Config Agent 2.23.5.

# 3.18.9

Grafana Alloy Service-Account-Reparatur: Der Observability-Konfigurator erkennt jetzt den effektiven `User=`/`Group=` aus `alloy.service`. Fehlen Konto oder Gruppe (systemd `217/USER`), werden sie als Systemkonto angelegt, `/var/lib/alloy` korrekt zugeordnet und erst danach Konfiguration und Runtime mit exakt diesem Serviceuser validiert. Ein Root-Fallback maskiert fehlende Service-Accounts nicht mehr. `client-baseline` ist 1.2.4.

# 3.18.7

Grafana Alloy Runtime-Fix: `client-baseline` 1.2.2 schreibt `/etc/alloy/config.alloy` mit einer fuer den effektiven Alloy-Serviceuser lesbaren Gruppe, validiert die Konfiguration mit dessen Rechten und prueft nach dem Restart mehrere Sekunden den stabilen Servicezustand. Bei Fehlern werden `systemctl status` und die letzten Journalzeilen direkt in den Git-Deploy-Report geschrieben. Die RPM-Postinstallation verschluckt keine produktbezogenen Konfigurationsfehler mehr; die ausfuehrende Logik bleibt in `observability-client/install.sh`.

## 3.18.6
- Datei Manager blendet hart geschuetzte Systempfade und virtuelle Runtime-Dateisysteme bereits in der Verzeichnisliste aus; sie sind weder sichtbar noch les-/schreibbar.
- Firewall-Editor um strukturierten Regeltyp `Port + Quelle` erweitert (IP/Netz + Praefix + Port/Bereich + Protokoll), serverseitig als firewalld Rich Rule umgesetzt.

## 3.18.5 - 2026-09-13

- Fix: Grafana Alloy akzeptiert keine `#`-Kommentare; die package-eigene `config.alloy` verwendet jetzt `//`.
- `client-baseline` wurde auf 1.2.1 angehoben, damit bestehende 1.2.0-Installationen sauber aktualisiert werden.
- Alloy-Konfiguration wird zuerst in einer Temp-Datei erzeugt, mit den echten Ingest-Credentials validiert und erst danach atomar aktiviert. Eine fehlerhafte neue Config ersetzt die letzte funktionierende Datei nicht mehr.
- Der Observability-Installer bleibt bei Fehlern fail-closed und startet `alloy.service` erst nach erfolgreicher Konfigurationsvalidierung.

## 3.18.4 - 2026-09-13

- Datei Manager komplett modernisiert: Browser-Navigation mit Zurueck/Vorwaerts/Hoch, Breadcrumbs, Root-Auswahl, Filter, Ordner-/Dateiansicht, kompakte Metadaten und moderner Editor-Status.
- Browser-`prompt()` fuer Datei anlegen/umbenennen/loeschen durch Bootstrap-Dialoge ersetzt; verwaltete Dateien behalten den expliziten Expert-Override.
- Lese- und Schreibrechte werden in der GUI getrennt dargestellt; bei reinen Lesepfaden ist der Editor sichtbar, aber schreibgeschuetzt.
- Firewall-Regel-Editor auf strukturierte Eingaben umgebaut: Zone, Port/Portbereich, Protokoll, Service, IP/Netzadresse und Praefix werden getrennt erfasst und clientseitig validiert.
- Rich Rules bleiben als bewusst gekennzeichneter Expertenmodus erhalten; eine Vorschau zeigt den an firewalld uebergebenen Wert.

## 3.18.2

## 3.18.3 - 2026-09-13

- Git Deploy: Forgejo Contents-API erzeugt `install.sh` regulaer mit Modus 0644. `post_deploy` akzeptiert deshalb kontrollierte `.sh`-Hooks innerhalb des aktiven Releases bereits bei der argv-Validierung und startet sie explizit ueber `/bin/bash`.
- Der Schutz bleibt erhalten: Hook muss eine regulaere Datei innerhalb des aktiven Releases sein; Symlinks und nicht-Shell-Programme muessen weiterhin executable sein.
- Regressionstest fuer den Erstinstallationsfehler `Programm nicht ausfuehrbar: .../install.sh` ergaenzt.

- `teko/observability-client` enthaelt wieder `install.sh` als expliziten Installations-Executor.
- Git Deploy startet `install.sh` automatisch als `post_deploy` nach Aktivierung des Releases.
- `install.sh` liest `deploy-profile.json`, richtet das interne RPM-Repository ein, installiert/verifiziert die Pakete und startet/validiert die Dienste.
- Der zentrale Deploy-Profileintrag enthaelt nur Repository/Target/Post-Deploy; der Paket-Sollzustand bleibt im Git-Commit.
- Forgejo Contents-API Dateien duerfen fuer kontrollierte `.sh`-Post-Deploy-Hooks via `/bin/bash` ausgefuehrt werden, auch wenn Git den Modus 0644 liefert; Pfad- und Symlink-Schutz bleiben aktiv.

# CHANGELOG

## 3.17.1

- Config-Manager Runtime-Daten behalten konsistent `wwwrun:www`; der Observability-Deploy-Profil-Bootstrap setzt das Datenverzeichnis nicht mehr versehentlich auf `root:wwwrun`.
- `setup_observability.sh` repariert Ownership/Modus von `standalone/data` und `config-manager.env` nach dem Audit-Token-Update explizit.
- Audit REST liefert bei fehlendem Bearer-Token zuerst 401 und prueft erst danach, ob der Export-Token konfiguriert ist. Dadurch wird Konfigurationszustand nicht unauthentisiert offengelegt.
- Behebt die Postinstall-Fehler `Audit REST ... HTTP 503` und `Config Manager data owner root:wwwrun`.

## 3.17.0

- Client Baseline architektonisch auf Host-ID/Config-Agent und lokalen Monit HTTP/XML-Zugang inklusive Credential reduziert.
- Paket-Repository, Paketinstallation und Grafana-Alloy-Konfiguration aus der Baseline-GUI entfernt.
- Neues zentrales Deploy-Profil `observability-client`; wird beim Setup automatisch in `deploy_profiles.json` angelegt.
- Forgejo `teko/config-deploy` erhaelt automatisch `deploy/observability-client/install.sh`, `verify.sh`, README und Manifest.
- Git Deploy installiert ueber das interne RPM-Repository das Meta-Paket `client-baseline` mit Monit, Alloy und `monit-prometheus-exporter`, erzeugt die generische Alloy-Konfiguration und aktiviert die Services.
- `setup_teko_local.sh` installiert den Monit Exporter nicht mehr direkt; Software-Rollout gehoert in Git Deploy.
- Baseline-Status fuehrt keine Alloy-/Repository-Abfragen mehr aus und bleibt dadurch schneller und eindeutiger.


## 3.16.7

- Bootstrap-Repository-Hygiene vor dem ersten globalen `zypper refresh`: ein aus einem frueheren/abgebrochenen Lauf verbliebenes `infrastructure-baseline` blockiert Forgejo, Config Agent und Config Manager nicht mehr.
- Ist `/srv/www/baseline-repo/repodata/repomd.xml` bereits vorhanden, wird die Repository-ID auf dem Management-Server frueh auf `file:///srv/www/baseline-repo/` umgebunden.
- Ist das lokale Repository noch nicht gebaut, wird nur der stale Repository-Eintrag entfernt; nach dem Build richtet `setup_monit_exporter.sh` ihn wieder auf die lokale Quelle ein.
- Damit ist ein FORCE-/Wiederholungslauf auch nach einem frueheren fehlerhaften HTTPS-Repository-Eintrag reproduzierbar.

## 3.16.6

- Management-Server nutzt das eigene Baseline-RPM-Repository lokal via `file:///srv/www/baseline-repo/`; kein HTTPS-Rundweg mehr beim lokalen Setup.
- Remote-Clients verwenden weiterhin `https://<config-manager>/baseline-repo/`.
- Config-Manager-Zertifikat wird lokal als Trust Anchor installiert.
- Repository-Build validiert `repodata/repomd.xml` lokal und prueft das HTTPS-Publishing separat.
- Behebt den Abbruch bei `zypper refresh infrastructure-baseline`, obwohl das Repository lokal korrekt gebaut wurde.


## 3.16.5

- Baseline-Repository-Manifest ist jetzt mit Python 3.6 kompatibel. `subprocess.check_output(..., text=True)` wurde durch `universal_newlines=True` ersetzt, da `text=` erst ab Python 3.7 unterstuetzt wird.
- Behebt den Abbruch nach erfolgreichem `createrepo_c` auf SLES/openSUSE-Systemen mit `/usr/bin/python3` 3.6.
- Regressionstest verhindert, dass der Repository-Builder erneut Python-3.7+-spezifische `subprocess`-Argumente verwendet.





## 3.16.4

- Baseline-Repository-Builder fuer SLES/openSUSE robuster gemacht: `zypper download` kann RPMs im libzypp-Paketcache unter `/var/cache/zypp/packages/` ablegen. Der Builder uebernimmt das heruntergeladene RPM nun anhand der RPM-Metadaten aus dem Cache in das interne Repository.
- Behebt insbesondere Alloy-Downloads wie `/var/cache/zypp/packages/grafana/Packages/alloy-1.19.2-1.amd64.rpm`, bei denen zypper Erfolg meldete, das RPM aber nicht im temporaeren Repository-Verzeichnis lag.
- Abgelaufene Metadaten anderer, fuer den Download nicht benoetigter Distribution-Repositories bleiben eine zypper-Warnung; der erfolgreiche Grafana-/Alloy-Download wird dadurch nicht faelschlich als fehlgeschlagen bewertet.

## 3.16.3

- Datei-Manager und Config-Agent-REST-Pfadmodell konsolidiert: Lesen standardmaessig hostweit, Schreiben in `/etc`, `/opt`, `/srv`, `/var/lib`, `/var/log` und `/usr/local`.
- Config-Agent `allowed_roots` werden beim Setup auf dieselben administrativen Schreibbereiche erweitert, damit GUI und REST-Service nicht widerspruechlich freigeben/blockieren.
- `/etc/systemd/system` ist fuer kontrollierte Datei-Manager-Aenderungen erreichbar; Systemd-Dateien werden als systemkritisch erkannt und verlangen Expert-Override.
- Der systemd-Sandbox des Config Agents blockiert `/etc/systemd/system` nicht mehr pauschal, waehrend Secrets (`/etc/shadow`, sudoers, SSH/PAM/Security, private TLS-Keys, `/opt/service/env`, `/opt/service/ssl`) weiterhin hart gesperrt bleiben.
- Virtuelle Runtime-Dateisysteme `/proc`, `/sys`, `/dev` und `/run` bleiben im Datei-Manager ausgeschlossen.

- Baseline-Repository-Build repariert: `zypper download` wird nicht mehr mit dem nicht portablen `--directory`-Parameter aufgerufen, sondern im Zielverzeichnis ausgefuehrt.
- Der Repository-Builder zeigt jetzt klare Fortschrittsschritte und einen ERR-Handler mit Zeile, Kommando und Exitcode; das Hauptsetup endet nicht mehr kommentarlos.
- Vendor-RPM-Download fuer `monit` und `alloy` wird nach dem Download verifiziert.
- Repository-Manifest markiert einen vollstaendigen Build explizit mit `ready: true`.
- Hauptsetup meldet Repository-Fehler mit konkretem Offline-Hinweis auf `baseline-repository/packages/`.

# 3.16.1

- Generische Baseline-Artefakte von der TEKO-Umgebung getrennt.
- RPM-Repository-ID: `infrastructure-baseline` statt umgebungsspezifischem Namen.
- Meta-Paket: `client-baseline`.
- Monit-Exporter: Paket/Binary/Unit `monit-prometheus-exporter`.
- Exporter-Metriken verwenden den neutralen Prefix `monit_` statt eines Umgebungs-Prefixes.
- Alloy-Drop-in heisst `10-infrastructure-baseline.conf`; Quelle `alloy-baseline.conf`.
- `BASELINE_REPO_URL`, `BASELINE_REPO_DIR` und `BASELINE_REPO_FETCH` sind die generischen Repository-Variablen. Alte `TEKO_BASELINE_*` Variablen werden nur in `teko-stack.conf` als Migrations-Fallback akzeptiert.
- TEKO bleibt Deployment-/Umgebungsprofil (DNS, Hosts, Forgejo-Struktur, lokale Dashboards), nicht Bestandteil generischer RPM-/Service-Namen.

# Changelog

## 3.16.1 - 2026-09-12

- Client Baseline trennt Paketinstallation und Konfiguration strikt.
- Neues internes RPM-Repository `infrastructure-baseline` unter `/baseline-repo/`.
- Neues Meta-Paket `client-baseline` fuer `monit`, `alloy` und `monit-prometheus-exporter`.
- Go Monit Exporter wird nicht mehr durch den Config Agent nach `/usr/local` kopiert; Binary und systemd-Unit gehoeren dem RPM.
- Alloy wird nicht mehr direkt aus `rpm.grafana.com` auf Clients installiert. Externe Quellen werden nur beim Repository-Build gespiegelt.
- Neue Repository-Werkzeuge `setup_baseline_repository.sh`, `baseline-repository/scripts/prepare_repository.sh` und `baseline-repository/install.sh`.
- Config Manager zeigt Repository-/Meta-Paket-Status und einen einzigen asynchronen Paketjob fuer die gesamte Baseline.
- Monit/Alloy Baseline bleibt fuer Konfiguration, Secrets, Service-Aktivierung und Healthchecks verantwortlich.

## 3.15.2 - 2026-09-12

- Monit/Exporter-Authentisierung im Setup vereinheitlicht: Monit, Config Agent und Go Exporter verwenden jetzt denselben Credential-Satz aus `/var/lib/service/config-agent/secrets/monit-status.env`.
- Frische Installationen erzeugen einmalig ein lokales starkes Monit-Passwort; vorhandene Baseline-Credentials bleiben erhalten.
- `monit-prometheus-exporter.service` hat jetzt genau einen autoritativen Unit-Pfad unter `/etc/systemd/system`. Eine alte parallele Unit unter `/usr/lib/systemd/system` wird entfernt.
- Setup-Abbruch mit `monit_up 0` / HTTP 401 nach der Exporter-Installation behoben.
- Exporter-Setup erfindet keine zweite Credential-Konfiguration mehr, sondern verlangt das zuvor erzeugte gemeinsame Monit-Secret.

## 3.15.1 - 2026-09-12

- Grafana-Alloy-Installation auf asynchronen Baseline-Job umgestellt: HTTP-Request kehrt sofort mit Job-ID zurueck, Fortschritt wird separat gepollt.
- Baseline-UI zeigt echte Installationsschritte und blockiert nicht mehr waehrend zypper/RPM-Operationen.
- Go Monit XML Exporter ist jetzt Bestandteil der generischen Client-Baseline und wird mit Monit/Alloy bereitgestellt.
- Alloy scrapt zusaetzlich `127.0.0.1:9108/metrics` und sendet die Monit-Metriken zusammen mit den Systemmetriken an Prometheus.
- Monit- und Alloy-Karten dokumentieren sichtbar, welche Pakete, Dateien, Services, Secrets und Datenpfade die Baseline erzeugt.
- Alloy-Installieren speichert zuerst die sichtbare Basiskonfiguration (Loki/Prometheus), danach validiert und aktiviert der Hintergrundjob Alloy.
- Monit Exporter verwendet den bestehenden Monit-Secret-Store; kein zweites Monit-Passwort notwendig.

## 3.15.0 - 2026-09-12

- Architektur-Konsolidierung: Control Plane und Observability Data Plane getrennt. Alloy sendet ueber den separaten `observability-ingest.service`; Config-Manager-PHP transportiert keine neuen Telemetrie-Payloads mehr.
- Baseline-Secret-Store nach `/var/lib/service/config-agent/secrets/` verschoben. Das behebt `Read-only file system` unter der Agent-Sandbox; `/opt/service/env` bleibt bewusst read-only.
- Stabile `host_id` plus Labels/Groups fuer Enrollment, Agent-Identitaet und Alloy-Telemetrie eingefuehrt.
- File Manager erkennt Baseline-, Managed-Config- und Git-Deploy-Ownership und verlangt fuer direkte Aenderungen einen Expert-Override.
- Config-Agent Capability-Scopes eingefuehrt.
- `VERSIONS.json` als zentrale Versions-Source-of-Truth mit `bin/sync-versions.py`.
- Client Baseline bleibt strikt auf Config Agent, Monit und Grafana Alloy begrenzt.

## 3.14.3 - 2026-09-12

- Monit-Baseline: HTTP-Basic-Auth-Passwort wird in der Monit-Konfiguration immer als String gequotet. Rein numerische Passwoerter werden damit nicht mehr als Zahl/token interpretiert und bestehen `monit -t`.
- Baseline-Status beschleunigt: normale Statusabfragen fuehren keine zypper/apt/dnf Repository-Suchen mehr aus. Paketquellen werden erst bei einer Installationsaktion geprueft.
- Baseline-UI kennzeichnet den schnellen Status als "Installation wird bei Bedarf geprueft" statt eine langsame Paketquellenpruefung bei jedem Laden auszufuehren.

## 3.14.2 - 2026-09-12

- Globaler Ladeindikator aus der rechten unteren Ecke in den oberen Inhaltsbereich verschoben.
- Busy-Tracking mit `Promise.finally()`, XHR-`loadend` und per-Request-Failsafe gegen haengende Spinner abgesichert.
- Baseline-Status setzt nach abgeschlossener Initialladung verwaiste Busy-Zustaende explizit zurueck.
- Cache-Buster fuer Feedback-JavaScript und Portal-CSS aktualisiert.

## 3.14.0 - 2026-09-12
- Monit Credential-Flow transparent gemacht: Passwort wird als lokales Client-Secret unter `/opt/service/env/monit-status.env` gespeichert (0600).
- Config Agent verwendet das gespeicherte Monit-Credential automatisch für den lokalen XML-Statuszugriff.
- Client Baseline zeigt Credential-Status, Speicherort und bietet einen expliziten Verbindungstest.
- Leeres Passwort beim späteren Speichern behält das vorhandene Secret bei; neues Passwort dient zur Rotation.
- Config Manager 2.28.0; Config Agent 2.19.5.

## 3.13.9 - 2026-09-12

- Portalweiter Ladeindikator fuer API-, Agent- und Service-Aufrufe eingefuehrt.
- `fetch`, `XMLHttpRequest`, klassische Form-Aktionen und interne Seitenwechsel liefern nun einheitliches sichtbares Busy-Feedback.
- Kurze Requests werden mit 180 ms Verzoegerung gefiltert, damit die GUI nicht flackert.
- Der Loader arbeitet referenzgezaehlt, sodass parallele Requests korrekt behandelt werden.
- Spezialmodule koennen den globalen Loader bei Bedarf explizit deaktivieren oder mit eigenem Meldungstext versehen.
- BFCache/Zurueck-Navigation setzt den Ladezustand sicher zurueck.

# Changelog

## 3.13.7 - 2026-09-12

- Host-Lifecycle architektonisch gebündelt: **Managed Hosts** ist der einzige Hauptmenüpunkt für Übersicht, Enrollment, Baseline und Registry.
- Die bisherigen Hauptmenüpunkte Agent Enrollment, Serververwaltung und Client Baseline wurden aus der Sidebar entfernt und als Tabs innerhalb von Managed Hosts weitergeführt.
- Neuer Managed-Hosts-Überblick mit Host-Lifecycle: Enrollment → Baseline → Konfiguration → Server Health.
- **Monit Status** in **Server Health** umbenannt; die Seite bleibt reine Überwachung. Monit wird lokal über den Config Agent ausgelesen und muss nicht auf Port 2812 für den Config Manager exponiert werden.
- Package Management dem Bereich **Server Management** zugeordnet.
- Baseline-Deep-Link kann einen Zielserver vorauswählen.
- Config Manager Standalone 2.27.7; Config Agent unverändert 2.19.4.

## 3.13.6 - 2026-09-12

- Neue **Client Baseline**: Config Agent + Monit + Grafana Alloy als generische Management-/Observability-Schicht pro Server.
- Monit kann pro Server installiert und mit Bind-Adresse, Port, Benutzer und Passwort grundkonfiguriert werden; localhost bleibt fuer Agent/Exporter erlaubt.
- Grafana Alloy kann pro Server installiert und mit Loki-/Prometheus-Endpunkten grundkonfiguriert werden.
- Workloads wie Apache, Postfix, Rspamd, Redis und ModSecurity bleiben bewusst ausserhalb der generischen Baseline und werden ueber Git/Managed Configs gepflegt.
- Neuer geschuetzter **Datei Manager** mit serverseitigen Root-Whitelists, Symlink-Schutz, Hard-Path-Schutz, atomischem Schreiben und Backup vor Ueberschreiben.
- Default-Observability auf dem Management-Server um zentralen Prometheus-Container und Grafana-Prometheus-Datasource erweitert.
- Forgejo Bootstrap erzeugt Baseline-/Rollen-Scaffolds fuer `generic-linux`, `mailserver` und `webserver`.
- Config Manager Standalone 2.27.6; Config Agent 2.19.4.

## 3.13.5 - 2026-09-12

- Fail2ban-Verwaltung von drei festen Web-Jails auf eine generische serverbezogene Jail-Verwaltung umgebaut.
- Vorlagen fuer SSH, Apache Auth, Nginx Auth, Postfix SASL, Dovecot, Recidive, ModSecurity, Web Scanner und Custom.
- Pro Jail frei verwaltbar: Filter, Backend, Port, Logpfad, Action, MaxRetry, FindTime, BanTime sowie Aktivstatus.
- Eigene Failregex/Ignoreregex mit automatisch erzeugten `cm-managed-*`-Filtern; Failregex muss `<HOST>` enthalten.
- GUI in Jails, Filter, Gebannte IPs und Globale Einstellungen gegliedert.
- Bestehende aktive Jails werden weiterhin live ueber `fail2ban-client status` angezeigt und koennen entsperrt werden.
- Serverseitige Validierung, `fail2ban-client -t`, atomisches Schreiben und Rollback bleiben erhalten.
- Config Manager Standalone 2.27.5; Config Agent 2.19.3.

## 3.13.4 - 2026-09-12

- Monit Status wieder strikt auf Monitoring reduziert.
- Security- und Paket-Aktionsbuttons aus der Server-Detailansicht entfernt.
- Firewall und Fail2ban bleiben ausschliesslich unter SECURITY verwaltbar.
- Config Manager Standalone 2.27.4; Config Agent unverändert 2.19.2.

## 3.13.3 - 2026-09-12

- Security Policies removed from the Config Manager UI and obsolete policy page removed.
- Firewall is now a per-server management module with live firewalld zone/rule inventory, install support and add/remove operations for ports, services, sources and rich rules.
- Fail2ban is now always managed directly per server; policy locking and policy references removed.
- Monit server details now provide direct per-host actions for Firewall and Fail2ban.
- Server selection is carried into Firewall/Fail2ban pages through the URL.
- Config Manager Standalone 2.27.3; Config Agent 2.19.2.

## 3.13.2 - 2026-09-12

- Deploy-Profile sind jetzt zentral im Config Manager gespeichert und nicht mehr an einen Zielserver gekoppelt.
- Vor Compare, Deploy und Desired-State-Prüfung wird der zentrale Profilkatalog nur bei Abweichung auf den Zielagenten synchronisiert.
- Bestehende Profile werden beim ersten Aufruf einmalig von einem erreichbaren Agenten in den zentralen Katalog migriert.
- Deploy-Profile-Editor ohne sichtbare Zielserver-Auswahl; Repository-Assistent nutzt weiterhin transparent einen erreichbaren Agenten.
- Zentrale Backups/Restore für Deploy-Profile; Desired State bezieht seinen Deployment-Katalog direkt aus den zentralen Profilen.
- Config Manager Standalone 2.27.2; Config Agent 2.19.1.

## 3.13.1 - 2026-09-12

### Security Scope / Installationsstatus
- Zentrale Security Policies klar auf **Firewall** und **Fail2ban** begrenzt.
- **ModSecurity / OWASP CRS** bleibt lokal auf dem Webserver und wird nicht als zentrale Policy angeboten.
- Lokale Fail2ban-Seite erkennt zugewiesene zentrale Fail2ban-Policies und sperrt in diesem Fall lokale Konfigurationsaenderungen.
- Fail2ban zeigt Paketverfuegbarkeit und Installationsmoeglichkeit an.
- Firewall-Agent um `firewalld`-Paketstatus und kontrollierte Installation erweitert.
- Firewall-Policy-Apply installiert fehlendes `firewalld` vor dem Apply; Preview zeigt fehlende bzw. nicht verfuegbare Abhaengigkeiten an.
- ModSecurity-UI kennzeichnet die Komponente als lokal und deaktiviert den Installationsbutton nach erfolgreicher Erkennung.
- Config Manager Standalone 2.27.1; Config Agent 2.19.1.

## 3.13.0 - 2026-09-12

### Security Policies neu aufgebaut
- Security Policies folgen jetzt dem klaren Modell **Policy erstellen → Zuweisen → Vorschau → Anwenden → Compliance**.
- Firewall-Policies und Fail2ban-Policies sind persistente Objekte statt nur einmaliger Fleet-Aktionen.
- Firewall-Regelbuilder fuer Port, Protokoll, optionale Quelle/CIDR und Beschreibung.
- Fail2ban-Policybuilder fuer Standard-Jails, Allowlist sowie eigene `cm-custom-*` Jails.
- Eigene Fail2ban-Jails unterstuetzen lokale Apache Access-/Error-Logs, `maxretry`, `findtime`, `bantime` und eine kontrollierte Failregex mit verpflichtendem `<HOST>`.
- Policies koennen einzelnen Servern, allen Agent-Servern oder einer Servergruppe zugewiesen werden.
- Zuweisungs-/Compliance-Sicht zeigt Zielserver und aktiven Dienststatus.
- Policy-Vorschau vor dem Rollout; Fleet-Apply bleibt auditiert.
- Policy-Datei `standalone/data/security_policies.json` wird bei Updates erhalten.
- Config Agent erweitert Fail2ban um eigene verwaltete Jail-/Filterdefinitionen.

## 3.12.0 - 2026-09-12

- Desired State UX neu geordnet: ein zentraler Navigationspunkt statt separatem Fleet- und Editor-Menü.
- Bedienmodell auf Baseline → Zuweisung → Abweichung vereinfacht.
- Bestehendes Backend-/Policy-Format bleibt kompatibel; kein Migrationszwang.
- Baseline-Editor zeigt den Normalfall zuerst und verschiebt Canary/Max-Targets/JSON in erweiterte Bereiche.
- Config-Manager-Sollzustand nutzt standardmässig dieselbe stabile Config-ID auf den Zielservern; abweichendes Mapping ist nur bei Bedarf sichtbar.
- Compliance-Seite verwendet konsistente Begriffe Baseline und Abweichung.

## 3.11.0 - 2026-09-12

### Security Policies / Fleet Hardening
- Neue zentrale Seite **Security Policies** fuer Fail2ban und Host-Firewall ueber alle registrierten Agent-Server.
- Zielserver koennen einzeln oder nach Servergruppe gefiltert und gemeinsam verwaltet werden.
- Fleet-Status zeigt Erreichbarkeit, Fail2ban-Status/Jails sowie Firewall-Backend und Dienststatus.
- Fail2ban Baseline kann fleet-weit ausgerollt werden; fehlendes Fail2ban wird auf Zielservern zuerst installiert.
- openSUSE/SLES: bekannter `busybox-ed`/`ed`-Konflikt bei Fail2ban wird kontrolliert aufgeloest.
- Neue Firewall-Agent-API fuer Inventar, Vorschau und Apply.
- Firewall V1 arbeitet absichtlich additiv: vorhandene Regeln werden nicht geloescht und keine Default-DROP-Policy wird automatisch gesetzt.
- Firewall-Policy unterstuetzt Port/Protokoll, optionale Quellnetze und firewalld-Zonen.
- Fleet-Aktionen werden im zentralen Audit protokolliert.

# 3.10.1

- Fix: Fail2ban GUI white page caused by an invalid sidebar include path.
- Fail2ban page now loads the standard navigation/sidebar layout correctly.
- Added an executable page-render regression test to catch missing UI includes before release.

## 3.10.0

- Neues Security-Modul **Fail2ban** für den Web-/Portal-Schutz.
- Serverzentrierte Installation und Statusanzeige über den Config Agent.
- Verwaltete Jails für wiederholte Apache 401/403, typische Web-Scanner und ModSecurity-Blocking.
- ModSecurity-Jail reagiert absichtlich nur auf `Access denied`, nicht auf DetectionOnly-Warnungen.
- GUI für Allowlist, Retry-/Zeitfenster-/Ban-Werte und aktuell gebannte IPs.
- Gebannte IPs können kontrolliert und auditierbar aus dem Portal entsperrt werden.
- Vor Aktivierung erfolgt `fail2ban-client -t`; bei Fehler werden Konfiguration und Filter automatisch zurückgerollt.
- Config Manager Standalone 2.24.0; Config Agent 2.17.0.

## 3.9.0

- Package Management um serverzentriertes Inventar erweitert.
- Installierte Pakete zeigen Version, Architektur und verfügbare Updates.
- OS und Paketmanager werden im Inventar zusammengefasst.
- Neuer Fleet-Vergleich für ein Paket über alle registrierten Server.
- Update-Erkennung für zypper, apt und dnf im Config Agent.
- Config Manager Standalone 2.23.1; Config Agent 2.16.0.

## 3.8.0

- Desired State: Config-Manager-Quelle auf echte Managed-Config-Objekte umgestellt.
- Source/Target-Config-Auswahl mit Katalog, Metadaten und Same-ID-Standard.
- Server-seitige Objekt-Referenzvalidierung ergänzt.
- Config Manager: Löschen/Umbenennen referenzierter Config-IDs wird blockiert.
- Neue Regression `config_object_reference_guard_test.py`.
- Config Manager Standalone 2.22.0; Config Agent 2.16.0.

## 3.7.0

- Desired State Editor deutlich vereinfacht: Zielserver-Auswahl jetzt ueber klare Modi **Alle Server**, **Nach Gruppen**, **Nach Labels** und **Erweitert**.
- Gruppen werden im einfachen Modus als anklickbare Chips dargestellt; mehrere Gruppen bedeuten standardmaessig ODER.
- Labels werden als vorhandene `key=value`-Chips dargestellt; Mehrfachauswahl wird als UND ausgewertet.
- Live-Vorschau der passenden Server bleibt direkt sichtbar; komplexe alte Policies werden automatisch im erweiterten Modus geoeffnet.
- Bestehendes Desired-State-Schema bleibt kompatibel; keine Migration der gespeicherten Policies notwendig.
- Config Manager Standalone 2.21.0; Config Agent 2.16.0.

## 3.6.5

- Desired State Editor: Gruppen-Selector mit explizitem ODER/UND-Modus.
- Neue Policies verwenden `group_match=any`; Legacy-Policies bleiben bei `all`.
- Zielserver-Vorschau und Nulltreffer-Hinweis verständlicher gestaltet.
- Config Manager Standalone 2.20.4.

## 3.6.4

- Deploy-Profile Toolbar nochmals vereinfacht.
- `Profile laden` ist wieder eine direkte Hauptaktion neben Neu, Validieren und Speichern.
- Die zusätzlichen Server/Profile/Status-Kacheln wurden entfernt; der Zielserver bleibt die einzige Kontextanzeige in der Toolbar.
- `Weitere Aktionen` enthält nur noch seltene Funktionen wie Serverliste aktualisieren, Repository-Assistent und erweiterte Optionen.
- Responsive Toolbar-Layout nachgeschärft.
- Config Manager Standalone 2.20.3; Config Agent 2.16.0.

## 3.6.3

- Deploy-Profile: kompakte Server/Profile/Status-Kontextleiste.
- Speichern ist nur bei ungespeicherten Änderungen aktiv und zeigt sonst Gespeichert.
- Profilkopf auf kompaktes Statusband plus Kebab-Aktionsmenü reduziert.
- Profilliste blendet leere Persistenz-Badges aus.
- Responsive Toolbar weiter bereinigt.

# 3.6.3

- Deploy-Profile Toolbar neu ausgerichtet: Zielserver links, Hauptaktionen rechts, keine grossen Leerflaechen.
- Profilkopf entschlackt: Status-Badges bleiben sichtbar, Duplizieren/Loeschen liegen unter einem klaren Aktionen-Menue.
- Responsive Verhalten der Deploy-Profile-Seite korrigiert.

## 3.6.1

- Deploy-Profile UI vereinfacht: Hauptworkflow ist jetzt „Neues Profil → Validieren → Speichern“.
- Seltene Aktionen wurden in „Weitere Aktionen“ verschoben (Profile neu laden, Serverliste aktualisieren, Repository-Assistent, erweiterte Optionen).
- Profilkopf zeigt explizit Aktiv/Inaktiv, Einfach/Erweitert sowie Gespeichert/Ungespeichert.
- Duplizieren und Löschen sind beschriftet statt als unklare Icon-Buttons dargestellt.
- Texte für Server, Laden und leere Zustände wurden verständlicher formuliert.
- Config Manager Standalone 2.20.1; Config Agent 2.16.0.

## 3.6.0

- Git Deploy komplett auf einen geführten 4-Schritt-Workflow umgestellt: Ziel wählen -> Version wählen -> Änderungen prüfen -> Deploy.
- Neue Bereichsnavigation `Deploy`, `Verlauf / Ergebnisse`, `Restore`; Restore ist nicht mehr im Hauptworkflow im Weg.
- Dynamische Next-Action-Anzeige zeigt jederzeit den nächsten notwendigen Schritt und den aktuellen Sperrgrund.
- Zielserverliste visuell reduziert: Agent-Version und Token sind Sekundärinformationen statt eigene dominante Spalten.
- Deployment-Profil-Details als kompakte Karten statt breiter technischer Tabelle; technische Pfade bleiben aufklappbar verfügbar.
- Deployment-Ergebnisse bzw. Statusabfragen wechseln automatisch in den Verlauf-Tab.
- Bestehende Sicherheitslogik bleibt unverändert: Diff-Pflicht, explizite Bestätigung, Token-Prüfung, Preflight, Healthcheck und Rollback.
- Neuer Regressionstest `git_deploy_guided_ux_test.py` schützt den geführten Workflow.
- Config Manager Standalone 2.20.0; Config Agent 2.16.0.

## 3.5.2

- ModSecurity Security-Events: Status **getunt** wird jetzt robust aus aktiven CM-FP-Ausnahmen ermittelt.
- Neue stabile CM-FP-MATCH-Metadaten (Rule, Host, URI, Methode, Target); bestehende 3.5.x-Ausnahmen werden per Legacy-Parser weiterhin erkannt.
- Host/URI werden für den Statusvergleich normalisiert; mehrere identische Loki-Treffer desselben Endpoints wechseln gemeinsam auf getunt.


## 3.5.1
- Security Events zeigt nur noch konkrete CRS-Ursachen; 949110/980170 und andere Summary-/Anomaly-Regeln werden als technischer Kontext korreliert und aus der Hauptliste ausgeblendet.
- ModSecurity Message-/Apache-Error-Duplikate werden vor der Korrelation um Host, URI und unique_id ergänzt.
- Status `getunt` wird ausschliesslich gegen aktive, passend gescopte Custom-Ausnahmen ermittelt und nach Aktivierung sofort neu berechnet.
- Top Rule/Top Typ und Event-Zähler berücksichtigen nur noch konkrete, verwertbare CRS-Ursachen.
# 3.5.0

- Setup kann Server-, Forgejo-, Config-Manager- und Grafana-FQDN sowie Config-Agent-Port interaktiv setzen; Defaults bleiben unveraendert.
- Werte werden root-only in `/etc/local-infrastructure-stack.conf` gespeichert und von allen Setup-Komponenten zentral verwendet.
- Sichtbare Produktbezeichnung auf `Local Infrastructure Stack` neutralisiert; `teko.local` bleibt Default/Legacy-Kompatibilitaet.
- Automatisch erzeugte WAF-Ausnahmen erhalten Status- und Validierungsmetadaten.
- Security Events zeigen Top-Rule/Top-Typ zur schnelleren False-Positive-Analyse.

# 3.4.2

- ModSecurity Auto Rule Builder repariert: generierte Regeln verwenden echte Zeilenumbrüche statt literaler `\n`-Sequenzen.
- Aktivierung hängt Custom Rules nun mit echten Zeilenumbrüchen an.
- Fehler beim automatischen Rule-Build werden direkt im Scope-Bereich angezeigt und nicht mehr versteckt.
- Auswahl eines Loki-Events zeigt Build-Fehler sichtbar; Auto-Build bleibt aktiv.
- Pflichtfeld-Hinweis ist dynamisch und zeigt nur tatsächlich fehlende Felder.
- Statischer Warntext wurde durch ein neutrales Sicherheitsprinzip ersetzt.
- Builder-Buttons sind explizit `type=button`; geänderte Scope-Felder invalidieren eine alte Vorschau.
- Neuer Regressionstest für Rule-Builder/Zeilenumbrüche.

## 3.4.1

- ModSecurity Security Events: CRS summary/correlation rules such as 980170 and 949110 are no longer used directly as false-positive tuning targets.
- Events are correlated by ModSecurity unique_id and the concrete root-cause rule is selected automatically.
- Automatic Rule Builder now shows an explicit build state and uses the concrete rule when a summary event is selected.
- False-positive metadata marker changed from TEKO-FP to neutral CM-FP; existing TEKO-FP entries remain readable.

# 3.4.0

## Workflow-first ModSecurity Tuning / Auto Rule Builder

- Security Events sind jetzt die primäre ModSecurity-Ansicht.
- Serverseitiger Rule Builder erzeugt Ausnahmen automatisch und wählt den engsten unterstützten Scope.
- Target-Ausnahmen werden bevorzugt; Endpoint-Ausnahmen sind der sichere Fallback.
- Ein-Klick-Aktivierung nutzt bestehenden Configtest-/Reload-/Rollback-Pfad.
- Runtime-Details kompakt/einklappbar; Raw Custom Rules in separatem Expertenmodus.
- Neue serverseitige Eingabevalidierung und kollisionsfreie TEKO Rule-ID-Vergabe.
- Config Manager Standalone 2.19.0; Config-Agent 2.16.0.

# 3.2.0

## ModSecurity False-Positive Management / UI Refresh

- ModSecurity-Oberflaeche visuell neu strukturiert und fuer technische Administration verdichtet.
- Neuer False-Positive-Assistent: Loki-/ModSecurity-Event einfuegen, Rule-ID/Host/URI/Target analysieren, Ausnahme generieren, Scope pruefen und kontrolliert speichern.
- Assistent erzeugt keine globalen CRS-Deaktivierungen; Host und URI sind Pflicht.
- Robuste Endpoint-Ausnahmen als Standard, optionale Target-Ausnahme fuer engere Advanced-Faelle.
- Automatische TEKO-Rule-IDs, Vorschau, Risikohinweis und Uebersicht erkannter TEKO-Ausnahmen.
- Raw Custom Rules bleiben als Expertenmodus erhalten.
- Configtest, Apache Reload und automatischer Rollback bleiben unveraendert aktiv.
- Config Manager Standalone 2.17.0; Config-Agent 2.16.0.

# 3.1.1

## UI/UX Maintenance

- Service-Journal verwendet ein einziges wiederverwendbares, breiteres Log-Fenster statt pro Aufruf ein neues Fenster zu öffnen.
- Git Repository Browser standardmässig mit breitem Zwei-Spalten-Layout; Historie wird nur bei Bedarf eingeblendet.
- Repository-Dateien werden mit dem bereits offline gebündelten CodeMirror/Ace-kompatiblen Editor angezeigt und bearbeitet, inklusive Zeilennummern, Syntaxmodus und Cursorposition.
- Keine externen Frontend-Abhängigkeiten hinzugefügt.

# 3.1.0

- Stabilisation Release ohne neue Funktionsbereiche.
- Vollstaendige Testmatrix konsolidiert: widerspruechliche Alt-Regressionen an die aktuelle Fleet-/Force-Semantik angepasst.
- Lokaler Agent-Token verwendet nun durchgaengig den kanonischen Pfad `/opt/service/config-manager/tokens/<server>.token`; `local-agent.token` bleibt nur noch als Legacy-Migrationsquelle relevant.
- ModSecurity-Dateipfade fuer Mode-Override und Custom-Rules-Include zentral im Profil verdrahtet; Rollback-/Sandbox-Pfade sind dadurch reproduzierbar und testbar.
- Git-Deploy Asset-Versionen/Testvertrag synchronisiert; Erstinstallations-/Diff-UX bleibt unveraendert.
- Neuer reproduzierbarer Volltest `tools/run-all-tests.sh` mit Einzeltest-Matrix plus Sandbox-End-to-End-Harness.
- Release-Metadaten, Checksummen und Clean-Package neu erzeugt.

# 3.0.44

- Neuer **Git Repository Browser** im Deployment-Bereich.
- Repository, Branch und Verzeichnisbaum direkt im Config Manager durchsuchen.
- Textdateien bis 2 MiB direkt anzeigen; Binärdateien werden sicher nur als Metadaten dargestellt.
- Commit-Historie pro Repository bzw. ausgewählter Datei anzeigen.
- Änderungen eines Commits als Dateiübersicht und Patch/Diff anzeigen.
- Beschreibbare Repositorys können Textdateien direkt im Browser bearbeiten und mit Commit-Nachricht nach Forgejo committen.
- Schreibzugriff verwendet weiterhin die bestehende Git-Upload-/Forgejo-Berechtigung; Read-only Browsing funktioniert mit Leserecht.
- Datei-Edits werden im Auditlog als `git_repository_file_edit` protokolliert.

## 3.0.43

- Git Deploy: Deploy-Button zeigt nun den konkreten Blockiergrund direkt neben der Aktion.
- Eine fehlende Diff-Vorschau wird explizit als Pflicht-Preflight angezeigt; der Sicherheitscheck bleibt bestehen.
- Ein Ziel ohne `active_commit`, aber mit gültigem Repository-Commit wird als `Erstinstallation` dargestellt statt als `Installiert unbekannt`.

## 3.0.42

- Remote-Agent TLS-Identitaet wird bei Token-Sync, Repair und Rotation ueber den gepinnten SSH-Kanal mit dem Manager synchronisiert.
- Normale Remote-Agent-Updates behalten bestehende TLS-Zertifikate; Force darf sie bewusst neu erzeugen.
- Manager aktualisiert CA-Datei und Server-Registry atomar, bevor `/health` geprueft wird.
- Behebt `CERTIFICATE_VERIFY_FAILED` nach erfolgreichem Agent-Repair/Token-Sync.

## 3.0.41 - 2026-09-11

- Serververwaltung: Authentifizierung, API-Erreichbarkeit und Agent-Health werden getrennt bewertet.
- Repair/Token-Rotation behaupten bei nicht verifizierter API nicht mehr faelschlich "Authentifizierung ist OK".
- HTTP 503 bleibt korrekt "Auth OK / Health degradiert"; 401/403 werden als Auth-Fehler und Transport/TLS-Fehler als "nicht verifiziert" dargestellt.
- Config Manager Standalone 2.14.6.


## 3.0.40 - 2026-09-11
- Fix: Remote-Agent-Repair-Bundle-Preflight ist jetzt `pipefail`-sicher.
- Ursache: `tar -tzf ... | grep -q` konnte bei vorhandenem Treffer wegen SIGPIPE von `tar` faelschlich als Fehler ausgewertet werden.
- Der Bundle-Inhalt wird einmal in eine temporaere Liste geschrieben und danach ohne Pipeline validiert.
- Regressionstest fuer den False-Negative-Preflight hinzugefuegt.

## Remote-Agent Default & Force Update

- Neue Remote-Agenten verwalten standardmaessig nur `config-agent-global`; Manager-spezifische Apache-, Grafana-, Postfix- und Git-Deploy-Eintraege werden nicht automatisch uebernommen.
- Normales `Agent reparieren / aktualisieren` aktualisiert den Agent-Code, behaelt aber vorhandene Remote-Einstellungen und `managed_configs.json`.
- Neuer Force-Schalter in Serververwaltung > Token / SSH: setzt Remote-Agent-Konfigurationen auf Paketstand zurueck und `managed_configs.json` bewusst auf den Remote-Default `config-agent-global`.
- Enrollment setzt das Remote-Profil bei der Erstinstallation explizit neu.
## 3.0.39 - 2026-09-11

- Remote-Agent Repair-Bundle enthaelt jetzt zwingend `teko-stack.conf`; `setup_config_agent.sh` kann damit auf dem Zielhost wieder korrekt starten.
- Das erzeugte Repair-Archiv wird vor der Installation auf alle Pflichtdateien validiert.
- Der Remote-Repair prueft nach dem Entpacken erneut `setup_remote_config_agent.sh`, `setup_config_agent.sh`, `teko-stack.conf` und `config-agent/VERSION` und bricht mit einer klaren Meldung ab, bevor Einstellungen veraendert werden.
- Config Manager Standalone 2.14.5; Config-Agent bleibt 2.15.5.

## 3.0.38 - 2026-09-11

- Remote-Agent Repair/Update direkt in der Serververwaltung ueber den bestehenden SSH-Recovery-Kanal ergaenzt.
- Der Manager erzeugt bei Setup ein root-only Repair-Bundle mit dem aktuellen Config-Agent-Code und den Remote-Setup-Skripten.
- Remote-Repair aktualisiert Agent-Code, Remote-Profil und Token in einem kontrollierten Ablauf und prueft danach `/health`.
- Remote `managed_configs.json` wird auf Agent-Core plus lokal tatsaechlich vorhandene Konfigurationsdateien reduziert; zentrale Apache/Grafana/Postfix-Eintraege werden nicht blind vererbt.
- Remote Git Upload/Deploy bleibt ohne explizit provisionierten Forgejo-Token deaktiviert.
- Config Manager Standalone 2.14.4; Config-Agent 2.15.5.

## 3.0.36 - 2026-09-11

- Remote-Agent Health konsolidiert: nicht vorhandene optionale Managed Configs werden nicht mehr als Security-Verstoss fehlklassifiziert.
- Registry-Validierung trennt deklarative Pfadpruefung vom fail-closed Runtime-Path-Guard; echte Schutzpfade wie `/etc/shadow`, `/etc/ssh` und `/etc/systemd/system` bleiben gesperrt.
- Remote-Enrollment markiert nur die Config-Agent-Core-Dateien als zwingend; weitere Stack-Configs bleiben verwaltbar, werden bis zur lokalen Installation aber als optional behandelt.
- Git Upload/Deploy werden auf frisch enrolten Remote-Agenten ohne explizite Forgejo-Token-Provisionierung deaktiviert; fehlender `/opt/service/env/forgejo-api.token` erzeugt dadurch keinen falschen 503-Health-Fehler mehr.
- `forgejo-api.token` ist nicht mehr unconditional `required_file` der Config-Agent-Analyse, da Git-Funktionen optional sind.
- Config-Agent auf 2.15.3 angehoben.
- Token-Lifecycle trennt Authentifizierung von Agent-Health: ein authentifizierter HTTP 503 ist kein Tokenfehler und loest bei Sync/Rotation keinen falschen Rollback mehr aus.
- Serververwaltung zeigt bei degradiertem `/health` die konkreten Agent-Health-Fehler direkt im Token-Dialog.
- Config Manager Standalone auf 2.14.2 angehoben.

## 3.0.35 - 2026-09-11

- Agent-Tokenverwaltung vereinheitlicht: alle Manager-seitigen Agent-Tokens liegen kanonisch unter `/opt/service/config-manager/tokens/<server>.token`.
- Bestehende Registry-Eintraege und Legacy-Tokens aus `/opt/service/config-manager/tokens` bzw. `local-agent.token` werden beim Setup automatisch und atomar migriert.
- Ein fehlender/ungueltiger Token eines Remote-Agents degradiert nur diesen Server und blockiert nicht mehr das gesamte Config-Manager-Portal.
- Enrollment, Remote-Setup und Token-Lifecycle verwenden dieselbe Token-Pfadkonvention.
- Config Manager Standalone auf 2.14.1 angehoben.

## 3.0.34 - 2026-09-11

- Serververwaltung um Agent-Token-Lifecycle erweitert: Token pruefen, via SSH synchronisieren und sicher rotieren.
- Token-Pruefung validiert token_file, Dateirechte/Fingerprint und fuehrt einen echten Config-Agent `/health`-API-Test aus.
- SSH-Synchronisierung liest `CONFIG_AGENT_API_TOKEN` direkt vom Agent und repariert die Manager-Token-Datei atomar mit `root:www 0640`.
- Token-Rotation erzeugt remote einen neuen Token, startet den Config-Agent neu, aktualisiert den Manager und prueft danach `/health`; bei fehlgeschlagenem API-Test wird ein Rollback versucht.
- SSH-Zugangsdaten koennen pro Aktion als Passwort oder Manager-Key angegeben werden. Passwoerter werden weder in Registry noch Auditlog gespeichert. Host-Key-Pruefung bleibt strikt ueber das Enrollment-known_hosts aktiv.
- Config Manager Standalone auf 2.14.0 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.32 - 2026-09-11

- Agent Enrollment: Job-Loeschung wird jetzt sicher ueber eine web-schreibbare Control-Queue an den Root-Worker delegiert; Status-/Work-Verzeichnisse bleiben nicht web-schreibbar.
- Agent Enrollment: offene/geschlossene Jobkarten bleiben ueber den 3-Sekunden-Auto-Refresh erhalten; „Alle schliessen“ wird nicht mehr sofort rueckgaengig gemacht.
- Agent Enrollment: Scrollposition des Statusbereichs bleibt beim Auto-Refresh erhalten.

## 3.0.30 - 2026-09-11

- Agent Enrollment: Agent Bind-IP wird bei IP-basiertem SSH-Ziel automatisch aus dem Ziel vorbelegt.
- Agent Enrollment: Verhindert den typischen Fehler, bei dem die Manager-IP als Remote-Agent Bind-IP verwendet wird.
- Agent Enrollment: Enrollment-Jobs können aus der Statusansicht gelöscht werden; laufende Jobs sind geschützt.
- Job-Löschung entfernt Queue-, Status-, Secret- und temporäre Registrierungsreste und wird auditiert.

## 3.0.29 - 2026-09-11

- Enrollment-Fehlerdarstellung lesbar gemacht: Fortschrittszeichen, reine Konsolenbalken und Sicherungs-Info werden aus der Kurzursache gefiltert.
- Worker speichert `error_summary` separat vom vollständigen technischen Rohoutput; die GUI zeigt die konkrete letzte Fehlermeldung prominent an.
- Bereits vorhandene Fehler ohne `error_summary` werden clientseitig ebenfalls sinnvoll zusammengefasst.
- Config Manager Standalone auf 2.13.4 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.27 - 2026-09-11

- Agent Enrollment zeigt bei fehlgeschlagenen Jobs die konkrete Fehlerursache jetzt direkt unter dem roten Fortschrittsbereich statt erst unterhalb des Ablauf-Logs.
- Technische Fehlerdetails sind unmittelbar aufklappbar und enthalten die komplette vom Worker gespeicherte Fehlermeldung.
- Der Enrollment-Worker uebernimmt bei fehlgeschlagenen Kommandos jetzt sowohl die letzte stdout- als auch stderr-Ausgabe. Damit werden Fehler aus Remote-Setup-Skripten sichtbar, auch wenn diese ihre Diagnose nicht nach stderr schreiben.
- Neuer Regressionstest `agent_enrollment_error_visibility_test.py`.
- Config Manager Standalone auf 2.13.3 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.26 - 2026-09-11

- Agent-Enrollment-Worker fuer Python 3.6 auf SLES/openSUSE kompatibel gemacht.
- `from __future__ import annotations` entfernt (erst ab Python 3.7 verfuegbar).
- `subprocess.run(capture_output=True)` durch `stdout/stderr=PIPE` ersetzt.
- `Path.unlink(missing_ok=True)` durch Python-3.6-kompatible Fehlerbehandlung ersetzt.
- Setup prueft Python >= 3.6 und kompiliert den Worker vor Installation.
- systemd startet den Worker explizit mit `/usr/bin/python3`.
- Config Manager Standalone auf 2.13.2 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.25 - 2026-09-11

- Agent Enrollment Status grundlegend erweitert: Live-Fortschritt mit neun nachvollziehbaren Schritten von Queue/Host-Key/SSH bis Registrierung und finalem TLS/API-Health-Check.
- Root-Worker persistiert `stage`, `stage_message`, `progress_percent`, strukturierte `steps` und die letzten Statusereignisse bereits waehrend eines laufenden Jobs; Fehler markieren den konkret fehlgeschlagenen Schritt.
- Enrollment-GUI zeigt Fortschrittsbalken, Schrittstatus, aktuellen Arbeitsschritt, kompakten Ablauf-Log, lesbare lokale Zeitstempel sowie klare Erfolgs-/Fehlermeldungen statt nur `Wartet`/`Noch kein Resultat`.
- Queued Jobs zeigen explizit, dass sie auf `teko-agent-enrollment.service` warten. Dadurch ist ein nicht gestarteter Root-Worker sofort von einem laufenden Remote-Setup unterscheidbar.
- Queue- und Statusdateien werden in der Summary pro Job-ID dedupliziert; sobald der Worker einen Status geschrieben hat, hat dieser Vorrang vor der noch vorhandenen Queue-Datei.
- Der zuletzt gewaehlte SSH-Authentifizierungsmodus wird im Browser beibehalten, damit ein Passwort-Demo-Flow nach Reload nicht optisch auf SSH-Key zurueckspringt.
- Polling fuer die Enrollment-Anzeige von 5 auf 3 Sekunden verkuerzt.
- Config Manager Standalone auf 2.13.1 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.23 - 2026-09-11

- Agent Enrollment: Im Passwort-Modus ist der SSH-Host-Key-Fingerprint nicht mehr als Formulareingabe erforderlich. Ohne Fingerprint wird der Host-Key vor der Passwortuebertragung per `ssh-keyscan` erfasst und in `known_hosts` gepinnt (TOFU); alle anschliessenden SSH/SCP-Verbindungen verwenden weiterhin `StrictHostKeyChecking=yes`.
- Im SSH-Key-Modus bleibt der SHA256-Fingerprint zwingend erforderlich und wird unveraendert strikt verglichen. Auch im Passwort-Modus kann weiterhin optional ein erwarteter Fingerprint vorgegeben werden; bei Abweichung wird das Enrollment abgebrochen.
- Agent-Enrollment-GUI passt Pflichtfeld, Hilfetext und Bootstrap-Public-Key-Bereich dynamisch an den gewaehlten Authentifizierungsmodus an.
- Der automatisch beobachtete Host-Key-Fingerprint wird im Jobstatus dokumentiert, nicht jedoch das Passwort.
- Config Manager Standalone auf 2.12.5 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.22 - 2026-09-11

- Git Repository Upload: Multipart-Weitergabe an `/git_upload/stage` verwendet jetzt dieselbe file-basierte Token-Rotation wie normale Agent-API-Aufrufe.
- Vor grossen Stage-Uploads wird `token_file` proaktiv neu geladen; bei einer Rotation waehrend des Requests erfolgt maximal ein kontrollierter 401-Retry mit frischer Verbindung.
- Behebt den Fall, dass Repository-/Branch-Abfragen funktionieren, der abschliessende Stage-Transfer aber mit `Agent Authentifizierung fehlgeschlagen (401)` endet.
- Config Manager Standalone auf 2.12.4 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.21 - 2026-09-11

- Git Repository Upload: Fehler behoben, durch den der Chunk-Request in 3.0.20 versehentlich zweimal per `xhr.send(form)` gestartet wurde.
- Verzeichnis-Upload grundlegend robuster: Dateien werden nicht mehr als Multipart/`$_FILES` übertragen, sondern einzeln als `application/octet-stream` direkt in das sessiongebundene lokale Staging gestreamt. Dadurch ist der Folder-Upload nicht mehr von `max_file_uploads` oder der PHP-Multipart-Auswertung abhängig.
- Chunk-Plan bleibt serverseitig strikt: Upload-ID, Chunk-Index, Chunk-Token und Datei-Index werden validiert; Dateireihenfolge und angekündigte Dateigrösse müssen exakt stimmen.
- Rohdaten werden mit `php://input` direkt in eine `.part`-Datei gestreamt, auf exakte Länge geprüft und erst danach atomar ins Staging übernommen.
- Technische Detailanzeige präzisiert: Verzeichnis-Upload zeigt jetzt `Binärstream je Datei`; PHP-Multipart-Grenzen gelten weiterhin für ZIP-/klassische Datei-Uploads.
- Config Manager Standalone auf 2.12.3 angehoben. Config-Agent bleibt 2.15.2; irreführende systemd-Description wurde auf 2.15.2 korrigiert.

## 3.0.20 - 2026-09-11

- Git-Verzeichnis-Upload: Chunk-Steuerdaten werden vor jedem Multipart-Transfer über einen separaten JSON-Prepare-Schritt registriert.
- Multipart-Requests enthalten nur noch Dateien; Upload-ID, Chunk-Index und ein kurzlebiges Chunk-Token werden in dedizierten Headern transportiert.
- Behebt `Upload-Chunk ist nicht in der erwarteten Reihenfolge.` auf PHP/Apache-Stacks, bei denen Multipart-POST-Steuerfelder nicht zuverlässig ankommen.
- Chunk-Reihenfolge bleibt strikt geprüft; die Prüfung wurde nicht abgeschaltet.
- Config-Manager-Standalone auf 2.12.2 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.19 - 2026-09-11

- Git-Verzeichnis-Upload: lokale Staging-ID wird redundant über `X-TEKO-Upload-ID` und Request-Body transportiert; Multipart-Verluste von POST-Steuerfeldern führen nicht mehr zu `Ungültige lokale Upload-ID.`.
- Backend prüft Header/POST/JSON auf identische Upload-ID und lehnt widersprüchliche Werte ab.
- Config-Manager-Standalone auf 2.12.1 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.18 - 2026-09-11

- Git Repository Upload: Verzeichnis-Uploads werden Browser -> Portal in kleinen, sequenziellen Batches mit standardmaessig 10 Dateien pro Request uebertragen. Dadurch ist der Upload nicht mehr von einem einzelnen grossen Multipart-Request bzw. dessen effektiver `max_file_uploads`-Auswertung abhaengig.
- Lokales, sitzungsgebundenes Upload-Staging ausserhalb des DocumentRoot ergaenzt. Dateipfade werden validiert, Chunks strikt sequenziell verarbeitet, Stages nach Abschluss/Fehler geloescht und Altstages automatisch bereinigt.
- Der Config Manager leitet den vollstaendigen lokalen Stage anschliessend in einem kontrollierten Request an den Config-Agent weiter; Agent-Limits bleiben die verbindliche Gesamtgrenze.
- PHP-Uploadlimits werden im Apache-VHost jetzt auf VirtualHost-Ebene gesetzt, damit sie bereits beim Parsen von Multipart-Requests wirksam sind. `max_input_vars` wird standardmaessig auf 10000 gesetzt.
- Upload-Diagnose erweitert: bei unvollstaendigen Requests werden ausgewaehlte/empfangene Dateianzahl, aktive PHP-Limits, SAPI und Requestgroesse gemeldet.
- Git-Upload-GUI optisch neu gegliedert: klare Schritte fuer Ziel sowie Inhalt/Commit; Agent/Forgejo nur noch als kompakte Status-Chips; technische Limits standardmaessig eingeklappt.
- Config-Manager-Standalone auf 2.12.0 angehoben; Config-Agent bleibt 2.15.2.

## 3.0.17 - 2026-09-11

- Git Repository Upload: frisch erstellte, noch leere Forgejo-Repositories koennen wieder ausgewaehlt und befuellt werden. Eine erfolgreiche Branch-Abfrage ohne JSON-Body bzw. mit `null` wird nur am Branch-Endpoint als leere Branch-Liste interpretiert, statt `Forgejo API lieferte kein gueltiges JSON` auszugeben.
- Leere Repositories waehlen im Upload-Portal automatisch **neuen Branch** und setzen den konfigurierten Default-Branch (typisch `main`) vor, auch wenn das Repository erst spaeter erneut ausgewaehlt wird.
- Agent Enrollment erweitert um **SSH-Key** und **Passwort** als explizite Authentifizierungsmodi. Passwort-Enrollment verwendet `sshpass -d` mit File-Descriptor; das Secret landet nicht in Job-JSON, Status oder Audit und wird nach Jobende geloescht.
- SSH-Host-Key-Fingerprint und `StrictHostKeyChecking=yes` bleiben fuer beide Enrollment-Modi zwingend. Nicht-root Enrollment verwendet weiterhin nur `sudo -n`.
- Agent-Enrollment-GUI neu strukturiert: vier klare Schritte, dunkler technischer Bootstrap-Bereich, Status-KPIs sowie kompakte Job-Karten mit farbigen Status-Badges und separatem Resultatbereich statt der breiten weissen Tabelle.
- Passwort-Modus wird automatisch deaktiviert, wenn `sshpass` auf dem Manager nicht verfuegbar ist; der Installer versucht das Paket auf zypper-basierten Systemen optional bereitzustellen.
- Config-Agent auf 2.15.2 und Config-Manager-Standalone auf 2.11.0 angehoben.

## 3.0.16 - 2026-09-11

- Config Manager: PHP-Uploadgrenzen fuer Git-/Verzeichnis-Uploads deutlich erhoeht: `post_max_size=640M`, `upload_max_filesize=512M`, `max_file_uploads=2000`.
- Upload-Grenzen sind ueber `CONFIG_MANAGER_PHP_*` in `teko-stack.conf` bzw. per Environment beim Setup konfigurierbar.
- Apache-VHost setzt die Limits mit `php_admin_value`, damit die Web-SAPI dieselben wirksamen Werte verwendet, die das Portal unter **PHP-Grenzen** anzeigt.
- Setup validiert Groessen- und Zahlenwerte vor dem Schreiben in die Apache-Konfiguration und setzt fuer grosse Uploads `max_execution_time`/`max_input_time` standardmaessig auf 600 Sekunden.

## 3.0.15 - 2026-09-11

- Config-Agent `/health`: fehlende per-Config Backup-Unterverzeichnisse sind bei `auto_create_backups=true` kein Fehler mehr; sie werden als Lazy-Backup-Info gemeldet.
- Health-API liefert strukturierte `errors`, `warnings` und `info`; HTTP 503 wird nur noch fuer echte Betriebsfehler verwendet.
- Betriebsuebersicht unterscheidet Fehler, Warnungen und reine Info-Hinweise korrekt und zeigt die Anzahl Configs ohne bisheriges Backup kompakt an.
- Legacy-Upgrades ohne `auto_create_backups` erhalten den aktuellen Default `true`; explizites `false` bleibt erhalten.

## 3.0.14 - 2026-09-10

- Neue **Betriebsübersicht** im Config Manager: Config-Agent, Managed Configs, Git Deploy, Git Upload, ModSecurity/CRS, Monit, Backups und Audit werden auf einer Seite zusammengeführt.
- Runtime-vs-Soll-Vergleich für statusfähige verwaltete Services ergänzt. `desired_status` unterstützt `running`, `stopped` und `disabled`; ohne expliziten Wert gilt für statusfähige Service-Einträge `running`.
- Health-/Dependency-Ansicht ergänzt: Agent `/health`, PHP-Runtime-Abhängigkeiten, Audit-DB, Backup-API, Monit und ModSecurity-Runtime-Override werden sichtbar bewertet.
- Backup-/Restore-Einstiege sprachlich vereinheitlicht (`Backups / Restore`) und in der Betriebsübersicht um eine Backup-Abdeckungsanzeige ergänzt.
- Portalweite Aktionsrückmeldungen über `mmbb-feedback.js` vereinheitlicht. Bestehende `alert()`-Aufrufe erscheinen als Bootstrap-Toasts; `confirm()`/`prompt()` bleiben unverändert.
- Audit-Trail erweitert: Service-Mutationen wie Start/Stop/Reload/Restart werden mit Ergebnis auditiert; reine Status- und Journal-Abfragen bleiben read-only ohne Audit-Rauschen.
- Standalone-Audit-Schema wird kompatibel um `ip`, `uri` und `data_json` erweitert. Query-Strings werden aus Sicherheitsgründen nicht in `uri` gespeichert.
- Audit-Log zeigt Mutationen/24h, Fehler/24h sowie Top-Aktion und Top-Ziel der letzten 7 Tage; historische `payload`-Daten bleiben sichtbar.
- Config-Agent auf 2.15.0 und Config-Manager-Standalone auf 2.10.0 angehoben.
- Regressionstests für Betriebsübersicht, Audit-Schema, Service-Audit und portalweite Feedback-Komponente ergänzt.

## 3.0.13 - 2026-09-10

- ModSecurity auf SUSE/openSUSE verwendet fuer Apache Reload/Restart jetzt `rcapache2`, sofern vorhanden.
- Der Rule-Engine-Modus wird zusaetzlich in `/etc/apache2/conf.d/zz-teko-modsecurity-mode.conf` als spaeter Apache-Override geschrieben. Dadurch kann die Distributionsdatei `/etc/apache2/conf.d/mod_security2.conf` mit `SecRuleEngine On` einen in der GUI gesetzten `DetectionOnly`-Modus nicht mehr uebersteuern.
- Configtest und Reload bleiben transaktional; auch der neue Runtime-Override wird bei Fehlern zurueckgerollt.
- Die ModSecurity-Web-GUI zeigt nun Soll-Modus, effektiven TEKO-Override und weitere gefundene `SecRuleEngine`-Definitionen/Abhaengigkeiten. Fehlende oder widerspruechliche Runtime-Overrides werden sichtbar als Warnung markiert.
- Regressionstest fuer SUSE-`rcapache2`, Runtime-Override und GUI-Abhaengigkeitsanzeige hinzugefuegt.

## 3.0.12 - 2026-09-10

- Behebt OWASP-CRS-LFI-False-Positives im Config Manager beim Bearbeiten verwalteter Konfigurationen wie `apache-config-manager-vhost`.
- Die Ausnahme ist bewusst eng begrenzt: nur `config_name` und `config_names`, nur auf `/index.php`, nur fuer CRS-Regeln mit Tag `attack-lfi`.
- Rule `949110` und der globale Anomaly-Threshold bleiben unveraendert; SQLi/XSS/RCE und alle anderen CRS-Pruefungen bleiben aktiv.
- Regressionstest `modsecurity_portal_lfi_exclusion_test.py` hinzugefuegt.

## 3.0.11 - 2026-09-10

- Portalweite Kontrast- und Lesbarkeitsoptimierung im zentralen Standalone-Stylesheet.
- Klarere Seitenhierarchie durch staerkere Karten-/Panel-Grenzen und weniger ausgewaschene Hintergrundflaechen.
- Sidebar, aktive Navigation, Formularfelder, Tabellenkoepfe, Zeilentrenner und Outline-Aktionsbuttons deutlicher hervorgehoben.
- Sekundaertexte bleiben zurueckhaltend, besitzen aber hoehere Lesbarkeit.
- Keine Aenderung an Backend, Berechtigungen oder Funktionslogik.

## 3.0.10 - 2026-09-10

- Services & Configs: Restore ist pro verwalteter Konfiguration als eigene, immer sichtbare Zeilenaktion verfuegbar.
- Restore oeffnet den vorhandenen Backup-/Restore-Dialog auch dann, wenn aktuell keine Backups vorhanden sind; der Dialog zeigt dann den bestehenden Leerzustand.
- Keine Aenderung am Restore-Backend: CSRF-Pruefung, Backup-Validierung und `restore_backup` bleiben unveraendert.

## 3.0.9 - 2026-09-10

- Fix Git upload repository creation: correctly unwrap blessed `GitUploadError` objects before testing Forgejo HTTP 404 responses.
- Treat repository lookup 404 as the expected "name is free" result instead of returning HTTP 400 to the portal.
- Preserve the dedicated diagnostic for a real 404 from `POST /api/v1/orgs/:owner/repos`.
- Add regression coverage for the error-object/404 handling.


## 3.0.25
- Agent Enrollment: Worker-Trigger auf `PathChanged` + `DirectoryNotEmpty` umgestellt; `PathExistsGlob` ist nicht mehr der einzige Aktivierungsmechanismus.
- Agent Enrollment: 10-Sekunden-systemd-Timer als Fallback, damit wartende Jobs auch bei verlorenen Path-Events verarbeitet werden.
- Agent Enrollment: bereits vorhandene Queue-Jobs werden beim Setup sofort angestossen.
- Agent Enrollment: temporäre Jobdateien werden ausserhalb der überwachten Queue erzeugt und erst vollständig atomar in die Queue verschoben.
- GUI: Jobs, die länger als 20 Sekunden warten, werden als Worker-/Trigger-Warnung hervorgehoben.


## 3.0.9 – Git Upload API Base URL Fix

- `git_upload.api_base_url` ist jetzt der kanonische Forgejo-API-Endpunkt und wird vom Runtime-Modul bevorzugt.
- `git_upload.base_url` bleibt als kompatibler Alias erhalten.
- Wenn beide Werte gesetzt sind und voneinander abweichen, geht Git Upload fail-closed in Degraded Mode.
- Der Config-Simplifier verwendet dieselbe Prioritaet wie der Runtime-Code.
- Damit wird `http://127.0.0.1:3000` aus bestehenden TEKO-Konfigurationen nicht mehr ignoriert.

## 3.0.7 – Forgejo Capability-Probe Cleanup Fix

- Ein erfolgreiches `POST /api/v1/orgs/{org}/repos` mit HTTP 201 gilt jetzt als Repository-Create-Capability-Nachweis.
- Das temporaere Probe-Repository wird mit dem kurzlebigen Bootstrap-Admin-Token entfernt, nicht mit dem Least-Privilege Service-Token.
- Verwaiste `teko-capability-probe-*`-Repositories aus abgebrochenen Setup-Laeufen werden beim naechsten Bootstrap sicher bereinigt.
- Der Service-User erhaelt bewusst keine zusaetzlichen Owner-/Delete-Rechte.

## 3.0.6 – Forgejo Repository Create End-to-End Fix

- `svc-teko-deploy` wird als normaler Non-Admin-Automation-User betrieben; bestehende als `restricted` angelegte Service-User werden beim Bootstrap migriert.
- PAT-Erzeugung verwendet bei Forgejo-Versionen mit Repository-spezifischen Tokens explizit `--repo all`.
- Der Forgejo-Bootstrap prueft Repository-Erstellung mit exakt dem finalen Service-Token durch einen echten Create+Delete Capability-Probe.
- Der Config-Agent prueft vor Repository-Erstellung die aktuelle `/user/orgs`-Mitgliedschaft statt des sichtbarkeitsabhaengigen User/Org-Permissions-Endpunkts.
- Ein Setup kann nicht mehr erfolgreich enden, wenn Repository-Listing funktioniert, Repository-Erstellung aber spaeter mit Forgejo 403/404 scheitern wuerde.

## 3.0.5 – Forgejo Repository Create Authorization Fix

- Service-Token erhaelt `write:organization` zusaetzlich zu `write:repository`.
- Alte Tokens ohne aktuelle Capability-Metadaten werden beim Setup rotiert.
- Repository-Erstellung prueft `can_create_repository` vor dem POST.
- Forgejo-404 bei fehlender Token-Capability wird als klare lokale Fehlermeldung ausgegeben.

## 3.0.5 – Git Repository Upload UI Fix

- Der Button **Neues Repository** steht jetzt gut sichtbar im Kopfbereich von **Git Repository Upload** direkt neben **Repositorys neu laden**.
- Die Repository-Erstellung ist damit nicht mehr von Breite oder Rendering der Repository-Auswahl abhaengig.
- Das bisherige kleine Inline-Element **Neu** wurde entfernt, damit es keine doppelte oder abgeschnittene Bedienung gibt.
- `git_upload.js` wird mit Versions-Cache-Buster `v=3.0.5` geladen, damit ein `--force`-Deployment nicht durch einen alten Browser-Cache verdeckt wird.
- Backend-Funktionalitaet aus 3.0.3 bleibt erhalten: Repository direkt in Forgejo erstellen, privat/leer als Default, Konflikte blockieren, Audit `repository_create`, danach automatisch neu laden und auswaehlen.

## 3.0.2 – Deployment-Profil-Assistent

- Der Assistent listet alle lesbaren Forgejo-Repositorys statt bereits verwendete Repositorys auszublenden.
- Bestehende Zuordnungen zu `git_deploy.json` werden als Status/Profil-IDs markiert.
- Bereits verwendete Repositorys koennen fuer weitere Profile oder Branches erneut analysiert werden.
- Read-only Repositorys bleiben explizit sichtbar.

## 3.0.1 – Setup/Analyzer Hardening

- Hostname checks no longer require the legacy `hostname` executable; a robust kernel-/file-/uname fallback is used.
- Config-Agent analyzer accepts executable system symlinks only after resolving and validating a root-owned, non-group/world-writable target.
- Config-Agent installation policy now matches the intentionally restrictive runtime permissions for `/opt/service/env`, `global.json` and `git_deploy.json`.

## 3.0.0 – Clean Baseline

Diese Version ist der bereinigte Git-Ausgangsstand des TEKO Local Stack.
Historische Validierungs-JSONs, Fix-/Review-Reports, Caches, Bytecode und alte
versionierte Beispielkonfigurationen wurden bewusst nicht übernommen.

Wesentliche Änderungen der Baseline:

- Git Deploy Ende-zu-Ende gehärtet und vereinheitlicht
- zustandsgebundene, einmalige Diff-Preview-Tokens pro Zielserver
- eigener Preview-/Restore-Ablauf
- Erstdeploy sowie Branch-/Tag-/Exact-/Ancestor-Ref-Prüfung konsolidiert
- Request-Token für Compare, Deploy, Restore, Status und History konsistent
- Preflight-Integritätsfingerprint vor/nach Prüfung
- sichere interne Symlink-Unterstützung bei expliziter Freigabe
- strikte JSON-Boolean-, Feld-, Schema- und Limit-Validierung
- Git Upload und read-only Repository-Assistent getrennt
- Race-/Stale-Editor-Schutz für `git_deploy.json`
- gemeinsame kanonische Beispielkonfigurationen
- Git-Deploy-Root-Whitelist enthält TEKO- und bestehende MMBB-Pfade
- Service-/Config-Manager-UI konsolidiert
- Repository-Dokumentation und Qualitätsprüfungen ausgebaut

Die Runtime-History für Deploy/Rollback, Audit und Backups bleibt absichtlich
Betriebsfunktionalität und ist nicht Teil der Source-History-Bereinigung.

## 3.0.33
- Config Manager: lokaler Runtime-Token `/opt/service/config-manager/local-agent.token` wird bei jedem Setup aus dem autoritativen `CONFIG_MANAGER_API_TOKEN` atomar regeneriert (`root:<web-group>`, `0640`).
- Runtime: fehlende/unlesbare `token_file` eines Loopback-Agents blockiert nicht mehr das gesamte Portal; nur fuer `127.0.0.1`, `::1` oder `localhost` ist ein geschuetzter Fallback auf den bereits geladenen Manager-Token erlaubt.
- Remote-Agenten bleiben strikt: fehlende/unlesbare Token-Dateien fuehren weiterhin zu einem Fehler.
- Regressionstests fuer lokalen Token-Recovery- und Setup-Pfad ergaenzt.

## 3.13.8 - 2026-09-12
- Neue zentrale Administration **Zugänge & Secrets** als übersichtliches Credential-/Key-Inventar.
- Zeigt Zweck, Scope, Speicherort, Rechte/Owner und zuständige Verwaltungsfunktion ohne Klartext-Secrets.
- Config-Agent Host-Tokens werden aus der Server-Registry in das Inventar aufgenommen.
- Passwort ändern wurde aus Security nach Administration verschoben.
- Klartext-Ausgabe bleibt bewusst ausschliesslich über `teko-access-summary.sh --show-secrets` möglich.

## 3.14.1 - 2026-09-12

- Client Baseline: bestehende Monit-HTTP-Definitionen in der Hauptkonfiguration werden beim Speichern automatisch und rollback-faehig in die Baseline-Drop-in-Konfiguration migriert; die manuelle Vorbereinigung entfaellt.
- Grafana Alloy: Loki- und Prometheus-Endpunkte werden aus der oeffentlichen Config-Manager-URL vorbelegt und bestehende Alloy-Konfigurationen wieder eingelesen. Auf SUSE/openSUSE kann bei fehlendem Paket automatisch das offizielle Grafana-RPM-Repository eingerichtet werden.
- Observability-Ingest: neue authentisierte Config-Manager-Endpunkte fuer Loki und Prometheus Remote Write. Als Credential wird der bereits vorhandene host-spezifische Config-Agent-Token verwendet.
- Alloy-Konfiguration kann bereits vorbereitet werden, wenn auf dem Zielhost noch keine Alloy-Paketquelle vorhanden ist. Der Paketstatus wird in der GUI eindeutig als `Paketquelle fehlt` angezeigt.
- Globaler Ladeindikator auf tokenbasierte Request-Verfolgung umgestellt. Fetch/XHR, abgebrochene Requests, BFCache und Navigation koennen keinen haengenden Spinner mehr hinterlassen.

## 3.18.1 - 2026-09-12

- Observability Client ist jetzt ein eigenes Forgejo-Repository `teko/observability-client`.
- Deploy-Profil `observability-client` enthaelt den Paketplan direkt (`monit`, `alloy`, `monit-prometheus-exporter`, `client-baseline`).
- Git Deploy unterstuetzt deklarative `package_repositories` und `packages`; keine `install.sh`/`verify.sh` Hooks mehr fuer Observability.
- Legacy-Observability-Skripte werden aus `config-deploy` entfernt.
- `client-baseline` RPM 1.2.0 uebernimmt Alloy-Basiskonfiguration und Service-Aktivierung package-seitig.
- Client Baseline im Portal bleibt auf Host-Identitaet und Monit-Zugang beschraenkt.

## 3.18.1
- `observability-client/deploy-profile.json` ist jetzt die autoritative, deklarative Installationsdefinition im Git-Repository.
- Git Deploy liest den Paketplan direkt aus dem ausgewaehlten Commit und fuehrt ihn ueber den Config-Agent Package Manager aus.
- Das zentrale Deploy-Profil enthaelt nur noch Repository/Branch/Ziel und erlaubt explizit den Repository-Paketplan; Paketlisten werden nicht doppelt gepflegt.
- RPM-Binaries bleiben im internen RPM-Repository und werden auf Remote-Hosts per zypper installiert; Git enthaelt bewusst keine 150-MB-Vendor-RPMs.
