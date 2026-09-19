#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT/teko-stack.conf"
[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }
command -v zypper >/dev/null 2>&1 || { echo "zypper fehlt." >&2; exit 1; }

# Der Management-Server konsumiert sein eigenes Repository direkt vom Dateisystem.
# Remote-Clients verwenden weiterhin BASELINE_REPO_URL (HTTPS). Damit haengt das
# lokale Setup weder von DNS/TLS noch vom Apache-Publishingpfad ab.
LOCAL_REPO_URL="${BASELINE_REPO_LOCAL_URL:-file://${BASELINE_REPO_DIR%/}/}"
[[ -s "${BASELINE_REPO_DIR%/}/repodata/repomd.xml" ]] || {
    echo "FEHLER: Lokales Baseline-Repository ist nicht bereit: ${BASELINE_REPO_DIR%/}/repodata/repomd.xml" >&2
    exit 1
}

# Repository-ID bewusst idempotent auf die lokale Quelle setzen.
zypper --non-interactive removerepo infrastructure-baseline >/dev/null 2>&1 || true
zypper --non-interactive addrepo -G --check --refresh "$LOCAL_REPO_URL" infrastructure-baseline
zypper --non-interactive refresh infrastructure-baseline
zypper --non-interactive install monit-prometheus-exporter

SECRET_FILE="/var/lib/service/config-agent/secrets/monit-status.env"
[[ -f "$SECRET_FILE" ]] || {
    echo "FEHLER: Monit-Credential fehlt: $SECRET_FILE" >&2
    echo "Bitte zuerst die Monit-Basis konfigurieren." >&2
    exit 1
}
systemctl daemon-reload
systemctl enable --now monit-prometheus-exporter.service
systemctl restart monit-prometheus-exporter.service
for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:9108/metrics 2>/dev/null | grep -q '^monit_up 1'; then
        echo "Monit Exporter aus RPM aktiv: http://127.0.0.1:9108/metrics"
        exit 0
    fi
    sleep .25
done
echo "FEHLER: RPM ist installiert, Exporter kann Monit aber nicht erfolgreich lesen." >&2
journalctl -u monit-prometheus-exporter.service --no-pager -n 50 || true
exit 1
