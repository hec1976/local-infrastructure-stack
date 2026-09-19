#!/bin/bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }
URL="${1:-${BASELINE_REPO_URL:-https://config-manager.local/baseline-repo/}}"
[[ "$URL" =~ ^https://[A-Za-z0-9._:-]+/[A-Za-z0-9._~:/-]*/?$ ]] || { echo "Ungueltige HTTPS Repository-URL: $URL" >&2; exit 1; }
command -v zypper >/dev/null 2>&1 || { echo "Dieses Installationsskript benoetigt zypper (SLES/openSUSE)." >&2; exit 1; }
zypper --non-interactive removerepo teko-baseline >/dev/null 2>&1 || true  # legacy 3.16.0 repo id
zypper --non-interactive removerepo infrastructure-baseline >/dev/null 2>&1 || true
zypper --non-interactive addrepo -G --check --refresh "$URL" infrastructure-baseline
zypper --non-interactive --gpg-auto-import-keys refresh infrastructure-baseline
zypper --non-interactive install client-baseline
printf '\nBaseline-Pakete installiert. Konfiguration wird anschliessend vom Config Manager angewendet.\n'
