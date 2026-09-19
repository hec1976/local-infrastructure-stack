# Managed Client Baseline Repository

Dieses Repository ist die **umgebungsneutrale Paketquelle** der generischen Managed-Client-Baseline.
Die Baseline selbst kopiert keine Binaries und erzeugt keine systemd-Units fuer
Softwarepakete. Installation und Updates laufen ausschliesslich ueber RPM/zypper.

## Pakete

- `monit` – Distributionspaket, gespiegelt/freigegeben
- `alloy` – Grafana Alloy, gespiegelt/freigegeben
- `monit-prometheus-exporter` – eigenes Go/RPM-Paket
- `client-baseline` – Meta-RPM, zieht die drei Pakete ein

## Einmalige Vorbereitung auf dem Management-/Repository-Builder

```bash
sudo ./baseline-repository/scripts/prepare_repository.sh
```

Das Skript baut das eigene Exporter-RPM, uebernimmt vorab abgelegte RPMs aus
`baseline-repository/packages/`, kann fehlende Vendor-Pakete mit `--fetch`
nachladen und erzeugt anschliessend ein `createrepo_c`-Repository unter
`/srv/www/baseline-repo`.

Offline-Betrieb: die freigegebenen Monit-/Alloy-RPMs vorab nach
`baseline-repository/packages/` legen und **ohne** `--fetch` vorbereiten.

## Client

Manuell kann ein Client mit folgendem Skript angebunden werden:

```bash
sudo ./baseline-repository/install.sh https://config-manager.local/baseline-repo/
```

Der Config Manager verwendet denselben Ablauf automatisch im Tab
`Managed Hosts -> Baseline`.

## Trennung von Produkt und Umgebung

Die Paketnamen, systemd-Units und Metriken sind absichtlich generisch. `TEKO` ist ein Deployment-/Umgebungsprofil und wird ausserhalb dieser generischen Paketquelle konfiguriert.
