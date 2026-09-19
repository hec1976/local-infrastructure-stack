#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$ROOT/teko-stack.conf"
[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausführen." >&2; exit 1; }

APACHE_GROUP="${APACHE_GROUP:-www}"
STATE="/var/lib/teko-agent-enrollment"
CFGDIR="/opt/service/config-manager"
ENVDIR="/opt/service/env/enrollment"
KEY="$ENVDIR/id_ed25519"
BUNDLE="$CFGDIR/bootstrap/teko-agent-bundle.tar.gz"

zypper --non-interactive install openssh tar gzip python3 >/dev/null

PYTHON3_BIN="$(command -v python3 || true)"
[[ -n "$PYTHON3_BIN" ]] || { echo "FEHLER: python3 wurde nicht gefunden." >&2; exit 1; }
"$PYTHON3_BIN" - <<'PYCOMPAT'
import sys
if sys.version_info < (3, 6):
    raise SystemExit("FEHLER: Agent Enrollment benoetigt Python >= 3.6; gefunden: %s" % (sys.version.split()[0],))
print("Agent Enrollment Python: %s" % (sys.version.split()[0],))
PYCOMPAT
"$PYTHON3_BIN" -m py_compile "$ROOT/bin/teko-agent-enrollment-worker.py"

PASSWORD_AUTH_AVAILABLE=true
if ! command -v sshpass >/dev/null 2>&1; then
  if ! zypper --non-interactive install sshpass >/dev/null 2>&1; then
    PASSWORD_AUTH_AVAILABLE=false
    echo "WARN: sshpass konnte nicht installiert werden; Passwort-Enrollment bleibt deaktiviert." >&2
  fi
fi
command -v sshpass >/dev/null 2>&1 || PASSWORD_AUTH_AVAILABLE=false

install -d -o root -g "$APACHE_GROUP" -m 0750 "$CFGDIR" "$CFGDIR/bootstrap" "$CFGDIR/ca"
install -d -o root -g "$APACHE_GROUP" -m 0750 /opt/service/config-manager/tokens
install -d -o root -g root -m 0700 "$ENVDIR"
install -d -o root -g "$APACHE_GROUP" -m 2770 "$STATE/queue"
install -d -o root -g "$APACHE_GROUP" -m 2770 "$STATE/incoming"
install -d -o root -g "$APACHE_GROUP" -m 2750 "$STATE/status"
install -d -o root -g "$APACHE_GROUP" -m 2770 "$STATE/secrets"
# Control queue is the only web-writable path used for privileged lifecycle actions
# such as deleting completed/failed jobs. Status/work stay root-owned.
install -d -o root -g "$APACHE_GROUP" -m 2770 "$STATE/control"
install -d -o root -g root -m 0700 "$STATE/work"

if [[ ! -f "$KEY" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C 'teko-agent-enrollment' -f "$KEY"
fi
chmod 0600 "$KEY"
chown root:root "$KEY"
chown root:"$APACHE_GROUP" "$KEY.pub"
chmod 0640 "$KEY.pub"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/teko-agent-bundle/bin"
cp -a "$ROOT/config-agent" "$TMP/teko-agent-bundle/"
cp "$ROOT/setup_config_agent.sh" "$ROOT/setup_remote_config_agent.sh" "$ROOT/teko-stack.conf" "$TMP/teko-agent-bundle/"
cp "$ROOT/bin/teko-hosts.sh" "$TMP/teko-agent-bundle/bin/"
if [[ ! -r /etc/apache2/ssl/config-manager.crt ]]; then
  echo "FEHLER: Config-Manager TLS-Zertifikat nicht lesbar: /etc/apache2/ssl/config-manager.crt" >&2
  exit 1
fi
cp /etc/apache2/ssl/config-manager.crt "$TMP/teko-agent-bundle/config-manager-ca.crt"
tar -C "$TMP" -czf "$BUNDLE.new" teko-agent-bundle
chown root:"$APACHE_GROUP" "$BUNDLE.new"; chmod 0640 "$BUNDLE.new"; mv -f "$BUNDLE.new" "$BUNDLE"

MANAGER_IP="${CONFIG_MANAGER_ENROLLMENT_IP:-$SERVER_IP}"
cat > "$CFGDIR/enrollment.json.new" <<EOF
{
  "schema_version": 1,
  "web_group": "$APACHE_GROUP",
  "manager_ip": "$MANAGER_IP",
  "agent_port": 5008,
  "forgejo_fqdn": "$FORGEJO_FQDN",
  "config_manager_fqdn": "$CONFIG_MANAGER_FQDN",
  "grafana_fqdn": "$GRAFANA_FQDN",
  "forgejo_token_file": "/opt/service/env/forgejo-api.token",
  "ssh_key": "$KEY",
  "known_hosts": "$ENVDIR/known_hosts",
  "password_auth_available": $PASSWORD_AUTH_AVAILABLE,
  "secret_dir": "$STATE/secrets",
  "bundle": "$BUNDLE",
  "queue_dir": "$STATE/queue",
  "incoming_dir": "$STATE/incoming",
  "status_dir": "$STATE/status",
  "control_dir": "$STATE/control",
  "state_dir": "$STATE/work",
  "registry": "/opt/service/config-manager/servers.json",
  "ca_dir": "$CFGDIR/ca",
  "token_dir": "/opt/service/config-manager/tokens"
}
EOF
chown root:"$APACHE_GROUP" "$CFGDIR/enrollment.json.new"; chmod 0640 "$CFGDIR/enrollment.json.new"
mv -f "$CFGDIR/enrollment.json.new" "$CFGDIR/enrollment.json"

install -o root -g root -m 0750 "$ROOT/bin/teko-agent-enrollment-worker.py" /usr/local/sbin/teko-agent-enrollment-worker

cat > /etc/systemd/system/teko-agent-enrollment.service <<'EOF'
[Unit]
Description=Agent Enrollment Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/bin/python3 /usr/local/sbin/teko-agent-enrollment-worker
PrivateTmp=true
ProtectHome=read-only
ProtectSystem=strict
ReadWritePaths=/var/lib/teko-agent-enrollment /opt/service/config-manager /opt/service/config-manager/tokens /opt/service/env/enrollment
NoNewPrivileges=true
RestrictSUIDSGID=true
LockPersonality=true
EOF

cat > /etc/systemd/system/teko-agent-enrollment.path <<'EOF'
[Unit]
Description=Watch TEKO Agent Enrollment Queue

[Path]
# PathChanged catches the atomic rename of a completed queue item.
# DirectoryNotEmpty also picks up jobs that were already queued before the
# path unit was started/restarted.  Do not rely on PathExistsGlob alone: on
# some systemd/SUSE combinations an already true glob is not a reliable edge
# trigger for repeated one-shot processing.
PathChanged=/var/lib/teko-agent-enrollment/queue
DirectoryNotEmpty=/var/lib/teko-agent-enrollment/queue
PathChanged=/var/lib/teko-agent-enrollment/control
DirectoryNotEmpty=/var/lib/teko-agent-enrollment/control
Unit=teko-agent-enrollment.service

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/teko-agent-enrollment.timer <<'EOF'
[Unit]
Description=Fallback poll for TEKO Agent Enrollment Queue

[Timer]
OnBootSec=20s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=teko-agent-enrollment.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now teko-agent-enrollment.path teko-agent-enrollment.timer
# Consume jobs that may already exist from a previous version immediately.
if compgen -G "$STATE/queue/*.json" >/dev/null; then
  systemctl start teko-agent-enrollment.service || true
fi

echo "Agent Enrollment Manager installiert."
echo "Bootstrap Public Key:"
cat "$KEY.pub"
echo
echo "SSH-Key-Modus: Diesen Public Key einmalig in authorized_keys der Zielsysteme hinterlegen."
if [[ "$PASSWORD_AUTH_AVAILABLE" == true ]]; then
  echo "Passwort-Modus: verfuegbar (sshpass installiert; Passwort wird nur temporaer pro Job gehalten)."
else
  echo "Passwort-Modus: nicht verfuegbar (sshpass fehlt)."
fi
