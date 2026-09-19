#!/bin/bash
set -euo pipefail
IMAGE="${FORGEJO_IMAGE:-codeberg.org/forgejo/forgejo:15-rootless}"
echo ">>> Backup"
/usr/local/sbin/forgejo-backup.sh
echo ">>> Image aktualisieren: $IMAGE"
podman pull "$IMAGE"
echo ">>> Forgejo neu starten"
systemctl restart forgejo.service
sleep 2
/usr/local/sbin/forgejo-health.sh
