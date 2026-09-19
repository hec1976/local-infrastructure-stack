# Architektur

## Zielbild

Local Infrastructure Stack ist als lokale Control-Plane fuer Konfiguration, Deployment und
Betrieb eines Linux-Servers aufgebaut. Der Web-Teil soll keine unkontrollierten
root-Rechte erhalten. Der privilegierte Zugriff wird in den Config-Agenten
konzentriert und dort durch Whitelists, feste API-Routen und Dateischutzregeln
begrenzt.

## Komponenten

### Forgejo

Aufgabe:

- lokaler Git Source of Truth
- private Repositories
- Git-Deploy-Quelle
- Ziel fuer kontrollierten Repository-Upload

Betrieb:

- Podman
- systemd Quadlet
- interner HTTP-Port `127.0.0.1:3000`
- Apache HTTPS unter `git.local`
- Git SSH auf TCP/2222

### Config Agent

Aufgabe:

- Lesen und Schreiben freigegebener Konfigurationsdateien
- atomare Sicherung und Restore
- systemd Actions
- Git Deploy
- Git Repository Upload
- Package Management
- ModSecurity-Verwaltung
- Monit Status

Der Agent ist die Sicherheitsgrenze zwischen Webportal und Betriebssystem.

### Config Manager

Aufgabe:

- Bedienoberflaeche
- Serverauswahl
- Config Editor und Vergleich
- Git Deploy und Deploy-Profile
- Fleet/Desired State
- Enrollment
- Package Management
- ModSecurity
- Monitoring und Audit

Das Portal verwendet den Config-Agent als Backend und speichert keine freien
root-Kommandos.

### Monit und Exporter

Monit prueft lokale Dienste und Endpunkte. Der Go-Exporter wandelt den lokalen
XML-Status in Prometheus-Metriken um. Beide Listener sind standardmaessig nur an
Loopback gebunden.

### Observability Data Plane: Alloy, Ingest, Loki, Prometheus und Grafana

Alloy sammelt auf verwalteten Hosts Basis-Logs und Basis-Metriken. Diese Daten laufen nicht durch die PHP-Anwendung des Config Managers. Apache terminiert TLS, authentisiert den host-spezifischen Agent-Token direkt per Basic Auth gegen eine automatisch synchronisierte htpasswd-Datei und proxyt die beiden Ingest-Pfade unmittelbar auf Loki bzw. Prometheus auf localhost. Ein zusaetzlicher Ingest-Dienst ist nicht erforderlich. Grafana visualisiert beide Datenquellen. Die Backend-Ports von Loki und Prometheus bleiben auf dem Management-Server lokal gebunden.


## Drei Ebenen: Management, Client-Baseline, Workload

```text
Management / Control Plane
├── Config Manager
├── Forgejo / Git
└── Server Registry / Desired State
        │
        ▼
Managed Client Baseline
├── Config Agent
├── Monit
└── Grafana Alloy
        │
        ▼
Workload
├── Postfix / Rspamd / Redis
├── Apache / ModSecurity
├── Fail2ban / Firewall
└── eigene Anwendungen
```

Die Client-Baseline ist fuer alle verwalteten Linux-Hosts gleich. Workload-Pakete und deren konkrete Monit-/Alloy-Erweiterungen werden nicht in die Baseline eingebaut, sondern in Forgejo versioniert und ueber Deploy-Profile bzw. Managed Configs zugewiesen.

Der Config Agent stellt zusaetzlich einen geschuetzten Datei-Manager bereit. Dessen `file_manager_roots` sind getrennt von den allgemeinen `allowed_roots`; dadurch kann die GUI nur in explizit freigegebenen Konfigurationsbaeumen Dateien anlegen oder aendern.

## Vertrauensgrenzen

```text
Browser
  |
  | HTTPS + Login + CSRF
  v
Config Manager
  |
  | HTTPS + API Token
  v
Config Agent
  |
  +-- path_guard / allowed_roots
  +-- service/action whitelist
  +-- hard protected paths
  +-- Git host/ref/path checks
  +-- atomic write / backup
  |
  v
Linux / systemd / files / git / zypper
```

## Warum zwei allowed_roots-Modelle existieren

Managed Configs und Git Deploy haben unterschiedliche Risikoprofile.

`allowed_roots` in der allgemeinen Agent-Konfiguration begrenzt Dateien, die im
Config-Editor bearbeitet werden duerfen.

`git_deploy.allowed_roots` begrenzt Deployment-Ziele und Release-Verzeichnisse.
Das verhindert, dass ein formal gueltiges Deploy-Profil an einen beliebigen Ort
im Dateisystem schreibt.

Aktuell:

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

Die MMBB-Pfade bleiben aus Kompatibilitaetsgruenden explizit erlaubt; sie sind
keine implizite globale Freigabe.

## Datenfluss bei Managed Configs

```text
GUI
 |
 | GET /configs
 v
Agent liefert Metadaten
 |
 +-- id
 +-- filename
 +-- category
 +-- service
 +-- actions
 |
 v
GUI rendert Status und erlaubte Aktionen
```

Beim Speichern:

```text
POST /config/<id>
  -> Registry-Eintrag aufloesen
  -> Pfadpruefung
  -> Lock
  -> Backup
  -> atomarer Write
  -> Owner/Group/Mode anwenden
  -> optional Service-Aktion separat ausfuehren
```

## Datenfluss bei Git Deploy

```text
Forgejo Repository
      |
      v
Ref/Commit validieren
      |
      v
sicheres Release-Verzeichnis
      |
      +-- Dateianzahl/Groesse pruefen
      +-- Symlink/LFS/Path-Pruefungen
      +-- Preserve anwenden
      +-- Preflight
      +-- Rechte setzen
      v
atomare Aktivierung
      |
      v
Status/Commit-Marker/Rollback-Daten
```

## Netzwerkprinzip

Interne Backend-Dienste werden soweit moeglich nur auf Loopback gebunden.
Browserzugriff erfolgt ueber Apache HTTPS und definierte lokale FQDNs. Dienste,
die fuer zentrale Systeme geoeffnet werden sollen, muessen separat ueber
Firewall/ACL/TLS freigegeben werden; eine globale Listener-Aenderung ist nicht
der Default.


## Control Plane und Observability Data Plane

```text
CONTROL PLANE                          DATA PLANE
Config Manager                        Grafana Alloy
Forgejo / Git                              |
Server Registry                            | HTTPS + Host Token
       |                                   v
       | HTTPS + Agent Token          Apache Direct Proxy
       v                              |                    |
Config Agent                         v                    v
                                  Loki                Prometheus
```

Der Config Manager transportiert keine kontinuierlichen Log- oder Metrik-Payloads. Die Datenebene besitzt einen eigenen Ingest-Prozess. Damit bleibt die Control Plane auch bei hohem Telemetrievolumen unabhaengig.

## Konfigurations-Ownership

Es gilt genau eine primaere Ownership pro Datei/Pfad:

1. **Client Baseline** verwaltet nur Management-Grundlagen (`Config Agent`, Monit-Basiszugang, Alloy-Basiskonfiguration).
2. **Forgejo / Git** ist die bevorzugte Source of Truth fuer dauerhafte Workload-Konfiguration und Rollenprofile.
3. **Managed Configs** verwalten explizit registrierte Einzeldateien, wenn Git nicht der Besitzer ist.
4. **File Manager** ist ein Expert-/Break-Glass-Werkzeug. Er erkennt bekannte Baseline-, Managed-Config- und Git-Deploy-Ownership und verlangt bei direkten Aenderungen einen bewussten Override.
5. **Security-/Operations-GUIs** (Firewall, Fail2ban, Package Management) verwalten nur ihren jeweiligen operativen Zustandsbereich.

Damit werden konkurrierende Writer bewusst vermieden.

## Host-Identitaet und Labels

Jeder verwaltete Host besitzt eine stabile `host_id`. Enrollment uebernimmt ausserdem `labels` und `groups`. Der Config Agent speichert diese Identitaet lokal in `/var/lib/service/config-agent/identity.json`. Alloy versieht Basis-Telemetrie mit `host_id`, `hostname` und den freigegebenen Labels, sodass Config Manager, Loki und Prometheus dieselbe Host-Identitaet verwenden.

## Agent-Token Scopes

Der Agent-Token kann ueber `CONFIG_AGENT_TOKEN_SCOPES` eingeschraenkt werden. Unterstuetzte Capability-Gruppen sind unter anderem `status.read`, `config.read`, `config.write`, `file.read`, `file.manage`, `baseline.manage`, `package.manage`, `security.manage`, `git.deploy` und `service.control`. Legacy-Installationen ohne Scope-Definition bleiben kompatibel; neue Installationen erhalten explizite Scopes statt Wildcard.

## Versions-Source-of-Truth

`VERSIONS.json` ist die kanonische Versionsquelle des Stacks. `bin/sync-versions.py` synchronisiert daraus `VERSION_STACK`, `VERSION`, Config-Agent-/Config-Manager-Versionen, Runtime-Agent-Version und systemd-Unit-Beschreibung. Dadurch werden widerspruechliche manuell gepflegte Versionsstaende vermieden.


## Package plane fuer die Client Baseline (3.16)

Die Client Baseline ist kein Paketinstaller mehr. Software kommt ueber die Package Plane:

```text
Approved/gespiegelte RPMs
        |
        v
Infrastructure Baseline Repository
  monit / alloy / monit-prometheus-exporter
        |
        v
client-baseline (Meta-RPM)
        |
        v
Package Management / zypper
        |
        v
Client Baseline Konfiguration
  Monit HTTP + Secret
  Alloy config + Secret
  Host-ID/Labels
  enable/start + Healthcheck
```

Binaries und systemd-Units gehoeren dem RPM. Git/Managed Configs bleiben Owner der workload-spezifischen Konfiguration.

### File Manager Zugriff (3.16.3)

Der File Manager trennt Lese- und Schreibfreigaben. Standardmaessig kann ein Administrator das normale Host-Dateisystem ab `/` browsen und regulaere Dateien lesen. Schreibende Operationen sind auf `/etc`, `/opt`, `/srv`, `/var/lib`, `/var/log` und `/usr/local` begrenzt. Die allgemeinen `allowed_roots` des Config-Agent-REST-Service enthalten dieselben administrativen Schreibbereiche, damit eine im File Manager freigegebene Operation nicht spaeter am REST-Path-Guard scheitert. Virtuelle Dateisysteme (`/proc`, `/sys`, `/dev`, `/run`) sowie sicherheitskritische Secrets bleiben gesperrt. Systemd-Units unter `/etc/systemd/system` sind erreichbar, werden aber als systemkritisch markiert und verlangen fuer Schreiboperationen einen Expert-Override.
