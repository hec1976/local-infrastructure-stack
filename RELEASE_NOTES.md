## 3.18.32

- Grafana Alloy Dashboard-Fix: Alloy/Loki-Panels filtern jetzt stabil ueber `source="alloy"` statt ueber `job="systemd-journal"`.
- Hintergrund: `loki.source.journal` liefert in der realen Laufzeit das `job`-Label z. B. als `loki.source.journal.system`; dadurch waren Daten in Loki/Explore sichtbar, aber das Dashboard blieb leer.
- Host-Auswahl verwendet jetzt `label_values({source="alloy"}, hostname)`.
- Auch die Alloy-Kachel in `TEKO Service Uebersicht` nutzt den stabilen `source="alloy"`-Selector.
- Regressionstest verhindert kuenftig wieder einen harten Dashboard-Filter auf `job="systemd-journal"`.
- Repository-Paket fuer GitHub bereinigt: umfassende aktuelle README, korrekte Execute-Bits, keine Bytecode-/Cache-Artefakte und keine veralteten Testergebnisse im Source-Root.
- GitHub Actions prueft Repository-Hygiene und Regressionstests; generierte Testberichte liegen ausschliesslich unter `reports/`.
- Lizenzstatus und direkt eingebettete Drittanbieter-Komponenten sind dokumentiert.


## 3.18.31

- Python 3.6 compatibility fix: removed invalid universal_newlines argument from tempfile.mkstemp() in teko-observability-auth-sync.py.
- Added regression check to ensure universal_newlines is used only with subprocess APIs, never tempfile.mkstemp().

### Python 3.6 / Observability Auth

Auf SLES/openSUSE-Systemen mit Python 3.6 konnte Schritt `6c/8: Observability Data Plane Auth fuer Apache vorbereiten` mit `TypeError: __init__() got an unexpected keyword argument 'text'` abbrechen. Alle produktiven Python-Runtime-Pfade fuer Auth-Sync, Enrollment und Token-Rotation verwenden nun `universal_newlines=True`.

## 3.18.29

Observability Auth und Grafana/Loki-Sichtbarkeit für Alloy-Clients korrigiert.

## 3.18.28

Der zusaetzliche Python-Dienst fuer den Observability-Ingest wurde entfernt. Apache ist nun die einzige externe Proxy-Schicht: `/observability-ingest/loki/api/v1/push` geht direkt an Loki und `/observability-ingest/prometheus/api/v1/write` direkt an Prometheus. Die bestehenden pro Host vergebenen Agent-Tokens werden weiterhin zur Authentisierung verwendet und automatisch in einer nur fuer Apache lesbaren htpasswd-Datei gespiegelt.

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

# 3.18.23

- Fail2ban-Statusabruf beschleunigt: bei bereits installiertem Fail2ban keine Paket-/Repository-Prüfung mehr.
- Fail2ban-GUI zeigt Ladefortschritt, Langläufer-Hinweis ab 2 s und die gemessene Ladezeit.
- Config-Agent 2.23.13 / Config-Manager 2.33.4.

# Release Notes
## 3.18.22

Die Firewall-Seite reagiert jetzt wesentlich direkter und zeigt laufende Aktionen sichtbar an.

- Bereits installiertes `firewalld` loest beim Statusladen keine Paket-/Repository-Vorschau mehr aus.
- Der Agent cached identische Statusabfragen fuer vier Sekunden. Mutationen verwerfen den Cache sofort.
- Nach einer Regel-, Interface- oder Zonen-Aenderung wird der Firewall-Status nur noch einmal neu ermittelt; der bisherige zweite Vollscan im Agenten entfaellt.
- Spinner und Aktionsstatus zeigen an, ob geladen, angewendet, entfernt oder aktualisiert wird.
- Dauert eine Abfrage laenger als zwei Sekunden, erscheint ein Hinweis auf die noch laufende firewalld/D-Bus-Abfrage.
- Die tatsaechliche Ladezeit wird nach erfolgreichem Refresh in Millisekunden angezeigt.

## 3.18.20

Die Firewall-Oberflaeche wurde nochmals vereinfacht und fachlich sauber getrennt.

- `Netz / Quelle` ist keine Freigaberegel mehr, sondern eine Zonen-Zuordnung. Netz und Praefix werden direkt bei der ausgewaehlten Zone erfasst.
- Interface- und Netz-Zuordnung stehen kompakt direkt unter `Zone bearbeiten`.
- Die eigentlichen Freigaben enthalten nur noch `Port`, `Service`, `Port + Quelle` und `Erweitert`.
- `public` wird nicht mehr kuenstlich in die Zonenauswahl eingefuegt. Angezeigt werden die vom Host gelieferten Zonen.
- Unbenutzte eingebaute firewalld-Zonen sind standardmaessig ausgeblendet; `Alle Systemzonen` blendet sie bei Bedarf ein.
- Eingebaute Zonen werden als `Systemzone` gekennzeichnet. Sie sind absichtlich nicht loeschbar; eigene Zonen besitzen weiterhin eine Loeschaktion.
- Die Zonenuebersicht ist jetzt eine kompakte Tabelle statt vieler grosser Karten.
- Die Regeln der aktuell ausgewaehlten Zone stehen direkt unter dem Eingabeeditor und koennen dort geloescht werden.

## 3.18.19

Die Firewall-Oberflaeche wurde auf eine zonenzentrierte Bedienung umgestellt.

- Jede Zone zeigt direkt, welche Interfaces ihr zugeordnet sind.
- Ein Interface kann innerhalb der Zielzone ueber `Zuweisen / aktivieren` zugeordnet oder aus einer anderen Zone verschoben werden.
- Interfaces koennen direkt aus einer Zone entfernt werden; ohne weitere Interfaces oder Quellen wird die Zone danach inaktiv.
- Die Ansicht kann auf aktive, konfigurierte oder alle Zonen gefiltert werden.
- Eine konfigurierte, aber inaktive Zone wird deutlich als derzeit unwirksam markiert.
- Regeln werden getrennt nach Quellen/Netzen, Services, Ports und Rich Rules dargestellt.
- Die Oberflaeche erklaert explizit, dass beispielsweise `443/tcp` in `public` nur wirkt, wenn Verkehr auch der Zone `public` zugeordnet ist.

## 3.18.18

Die Firewall-Seite war durch elf leere Standardzonen unbenutzbar und liess
zentrale Verwaltungsschritte nicht zu.

- P1: Zonen ohne Regeln werden ausgeblendet. Angezeigt werden aktive Zonen, die
  Standardzone und Zonen mit Regeln oder Interfaces. Ein Umschalter blendet die
  uebrigen bei Bedarf ein.
- P1: Netzwerkschnittstellen sind verwaltbar. Der Agent meldet alle Interfaces des
  Hosts mit ihrer Zone; im Portal laesst sich eine Schnittstelle einer Zone
  zuordnen. Erst dadurch wird eine Zone ueberhaupt wirksam.
- P1: Zonen koennen angelegt und geloescht werden (`POST /firewall/zone`).
  Eingebaute Zonen, die Standardzone und Zonen mit zugeordneten Interfaces sind
  gegen Loeschen geschuetzt.
- P1: Der Hinweis "Weder Laufzeit- noch permanente Konfiguration lesbar" erschien
  auch bei laufendem Dienst, sobald der Agent aelter als das Portal war und
  `config_source` nicht kannte. Die Seite faellt jetzt auf den Dienstzustand zurueck.
- P2: "Keine Regeln in dieser Zone" wurde zusaetzlich zu vorhandenen Regeln
  angezeigt, weil die Leermeldung nur an den Rich Rules hing.
- P2: Zonen-Target wird lesbar dargestellt (`REJECT` statt `%%REJECT%%`).
- P2: Ein leeres Eingabefeld zeigt keine rote Fehlermeldung mehr. Die Buttons
  bleiben deaktiviert, bis die Eingabe gueltig ist.
- P2: Das Entfernen von Agent-Port, `ssh` oder einer Interfacezuordnung fragt im
  Portal ausdruecklich nach und reicht die Bestaetigung an den Agenten weiter.

## 3.18.17

Korrektur eines in 3.18.16 eingefuehrten Remote-Lockouts sowie die fehlende
Uebersicht ueber den tatsaechlich gesetzten Firewall-Stand.

- P0: Der automatische Start von firewalld aus `_fw_change` heraus hat den Agenten
  ausgesperrt. firewalld startet mit der Standardzone, die den Agent-Port nicht
  kennt; der laufende Request endete mit "Could not connect to server" und der Host
  war ueber das Portal nicht mehr erreichbar. `_fw_ensure_running` schreibt jetzt
  zuerst per `firewall-offline-cmd` Selbstschutzregeln fuer den Agent-Port und SSH
  in die Standardzone und startet den Dienst erst danach. Laesst sich der
  Selbstschutz nicht setzen, wird gar nicht gestartet und die Aktion bricht mit
  einer erklaerenden Meldung ab.
- P1: Bei gestopptem firewalld zeigte die Seite gar keine Regeln. `_fw_info` liest
  in diesem Fall die permanente Konfiguration ueber `firewall-offline-cmd` und
  kennzeichnet sie als solche. Was gesetzt ist, ist damit auch ohne laufenden
  Dienst sichtbar.
- P1: Aussperrschutz beim Entfernen. Das Loeschen des Agent-Ports oder des
  Services `ssh` wird abgelehnt, solange es nicht ausdruecklich bestaetigt wird.
- P1: Neue Sammelanwendung `POST /firewall/changes` fuer bis zu 32 Regeln. Alle
  Eintraege werden zuerst vollstaendig validiert, danach angewendet, mit genau
  einem Reload. Im Portal gibt es dazu eine Vormerkliste und "Alle anwenden".
- P2: Die Seite markiert vor dem Anwenden, ob eine Regel in der gewaehlten Zone
  bereits gesetzt ist, sowohl im Eingabefeld als auch in der Vormerkliste. Das
  Ergebnis meldet getrennt, wie viele Regeln neu gesetzt wurden und wie viele
  bereits vorhanden waren.

## 3.18.16

Firewall-Verwaltung im Portal repariert. Die Seite konnte Regeln bisher nur
teilweise anlegen und teilweise gar nicht entfernen.

- P1: Regeltyp `source_port` ("Port + Quelle") war in `ConfigManagerService::changeFirewallRule`
  nicht freigegeben. Die GUI bot den Tab an, jeder Request endete aber mit HTTP 400,
  bevor der Agent ueberhaupt erreicht wurde.
- P1: Port**bereiche** werden jetzt durchgehend unterstuetzt. Die GUI hat `8000-8100`
  beworben und validiert, der Agent liess nur Einzelports zu. Bestehende Bereichsregeln
  liessen sich dadurch weder anlegen noch ueber den Papierkorb-Button loeschen.
- P1: Regelaenderungen starten firewalld bei Bedarf selbst (`_fw_ensure_running`).
  Bei installiertem, aber gestopptem Dienst scheiterte bisher jede Aktion mit
  "FirewallD is not running", und das Portal bot keinen Ausweg.
- P1: Neue Dienststeuerung `/firewall/service` (enable, restart, disable) mit Buttons
  im Portal. Stoppen ist explizit bestaetigungspflichtig.
- P2: `_fw_info` liefert alle definierten Zonen statt nur der aktiven, inklusive
  Standardzone, Target und Aktiv-Kennzeichnung. Zonen wie `internal` oder `dmz` sind
  damit ueberhaupt erst verwaltbar.
- P2: Drift-Erkennung zwischen Laufzeit- und permanenter Konfiguration je Zone.
  Direkt auf der Konsole gesetzte Regeln ohne `--permanent` werden im Portal markiert.
- P2: `ALREADY_ENABLED`/`NOT_ENABLED` gelten als idempotentes Ergebnis und nicht mehr
  als Fehler.
- P2: SCTP ist jetzt auch fuer "Port + Quelle" waehlbar.
- P1: Agent-Token-Scopes werden bei bestehenden Installationen zusammengefuehrt statt
  nur bei Erstinstallation gesetzt. Aeltere Agenten ohne `security.manage` beantworteten
  jede Firewall-Aktion mit HTTP 403.
- P1: Trust-Anchor im Enrollment- und Repair-Bundle ist fail closed. Fehlt das
  Config-Manager-Zertifikat, brechen Bundle-Bau und Remote-Repair mit einer klaren
  Meldung ab, statt spaeter beim Observability-Deploy als curl rc=60 aufzutauchen.

## 3.18.15

- P1: Agent Lifecycle Repair-Bundle enthaelt jetzt den aktuellen Config-Manager Trust-Anchor; Remote-Repair installiert ihn kanonisch als `/etc/pki/trust/anchors/infrastructure-config-manager.crt` und aktualisiert den System-Truststore.
- P1: Config-Agent-Basisupdate deaktiviert ein vorhandenes `infrastructure-baseline`-Repository robust ueber Alias-Erkennung statt fehlerhafter fester zypper-Spaltenposition. Dadurch blockiert ein defektes Workload-Repo den Agent-Repair nicht mehr.
- P1: Observability-Deploy-Preflight prueft nur gueltige X.509 Trust-Anker und liefert einen eindeutigen erwarteten Pfad bei TLS rc=60.
 3.18.14

Diese Version ist bewusst eine P1-Konsolidierung ohne neue Produktfunktion. Sie schliesst die zwei kritischen Fehlerpfade rund um Agent Lifecycle und Remote Git Deploy.

- `observability-client` bricht bei nicht erreichbaren HTTPS-Repository-Metadaten jetzt bereits im Preflight mit dem echten curl-Return-Code ab.
- Agent Lifecycle Update/Repair ignoriert ein stale/defektes `infrastructure-baseline`-Repo waehrend der Config-Agent-Basisreparatur und stellt es danach wieder her.
- Remote-Clients reparieren zentrale FQDN-Zuordnungen auf die konfigurierte Manager-IP und erneuern den lokalen Trust-Anchor aus dem Repair-Bundle.
- Baseline-Repository-Publishing wird nach Build durch Apache configtest/reload und anschliessenden HTTPS-Metadaten-Check verifiziert.
- Der Zielsystem-E2E-Test prueft jetzt Alloy, Prometheus und Observability Ingest als Release-Gate.

# Local Infrastructure Stack 3.18.13

- Agent Lifecycle ist als eigener Bereich von Token/SSH getrennt.
- Remote Baseline-RPM-Repository wird auf dem Management-Host nach dem Build lokal und via HTTPS validiert.
- Apache liefert `/baseline-repo/` als statische Paketquelle aus; ModSecurity wird fuer diesen internen statischen Pfad deaktiviert.
- `observability-client/install.sh` prueft vor zypper exakt `repodata/repomd.xml`, erneuert den CA-Trust und liefert bei DNS/TLS/Publishing-Fehlern eine konkrete Ursache statt nur `Repository invalid`.

## 3.18.12

- Neuer separater **Agent Lifecycle** in Managed Hosts/Registry.
- Token/SSH-Dialog ist auf Authentisierung, SSH-Synchronisation und Token-Rotation reduziert.
- **Agent aktualisieren**: Code neu ausrollen, Host-ID/Token/Remote-Einstellungen behalten.
- **Agent reparieren**: Agent-Dateien/Service erneut ausrollen und pruefen, Einstellungen soweit moeglich behalten.
- **Auf Defaults zuruecksetzen**: ersetzt den bisherigen Force-Schalter und setzt Remote-Agent-Konfiguration bewusst auf zentrale Defaults zurueck.
- Reset ist klar als destruktive Aktion gekennzeichnet und separat bestaetigungspflichtig.

## 3.18.11

Der Agent-Rollout ist jetzt fuer Management-Host und Remote-Clients vereinheitlicht. Alle Hosts erhalten dasselbe Config-Schema und dieselben Defaults; hostabhaengig bleiben nur Listener und ACL. Der Master traegt seine eigene Management-IP plus Loopback in `allowed_ips` ein. Enrollment/Repair uebertragen den Forgejo-Service-Token separat ueber SSH, sodass Git Deploy nach dem Rollout sofort vorbereitet ist.

## 3.18.10

Behebt den Git-Deploy-Abbruch `useradd: /etc/shadow: Read-only file system`. Die Config-Agent-systemd-Sandbox blockiert keine systemweiten Paket-/Servicekonto-Aenderungen mehr, die fuer autorisierte Package- und Git-Deploy-Jobs erforderlich sind. Sensitive Pfade bleiben im Datei-Manager und in direkten File-REST-Aktionen weiterhin serverseitig gesperrt. Agent-eigene Credential-Verzeichnisse bleiben read-only.

## 3.18.9

Behebt den Alloy-Abbruch `status=217/USER`: `client-baseline` 1.2.4 repariert fehlende Alloy-Systemgruppe/-benutzer idempotent, setzt `/var/lib/alloy` passend und validiert/startet Alloy anschliessend unter den echten Service-Credentials.

## 3.18.7

Grafana Alloy Runtime-Fix: `client-baseline` 1.2.2 schreibt `/etc/alloy/config.alloy` mit einer fuer den effektiven Alloy-Serviceuser lesbaren Gruppe, validiert die Konfiguration mit dessen Rechten und prueft nach dem Restart mehrere Sekunden den stabilen Servicezustand. Bei Fehlern werden `systemctl status` und die letzten Journalzeilen direkt in den Git-Deploy-Report geschrieben. Die RPM-Postinstallation verschluckt keine produktbezogenen Konfigurationsfehler mehr; die ausfuehrende Logik bleibt in `observability-client/install.sh`.

## 3.18.6
Der Datei Manager zeigt sensible Systempfade nicht mehr an. Die Firewall kann nun Quellnetz und Zielport in einer strukturierten Regel kombinieren, ohne Rich-Rule-Freitext.

## 3.18.5 – Alloy-Konfiguration / Observability Deploy Fix

Der fehlgeschlagene `observability-client`-Deploy wurde durch eine ungueltige Alloy-Kommentar-Syntax (`#`) in `/etc/alloy/config.alloy` verursacht. Alloy verwendet `//` bzw. `/* ... */`. Die RPM-Konfiguration wurde korrigiert und wird nun vor Aktivierung atomar validiert. `client-baseline` 1.2.1 erzwingt auf Hosts mit 1.2.0 ein sauberes Update.

## 3.18.4 – Datei Manager und Firewall UX

Der Datei Manager arbeitet jetzt wie ein moderner Dateibrowser mit Verlauf, Breadcrumb-Navigation, Hoch/Zurueck/Vorwaerts, Filter und klarer Trennung zwischen lesbaren und schreibbaren Pfaden. Dateiaktionen verwenden Portal-Dialoge statt Browser-Prompts.

Die Firewall-Seite verlangt keine zusammengesetzten Freitextwerte mehr. Port und Protokoll, IP-Adresse und Praefix sowie firewalld-Service werden getrennt eingegeben und validiert. Nur Rich Rules bleiben als Experten-Freitext erhalten.

# 3.18.2

## 3.18.3

Git-Deploy kann nun ein durch Forgejo angelegtes `install.sh` mit Modus 0644 sicher als `post_deploy` ausfuehren. Das Skript wird nur innerhalb des aktiven Releases akzeptiert und explizit mit `/bin/bash` gestartet; die bisherige Executable-Pruefung fuer andere Programme bleibt bestehen.

`observability-client` besitzt wieder einen expliziten Installer. Forgejo wird mit `install.sh`, `deploy-profile.json` und `packages.json` vorbereitet. Das zentrale Deploy-Profil startet `install.sh` nach Aktivierung des Git-Releases als `post_deploy`. Der Installer liest den Paketplan aus demselben Commit, richtet das interne Repository ein, installiert/verifiziert Monit, Alloy, Monit Prometheus Exporter und `client-baseline`, aktiviert die Dienste und fuehrt einen Healthcheck aus. Die Config-Manager Client Baseline bleibt auf Host-ID und Monit-Zugang beschraenkt.

# Release Notes 3.18.1

Die Observability-Software wird jetzt deklarativ ueber Git Deploy und Package Management ausgerollt. Forgejo erhaelt ein eigenes Repository `teko/observability-client` mit `deploy-profile.json` und `packages.json`. Das zentrale Deploy-Profil enthaelt die Paketliste direkt; Das Repository enthaelt `install.sh`; Git Deploy startet es als `post_deploy`.

Die Client Baseline bleibt bewusst klein: Config-Agent/Host-ID sowie Monit-Zugang und Credential. Monit, Grafana Alloy, der Monit Prometheus Exporter und das Meta-Paket `client-baseline` werden ueber den Paketplan installiert.

`client-baseline` 1.2.0 besitzt die generische Alloy-Konfiguration und aktiviert die Services package-seitig. Dadurch gibt es keinen zweiten Installer-Pfad mehr.

# RELEASE NOTES

## 3.17.1 – Audit REST und Runtime-Ownership

Der Observability-Deploy-Profil-Bootstrap verwendet fuer die Config-Manager-Laufzeitdaten jetzt denselben Runtime-Owner wie das Portal (`wwwrun:www`). Das behebt fehlgeschlagene Audit-REST-Aufrufe mit HTTP 503, wenn `config-manager.env` nach dem Bootstrap fuer Apache nicht mehr lesbar war. `setup_observability.sh` stellt Ownership und Dateirechte nach der Token-Synchronisierung zusaetzlich explizit wieder her.

## 3.17.0 – Baseline und Software-Rollout getrennt

Die Client Baseline ist jetzt bewusst klein: Sie verwaltet nur Config-Agent/Host-Identitaet sowie den lokalen Monit-Zugang fuer Server Health. Monit-Paket, Grafana Alloy und Monit Prometheus Exporter werden ausschliesslich ueber das zentrale Deploy-Profil `observability-client` verteilt.

Forgejo `teko/config-deploy` wird beim Bootstrap mit einem fertigen Observability-Deployment vorbereitet. Das zentrale Deploy-Profil wird ebenfalls automatisch angelegt und ruft nach dem Git-Deployment `deploy/observability-client/install.sh` auf. Der Installer bezieht die freigegebenen RPMs aus dem internen `infrastructure-baseline`-Repository, erzeugt die generische Alloy-Konfiguration und aktiviert Alloy. Der Monit Exporter wird aktiviert, sobald das Monit-Credential ueber die Baseline gesetzt ist.

Damit gilt klar: **Baseline = Zugang/Identitaet, Git Deploy = Software-Sollzustand, Git = Source of Truth.**


## 3.16.7

Der Management-Bootstrap neutralisiert jetzt einen veralteten oder noch nicht publizierbaren `infrastructure-baseline`-Repository-Eintrag **bevor** Forgejo, Config Agent oder Config Manager ein globales `zypper refresh` ausfuehren. Ein bereits fertig gebautes lokales Repository wird direkt als `file:///srv/www/baseline-repo/` eingebunden; andernfalls wird der stale Eintrag entfernt und spaeter sauber neu angelegt.

Das behebt Wiederholungsläufe, bei denen ein alter HTTPS-Eintrag `https://config-manager.local/baseline-repo/` den gesamten Setup bereits in Schritt 2/10 blockierte, obwohl das Repository zu diesem Zeitpunkt noch gar nicht benoetigt wurde.

## 3.16.6

Das Management-Setup verwendet sein frisch gebautes Baseline-Repository direkt als lokale `file://`-Quelle. Remote-Clients bleiben auf HTTPS. Die Repository-Metadaten werden lokal zwingend validiert und die HTTPS-Verteilung wird separat getestet.

# Release Notes – Local Infrastructure Stack 3.16.5

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

3.16.2 behebt den Abbruch beim Aufbau des internen Baseline-RPM-Repositorys. Ursache war der Aufruf von `zypper download` mit einem nicht portablen `--directory`-Schalter. Der Download wird nun direkt im temporaeren Repository-Verzeichnis ausgefuehrt und danach auf das erwartete RPM geprueft.

Der Repository-Builder protokolliert jeden Schritt und liefert bei einem Fehler Zeile, Kommando und Exitcode. Das Hauptsetup stoppt damit kontrolliert und mit einer verwertbaren Fehlermeldung statt direkt nach einem `zypper refresh` zu verschwinden.

Die Meldung `Missing build-id` beim selbst gebauten Go-RPM ist nur eine RPM-Warnung und war nicht die Abbruchursache.

# Local Infrastructure Stack 3.16.1

3.16.1 trennt die generische Client-Plattform konsequent von der konkreten TEKO-Umgebung. Die installierbaren Baseline-Artefakte heissen jetzt `client-baseline`, `monit-prometheus-exporter` und `infrastructure-baseline`. TEKO-spezifische Namen bleiben nur dort erhalten, wo sie wirklich die Umgebung bzw. deren lokale Services, Dashboards oder Bootstrap-Profile bezeichnen.

Die Monit-Prometheus-Metriken sind ebenfalls neutral (`monit_*`). Das Meta-RPM verwendet ein neutrales Alloy-Drop-in. Fuer Upgrades deklarieren die neuen RPMs die bisherigen Paketnamen als `Provides/Obsoletes`; diese Legacy-Namen dienen nur der Migration und sind keine neuen Komponentenbezeichnungen.

# Release Notes – Local Infrastructure Stack 3.16.1

## Architektur: Paketierung vor Konfiguration

Die generische Client-Baseline installiert Software nicht mehr ad hoc. Monit, Grafana Alloy und der Go Monit XML Exporter werden als freigegebene RPMs in einem internen Repository bereitgestellt. Der Config Manager installiert auf Zielhosts nur noch das Meta-Paket `client-baseline` und wendet danach die host-spezifische Basiskonfiguration an.

Der Management-Server stellt das Repository unter `https://<config-manager>/baseline-repo/` bereit. `setup_baseline_repository.sh` baut das eigene Exporter-RPM und das Meta-RPM und uebernimmt freigegebene Monit-/Alloy-RPMs. Offline koennen diese RPMs vorab unter `baseline-repository/packages/` abgelegt werden; mit `TEKO_BASELINE_REPO_FETCH=1` bzw. Auto-Modus koennen fehlende Vendor-Pakete einmalig auf dem Repository-Builder geladen werden.

Wichtig: Der Config Agent schreibt keine Exporter-Binary und keine Exporter-systemd-Unit mehr. Diese Dateien gehoeren ausschliesslich dem Paketmanager.

# Release Notes 3.15.2

3.15.2 korrigiert den Monit-Prometheus-Exporter-Setup-Pfad. Die lokale Monit-HTTP-Authentisierung besitzt jetzt eine einzige Source of Truth: `/var/lib/service/config-agent/secrets/monit-status.env`. Monit, Config Agent und Go Exporter verwenden exakt diesen Credential-Satz.

Der Installer standardisiert die systemd-Unit auf `/etc/systemd/system/monit-prometheus-exporter.service` und entfernt die in 3.15.1 mögliche konkurrierende Unit unter `/usr/lib/systemd/system`. Damit kann systemd nicht mehr unbeabsichtigt eine ältere Exporter-Definition mit falschem Environment verwenden.

# Release Notes 3.15.1

3.15.1 macht die Client-Baseline betrieblich nachvollziehbar. Lange Paketinstallationen laufen als Hintergrundjobs mit echter Fortschrittsanzeige statt als lang laufender Webrequest.

Die Observability-Baseline besteht nun sichtbar aus Config Agent, Monit, dem Go Monit XML Exporter und Grafana Alloy. Der Exporter liest Monit lokal und stellt Prometheus-Metriken nur auf `127.0.0.1:9108` bereit. Alloy scrapt diese Metriken und sendet sie ueber den separaten Observability-Ingest an Prometheus. Journal-Logs gehen an Loki.

Die GUI zeigt ausserdem die konkreten Baseline-Artefakte und trennt sie weiterhin von workload-spezifischen Monit-Checks und Alloy-Pipelines, die in Git/Managed Configs bleiben.

# Release Notes 3.15.0

3.15.0 konsolidiert die Plattformarchitektur. Die kontinuierliche Observability-Datenebene ist vom Config Manager getrennt, Host-Identitaet und Labels werden durchgaengig verwendet, der Datei-Manager kennt Konfigurations-Ownership, und Agent-Tokens koennen capability-basiert eingeschraenkt werden.

Der Baseline-Secret-Store liegt jetzt unter `/var/lib/service/config-agent/secrets/`. Dadurch kann die privilegierte Baseline ihre eigenen lokalen Credentials atomar verwalten, waehrend `/opt/service/env` weiterhin read-only bleibt.

## 3.14.3

Monit-Credentials werden nun robust als gequotete Basic-Auth-Zugangsdaten erzeugt. Das behebt insbesondere Configtest-Fehler bei rein numerischen Passwoertern.

Die Client-Baseline wurde fuer Statusabfragen deutlich beschleunigt: Paketmanager-Repository-Abfragen werden nicht mehr bei jedem Seitenladen ausgefuehrt, sondern nur noch wenn eine Installation tatsaechlich gestartet wird.

## 3.14.2

Der portalweite Ladeindikator ist jetzt zentral und eindeutig sichtbar statt unten rechts. Netzwerk- und Navigations-Busy-Zustaende werden garantiert aufgeraeumt; ein verlorenes Browser-/Library-Event kann den Spinner nicht mehr dauerhaft stehen lassen.

# Release Notes 3.14.1

## Client Baseline

Die Baseline behandelt vorhandene Monit-Installationen jetzt als uebernehmbaren Bestand. Ein bereits in `/etc/monitrc` bzw. der distributionsspezifischen Hauptdatei vorhandener `set httpd`-Block wird vor der Aenderung gesichert und in die vom Config Manager verwaltete Drop-in-Datei migriert. Erst danach laufen `monit -t`, Service-Aktivierung und Credential-Speicherung. Bei einem Fehler wird der vorherige Zustand wiederhergestellt.

Grafana Alloy erhaelt standardmaessig die zentralen Ziele des Config Managers:

- Loki: `/api/observability_loki_push.php`
- Prometheus Remote Write: `/api/observability_prometheus_write.php`

Die beiden Ingest-Endpunkte akzeptieren nur registrierte Config-Agent-Tokens und leiten danach lokal an Loki bzw. Prometheus weiter. Dadurch ist kein zweites Shared Secret fuer die Client-Baseline erforderlich. Die URL-Basis wird ueber `CONFIG_MANAGER_PUBLIC_BASE_URL` definiert.

Ist Alloy noch nicht installiert oder fehlt die Paketquelle, kann die Basiskonfiguration trotzdem vorbereitet werden. Auf SUSE/openSUSE bietet die Baseline ausserdem die kontrollierte Einrichtung des offiziellen Grafana-RPM-Repositorys und die anschliessende Installation von `alloy` an. Die Aktivierung erfolgt nach erfolgreicher Installation des Alloy-Binaries.

## UI

Der globale Ladeindikator verwendet jetzt pro Request/Aktion eigene Tokens statt eines einfachen Counters. Abbruch-, Fehler-, Navigation- und BFCache-Pfade bereinigen ihren Zustand explizit; dadurch bleibt die Anzeige nicht mehr dauerhaft in der Ecke stehen.

### 3.18.1 – Git als Source of Truth fuer Observability-Paketplan
`deploy-profile.json` im Forgejo-Repository `observability-client` ist jetzt nicht mehr nur Dokumentation. Git Deploy liest die Datei aus dem freigegebenen Commit und installiert die dort deklarierten Pakete aus dem internen RPM-Repository. Damit ist nachvollziehbar, wie ein neuer Host Monit, Alloy, den Monit-Prometheus-Exporter und das Meta-Paket erhaelt, ohne Installationsskripte oder grosse RPM-Binaries in Git zu speichern.
