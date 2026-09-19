#!/bin/bash
set -euo pipefail
PORT="${FORGEJO_HTTP_PORT:-3000}"
failed=0
echo "Forgejo systemd : $(systemctl is-active forgejo.service 2>/dev/null || true)"
echo "Apache          : $(systemctl is-active apache2 2>/dev/null || true)"
echo "Backup timer    : $(systemctl is-active forgejo-backup.timer 2>/dev/null || true)"
if podman ps --format '{{.Names}}' | grep -qx forgejo; then
  echo "Container       : running"
else
  echo "Container       : NOT RUNNING"
  failed=1
fi
if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null; then
  echo "HTTP localhost  : OK"
else
  echo "HTTP localhost  : FEHLER"
  failed=1
fi
df -h /srv/forgejo 2>/dev/null || true
exit "$failed"
