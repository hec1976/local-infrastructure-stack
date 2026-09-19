#!/bin/bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

echo "Dieses Skript entfernt Services/Proxy, aber NICHT automatisch /srv/forgejo/data."
read -r -p "Forgejo-Dienste wirklich entfernen? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || exit 0

systemctl disable --now forgejo-backup.timer 2>/dev/null || true
systemctl disable --now forgejo.service 2>/dev/null || true
rm -f /etc/containers/systemd/forgejo.container /etc/containers/systemd/forgejo.network
rm -f /etc/systemd/system/forgejo-backup.service /etc/systemd/system/forgejo-backup.timer
rm -f /etc/apache2/vhosts.d/forgejo-teko.conf
rm -f /usr/local/sbin/forgejo-backup.sh /usr/local/sbin/forgejo-update.sh
rm -f /usr/local/sbin/forgejo-health.sh /usr/local/sbin/setup-config-manager-git.sh
systemctl daemon-reload
systemctl restart apache2 2>/dev/null || true

echo "Forgejo-Service entfernt."
echo "Daten bleiben erhalten: /srv/forgejo/data"
echo "Backups bleiben erhalten: /srv/forgejo/backup"
