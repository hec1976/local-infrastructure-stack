#!/bin/bash
set -euo pipefail
umask 077

# Erzeugt einen dedizierten SSH-Key fuer den Config-Manager.
# Der private Key bleibt lokal; nur den ausgegebenen Public Key in Forgejo
# als Deploy Key oder beim technischen Benutzer hinterlegen.

FORGEJO_HOST="${FORGEJO_HOST:-git.local}"
FORGEJO_SSH_PORT="${FORGEJO_SSH_PORT:-2222}"
KEY_DIR="${CONFIG_MANAGER_GIT_KEY_DIR:-/opt/service/config-manager-git}"
KEY_FILE="${KEY_DIR}/id_ed25519"
KNOWN_HOSTS="${KEY_DIR}/known_hosts"

[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [[ ! -f "$KEY_FILE" ]]; then
  ssh-keygen -t ed25519 -a 64 -N '' -C "config-manager@teko" -f "$KEY_FILE"
else
  echo "SSH-Key existiert bereits und wird nicht ersetzt."
fi
chmod 600 "$KEY_FILE"
chmod 644 "${KEY_FILE}.pub"

echo "Forgejo Host-Key erfassen..."
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
ssh-keyscan -p "$FORGEJO_SSH_PORT" "$FORGEJO_HOST" > "$tmp" 2>/dev/null
[[ -s "$tmp" ]] || { echo "Forgejo SSH ist nicht erreichbar." >&2; exit 1; }
install -o root -g root -m 0644 "$tmp" "$KNOWN_HOSTS"

echo
echo "======================================================================"
echo " Public Key fuer Forgejo"
echo "======================================================================"
cat "${KEY_FILE}.pub"
echo
echo "Diesen Public Key in Forgejo beim technischen Benutzer oder als"
echo "Deploy-Key des Config-Repositories hinterlegen."
echo
echo "Private Key : $KEY_FILE"
echo "Known Hosts : $KNOWN_HOSTS"
echo
echo "Beispiel SSH-URL:"
echo "  ssh://git@${FORGEJO_HOST}:${FORGEJO_SSH_PORT}/<owner>/<repo>.git"
echo
echo "Test:"
echo "  GIT_SSH_COMMAND='ssh -i ${KEY_FILE} -o UserKnownHostsFile=${KNOWN_HOSTS}' \\"
echo "    git ls-remote ssh://git@${FORGEJO_HOST}:${FORGEJO_SSH_PORT}/<owner>/<repo>.git"
echo "======================================================================"
