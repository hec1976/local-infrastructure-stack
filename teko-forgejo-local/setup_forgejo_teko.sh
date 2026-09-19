#!/bin/bash
set -euo pipefail
umask 027

# openSUSE: administrative tools such as a2enmod may live in /usr/sbin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# TEKO Forgejo local setup
STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC1090
source "$STACK_ROOT/teko-stack.conf"

FORGEJO_IMAGE="${FORGEJO_IMAGE:-codeberg.org/forgejo/forgejo:15-rootless}"
FORGEJO_HTTP_PORT="${FORGEJO_HTTP_PORT:-3000}"
FORGEJO_SSH_PORT="${FORGEJO_SSH_PORT:-2222}"
FORGEJO_BASE="${FORGEJO_BASE:-/srv/forgejo}"
FORGEJO_DATA="${FORGEJO_BASE}/data"
FORGEJO_BACKUP="${FORGEJO_BASE}/backup"
QUADLET_DIR="/etc/containers/systemd"
APACHE_SSL_DIR="/etc/apache2/ssl"
APACHE_CERT="${APACHE_SSL_DIR}/forgejo-teko.crt"
APACHE_KEY="${APACHE_SSL_DIR}/forgejo-teko.key"
APACHE_VHOST="/etc/apache2/vhosts.d/forgejo-teko.conf"

log(){ printf '\n>>> %s\n' "$*"; }
die(){ echo "FEHLER: $*" >&2; exit 1; }


[[ $EUID -eq 0 ]] || die "Bitte als root/sudo ausfuehren."

log "1/10 Hostname und lokale Namensaufloesung"
"$STACK_ROOT/bin/teko-hosts.sh"

log "2/10 Pakete installieren"
zypper --non-interactive refresh
zypper --non-interactive install podman git curl rsync openssl apache2 python3
if [[ "${TEKO_FORCE:-0}" == "1" ]]; then
    echo "FORCE: Forgejo Service-/Proxy-Definitionen werden neu erzeugt; Repositories und Secrets bleiben erhalten."
    rm -f /etc/containers/systemd/forgejo.container /etc/apache2/vhosts.d/forgejo-teko.conf 2>/dev/null || true
fi
systemctl enable apache2

log "3/10 Persistente Daten vorbereiten"
mkdir -p "$FORGEJO_DATA" "$FORGEJO_BACKUP"
chown -R 1000:1000 "$FORGEJO_DATA"
chmod 750 "$FORGEJO_BASE" "$FORGEJO_DATA"
chmod 700 "$FORGEJO_BACKUP"

log "4/10 Podman Quadlet installieren"
mkdir -p "$QUADLET_DIR"

cat > "$QUADLET_DIR/forgejo.network" <<'EOF'
[Network]
NetworkName=forgejo
EOF

cat > "$QUADLET_DIR/forgejo.container" <<EOF
[Unit]
Description=Forgejo TEKO local Git service
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=forgejo
Image=${FORGEJO_IMAGE}
User=1000:1000
Network=forgejo.network
PublishPort=127.0.0.1:${FORGEJO_HTTP_PORT}:3000
PublishPort=0.0.0.0:${FORGEJO_SSH_PORT}:2222
Volume=${FORGEJO_DATA}:/var/lib/gitea
Volume=/etc/localtime:/etc/localtime:ro

Environment=USER_UID=1000
Environment=USER_GID=1000
Environment=FORGEJO__database__DB_TYPE=sqlite3
Environment=FORGEJO__database__PATH=/var/lib/gitea/data/forgejo.db
Environment=FORGEJO__server__DOMAIN=${FORGEJO_FQDN}
Environment=FORGEJO__server__ROOT_URL=https://${FORGEJO_FQDN}/
Environment=FORGEJO__server__HTTP_PORT=3000
Environment=FORGEJO__server__SSH_DOMAIN=${FORGEJO_FQDN}
Environment=FORGEJO__server__SSH_PORT=${FORGEJO_SSH_PORT}
Environment=FORGEJO__server__SSH_LISTEN_PORT=2222
Environment=FORGEJO__server__START_SSH_SERVER=true
Environment=FORGEJO__service__DEFAULT_KEEP_EMAIL_PRIVATE=true
Environment=FORGEJO__service__ENABLE_NOTIFY_MAIL=false
Environment=FORGEJO__repository__DEFAULT_PRIVATE=private
Environment=FORGEJO__repository__ENABLE_PUSH_CREATE_USER=false
Environment=FORGEJO__repository__ENABLE_PUSH_CREATE_ORG=false
Environment=FORGEJO__openid__ENABLE_OPENID_SIGNIN=false
Environment=FORGEJO__openid__ENABLE_OPENID_SIGNUP=false
Environment=FORGEJO__server__OFFLINE_MODE=true
# Greenfield-sicher: Web-Installationswizard deaktivieren. Die komplette
# Initialisierung (DB/Admin/Org/Repo/Token) erfolgt automatisiert.
Environment=FORGEJO__security__INSTALL_LOCK=true

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=180
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$QUADLET_DIR/forgejo.network" "$QUADLET_DIR/forgejo.container"
systemctl daemon-reload

# Diagnose: sicherstellen, dass Quadlet die Unit erfolgreich generiert hat.
if ! systemctl cat forgejo.service >/dev/null 2>&1; then
    echo "FEHLER: forgejo.service wurde aus forgejo.container nicht generiert." >&2
    echo "Quadlet-Diagnose:" >&2
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze --generators=true verify forgejo.service || true
    fi
    if [[ -x /usr/lib/systemd/system-generators/podman-system-generator ]]; then
        /usr/lib/systemd/system-generators/podman-system-generator --dryrun || true
    fi
    exit 1
fi

log "5/10 Forgejo LTS Image laden und starten"
# Registry-Ausfaelle (z. B. HTTP 503 bei Codeberg) duerfen eine bereits
# funktionsfaehige lokale Installation nicht unnoetig blockieren. Ein lokal
# vorhandenes Image wird deshalb standardmaessig weiterverwendet. Mit
# TEKO_FORGEJO_FORCE_PULL=1 kann ein Pull explizit erzwungen werden.
FORGEJO_PULL_RETRIES="${FORGEJO_PULL_RETRIES:-5}"
FORGEJO_PULL_DELAY="${FORGEJO_PULL_DELAY:-10}"
TEKO_FORGEJO_FORCE_PULL="${TEKO_FORGEJO_FORCE_PULL:-0}"

pull_forgejo_image() {
    local attempt delay
    delay="$FORGEJO_PULL_DELAY"
    for attempt in $(seq 1 "$FORGEJO_PULL_RETRIES"); do
        echo "Forgejo Image Pull: Versuch ${attempt}/${FORGEJO_PULL_RETRIES} ..."
        if podman pull "$FORGEJO_IMAGE"; then
            return 0
        fi
        if (( attempt < FORGEJO_PULL_RETRIES )); then
            echo "WARNUNG: Forgejo Registry momentan nicht erreichbar. Neuer Versuch in ${delay}s ..." >&2
            sleep "$delay"
            # Begrenztes Backoff, damit ein temporaerer Registry-Ausfall abgefangen wird.
            if (( delay < 30 )); then
                delay=$(( delay * 2 ))
                (( delay > 30 )) && delay=30
            fi
        fi
    done
    return 1
}

if podman image exists "$FORGEJO_IMAGE" && [[ "$TEKO_FORGEJO_FORCE_PULL" != "1" ]]; then
    echo "Forgejo Image bereits lokal vorhanden; Registry-Pull wird uebersprungen."
else
    if ! pull_forgejo_image; then
        if podman image exists "$FORGEJO_IMAGE"; then
            echo "WARNUNG: Registry-Pull fehlgeschlagen; vorhandenes lokales Forgejo Image wird verwendet." >&2
        else
            die "Forgejo Image konnte nach ${FORGEJO_PULL_RETRIES} Versuchen nicht geladen werden. Registry spaeter erneut versuchen."
        fi
    fi
fi
# Quadlet erzeugt forgejo.service dynamisch.
# Ein generierter Quadlet-Service darf NICHT mit "systemctl enable" aktiviert
# werden. Der Autostart wird vom Quadlet-Generator anhand von
# [Install] WantedBy=multi-user.target eingerichtet.
systemctl restart forgejo.service

# Auf einem komplett neuen Server muss Forgejo zuerst SQLite initialisieren.
# Die Startseite allein ist kein Readiness-Nachweis (sie kann bereits waehrend
# des Installationszustands HTTP 200 liefern). Bootstrap prueft danach DB/CLI
# und die echte REST-API. Hier wird nur der Dienststart abgesichert.
for _ in $(seq 1 180); do
    systemctl is-active --quiet forgejo.service && \
      curl -fsS "http://127.0.0.1:${FORGEJO_HTTP_PORT}/" >/dev/null 2>&1 && break
    sleep 1
done

systemctl is-active --quiet forgejo.service || {
    journalctl -u forgejo.service --no-pager -n 100 || true
    die "Forgejo startet nicht."
}

log "6/10 Apache HTTPS Reverse Proxy"
a2enmod ssl || true
a2enmod proxy || true
a2enmod proxy_http || true
a2enmod headers || true
a2enmod rewrite || true
mkdir -p "$APACHE_SSL_DIR"

if [[ ! -f "$APACHE_CERT" || ! -f "$APACHE_KEY" ]]; then
    openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
        -keyout "$APACHE_KEY" \
        -out "$APACHE_CERT" \
        -subj "/CN=${FORGEJO_FQDN}" \
        -addext "subjectAltName=DNS:${FORGEJO_FQDN},DNS:${SERVER_FQDN},DNS:${SERVER_SHORTNAME},IP:${SERVER_IP}"
    chown root:root "$APACHE_KEY" "$APACHE_CERT"
    chmod 600 "$APACHE_KEY"
    chmod 644 "$APACHE_CERT"
fi

mkdir -p /etc/apache2/conf.d
cat > "$APACHE_VHOST" <<EOF
<VirtualHost *:80>
    ServerName ${FORGEJO_FQDN}
    Redirect permanent / https://${FORGEJO_FQDN}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${FORGEJO_FQDN}

    SSLEngine on
    SSLCertificateFile ${APACHE_CERT}
    SSLCertificateKeyFile ${APACHE_KEY}

    ProxyPreserveHost On
    AllowEncodedSlashes NoDecode
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "443"

    ProxyPass        / http://127.0.0.1:${FORGEJO_HTTP_PORT}/ nocanon
    ProxyPassReverse / http://127.0.0.1:${FORGEJO_HTTP_PORT}/

    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "same-origin"
    Header always set X-Frame-Options "SAMEORIGIN"

    ErrorLog /var/log/apache2/forgejo_teko_error.log
    CustomLog /var/log/apache2/forgejo_teko_access.log combined
</VirtualHost>
EOF

"$STACK_ROOT/bin/teko-apache-https.sh"

log "6b/10 TEKO Forgejo Organisation / Repository / Service-User"
chmod 0755 "$STACK_ROOT/bin/forgejo-bootstrap-teko.sh" 2>/dev/null || true
/bin/bash "$STACK_ROOT/bin/forgejo-bootstrap-teko.sh"

log "7/10 Firewall"
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port="${FORGEJO_SSH_PORT}/tcp"
    firewall-cmd --reload
else
    echo "firewalld nicht aktiv; keine Regeln geaendert."
fi

log "8/10 Backup/Update/Health-Skripte installieren"
install -o root -g root -m 0750 "$(dirname "$0")/bin/forgejo-backup.sh" /usr/local/sbin/forgejo-backup.sh
install -o root -g root -m 0750 "$(dirname "$0")/bin/forgejo-update.sh" /usr/local/sbin/forgejo-update.sh
install -o root -g root -m 0750 "$(dirname "$0")/bin/forgejo-health.sh" /usr/local/sbin/forgejo-health.sh

cat > /etc/systemd/system/forgejo-backup.service <<EOF
[Unit]
Description=Consistent Forgejo backup
RequiresMountsFor=${FORGEJO_BASE}
After=local-fs.target

[Service]
Type=oneshot
Environment=FORGEJO_BASE=${FORGEJO_BASE}
Environment=FORGEJO_BACKUP=${FORGEJO_BACKUP}
ExecStart=/usr/local/sbin/forgejo-backup.sh
EOF

cat > /etc/systemd/system/forgejo-backup.timer <<'EOF'
[Unit]
Description=Daily Forgejo backup

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now forgejo-backup.timer

log "9/10 Config-Manager Git Helper installieren"
install -o root -g root -m 0750 "$(dirname "$0")/bin/setup-config-manager-git.sh" /usr/local/sbin/setup-config-manager-git.sh

log "10/10 Endkontrolle"
/usr/local/sbin/forgejo-health.sh || true

echo
echo "======================================================================"
echo " Forgejo bereit"
echo "======================================================================"
echo "Server Hostname : $(teko_hostname)"
echo "Server FQDN     : ${SERVER_FQDN}"
echo "Server IP       : $SERVER_IP"
echo "Web             : https://${FORGEJO_FQDN}/"
echo "Git SSH         : ssh://git@${FORGEJO_FQDN}:${FORGEJO_SSH_PORT}/USER/REPO.git"
echo "Forgejo Image   : ${FORGEJO_IMAGE}"
echo "Daten           : ${FORGEJO_DATA}"
echo "Backups         : ${FORGEJO_BACKUP}"
echo
echo "Lokale Namensaufloesung:"
echo "  ${SERVER_IP}  ${SERVER_FQDN} ${SERVER_SHORTNAME} ${FORGEJO_FQDN} git"
echo
echo "Naechste Schritte:"
echo "  1. /etc/hosts bzw. Client-hosts kontrollieren"
echo "  2. https://${FORGEJO_FQDN}/ aufrufen"
echo "  3. Forgejo-Ersteinrichtung/Admin wird automatisch angelegt"
echo "     Admin-Zugang: /opt/service/env/forgejo-admin.env (root:root 0600)"
echo "  4. Repository-Struktur wird danach automatisch verwaltet: ${FORGEJO_ORG}/${FORGEJO_REPO}"
echo "  5. Service-User/Team: ${FORGEJO_SERVICE_USER} / ${FORGEJO_TEAM}"
echo "======================================================================"
