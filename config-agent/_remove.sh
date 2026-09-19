#!/usr/bin/env bash
# Entfernt nur die systemd-Installation. Anwendung und Konfiguration bleiben erhalten.
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$DIR/_install.sh" --config "$DIR/service-install.ini" --internal-remove "$@"
