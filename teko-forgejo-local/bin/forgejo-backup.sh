#!/bin/bash
set -euo pipefail
umask 077
FORGEJO_BASE="${FORGEJO_BASE:-/srv/forgejo}"
FORGEJO_BACKUP="${FORGEJO_BACKUP:-${FORGEJO_BASE}/backup}"
KEEP_DAYS="${FORGEJO_BACKUP_KEEP_DAYS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${FORGEJO_BACKUP}/forgejo-${STAMP}.tar.gz"
mkdir -p "$FORGEJO_BACKUP"
was_active=0
if systemctl is-active --quiet forgejo.service; then
  was_active=1
  systemctl stop forgejo.service
fi
cleanup(){ [[ "$was_active" -eq 1 ]] && systemctl start forgejo.service || true; }
trap cleanup EXIT
tar --numeric-owner -C "$FORGEJO_BASE" -czf "$ARCHIVE" data
chmod 600 "$ARCHIVE"
find "$FORGEJO_BACKUP" -type f -name 'forgejo-*.tar.gz' -mtime "+$KEEP_DAYS" -delete
echo "Backup erstellt: $ARCHIVE"
