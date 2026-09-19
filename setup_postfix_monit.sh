#!/bin/bash
#
# TEKO Postfix + Monit integration
#
# Postfix:
#   - local-only listener by default (no open relay)
#   - systemd enabled
#   - main.cf and master.cf manageable through Config Manager
#
# Monit:
#   - exactly ONE TEKO monitoring policy file:
#       /etc/monit.d/teko-stack.monitrc
#   - /etc/monitrc is only bootstrap/global config and includes monit.d
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$ROOT/teko-stack.conf"

[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

log(){ printf '\n>>> %s\n' "$*"; }

MONIT_DIR="/etc/monit.d"
MONIT_STACK="$MONIT_DIR/teko-stack.monitrc"
MONIT_BASELINE="$MONIT_DIR/cm-baseline.monitrc"
MONIT_MAIN="/etc/monitrc"
AGENT_DIR="/opt/service/config-agent"
AGENT_MC="$AGENT_DIR/managed_configs.json"
MONIT_SECRET_DIR="/var/lib/service/config-agent/secrets"
MONIT_SECRET_FILE="$MONIT_SECRET_DIR/monit-status.env"

log "1/7 Postfix und Monit installieren"
zypper --non-interactive install postfix monit

log "2/7 Postfix sichere lokale Basis"
mkdir -p /etc/postfix
if [[ -f /etc/postfix/main.cf && ! -f /etc/postfix/main.cf.teko-original ]]; then
    cp -a /etc/postfix/main.cf /etc/postfix/main.cf.teko-original
fi
if [[ -f /etc/postfix/master.cf && ! -f /etc/postfix/master.cf.teko-original ]]; then
    cp -a /etc/postfix/master.cf /etc/postfix/master.cf.teko-original
fi

# WICHTIG fuer openSUSE/SLES:
# Die vom Paket gelieferte main.cf enthaelt plattformspezifische Parameter
# (u.a. setgid_group und Pfade). Diese Datei NICHT durch eine generische
# TEKO-main.cf ersetzen. Bei einem Wiederholungslauf nach einer aelteren
# TEKO-Version wird die urspruengliche Paketdatei zuerst restauriert.
if [[ -f /etc/postfix/main.cf.teko-original ]] && {
     [[ "${TEKO_FORCE:-0}" == "1" ]] || grep -q '^# TEKO local single-server Postfix' /etc/postfix/main.cf 2>/dev/null;
   }; then
    if [[ "${TEKO_FORCE:-0}" == "1" ]]; then
        echo "FORCE: SUSE-Postfix-Paketbasis wird aus main.cf.teko-original restauriert."
    else
        echo "Alte verwaltete Komplettkonfiguration erkannt; SUSE-Paketbasis wird restauriert."
    fi
    cp -a /etc/postfix/main.cf.teko-original /etc/postfix/main.cf
fi

# Vor jeder Aenderung muss die Paketbasis fuer dieses System konsistent sein.
# postconf -h liest dabei bewusst den effektiven SUSE/SLES-Wert und nicht nur
# den kompilierten Postfix-Default (postconf -d).
PACKAGE_SETGID_GROUP="$(postconf -h setgid_group 2>/dev/null || true)"
if [[ -z "$PACKAGE_SETGID_GROUP" ]]; then
    echo "FEHLER: Postfix setgid_group konnte aus der Paketkonfiguration nicht ermittelt werden." >&2
    exit 1
fi
if ! getent group "$PACKAGE_SETGID_GROUP" >/dev/null 2>&1; then
    echo "FEHLER: Die von der SUSE-Postfix-Konfiguration erwartete Gruppe '$PACKAGE_SETGID_GROUP' fehlt." >&2
    echo "       main.cf wird nicht durch den Stack ersetzt. Bitte Postfix-Paketinstallation pruefen." >&2
    exit 1
fi

echo "Postfix Paketbasis: setgid_group=$PACKAGE_SETGID_GROUP"

# Nur die TEKO-eigenen Einstellungen setzen. Alle distributions-/build-
# spezifischen Postfix-Parameter und master.cf bleiben unangetastet.
postconf -e \
    "compatibility_level = 3.6" \
    "myhostname = ${SERVER_FQDN}" \
    "mydomain = local" \
    'myorigin = $myhostname' \
    "inet_interfaces = loopback-only" \
    "inet_protocols = ipv4" \
    'mydestination = $myhostname, localhost.$mydomain, localhost' \
    "mynetworks = 127.0.0.0/8" \
    "relay_domains =" \
    "relayhost =" \
    "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination" \
    "smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination" \
    "smtpd_helo_required = yes" \
    "disable_vrfy_command = yes" \
    "message_size_limit = 26214400" \
    "mailbox_size_limit = 0" \
    "biff = no" \
    "append_dot_mydomain = no"

chown root:root /etc/postfix/main.cf
chmod 0644 /etc/postfix/main.cf
[[ -f /etc/postfix/master.cf ]] && { chown root:root /etc/postfix/master.cf; chmod 0644 /etc/postfix/master.cf; }

postfix check

systemctl enable postfix.service
systemctl restart postfix.service
systemctl is-active --quiet postfix.service || {
    systemctl status postfix.service --no-pager -l || true
    journalctl -u postfix.service -n 80 --no-pager || true
    exit 1
}

log "3/7 Monit Bootstrap vereinheitlichen"
mkdir -p "$MONIT_DIR" /var/lib/monit/events

# Monit, Config Agent und der Go Exporter muessen exakt denselben lokalen
# Credential-Satz verwenden. Vorhandene Baseline-Credentials werden
# beibehalten; auf einem frischen System wird einmalig ein starkes lokales
# Passwort erzeugt. Das Secret liegt bewusst ausserhalb von /opt/service/env,
# weil dieses Verzeichnis fuer den laufenden Config Agent read-only ist.
install -d -o root -g root -m 0700 "$MONIT_SECRET_DIR"
MONIT_HTTP_USER=""
MONIT_HTTP_PASSWORD=""
if [[ -f "$MONIT_SECRET_FILE" && ! -L "$MONIT_SECRET_FILE" ]]; then
    MONIT_HTTP_USER="$(sed -n 's/^MONIT_USER=//p' "$MONIT_SECRET_FILE" | head -n1)"
    MONIT_HTTP_PASSWORD="$(sed -n 's/^MONIT_PASSWORD=//p' "$MONIT_SECRET_FILE" | head -n1)"
fi
if [[ -z "$MONIT_HTTP_USER" || -z "$MONIT_HTTP_PASSWORD" ]]; then
    MONIT_HTTP_USER="monitadmin"
    MONIT_HTTP_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
    umask 077
    cat > "${MONIT_SECRET_FILE}.tmp" <<EOF
MONIT_USER=${MONIT_HTTP_USER}
MONIT_PASSWORD=${MONIT_HTTP_PASSWORD}
EOF
    chown root:root "${MONIT_SECRET_FILE}.tmp"
    chmod 0600 "${MONIT_SECRET_FILE}.tmp"
    mv -f "${MONIT_SECRET_FILE}.tmp" "$MONIT_SECRET_FILE"
fi
chmod 0600 "$MONIT_SECRET_FILE"
chown root:root "$MONIT_SECRET_FILE"

# Alte TEKO-/Paketfragmente aus monit.d entfernen, damit genau eine von
# diesem Stack gepflegte Monitoring-Datei existiert. Fremde Admin-Dateien
# werden NICHT gelöscht.
find "$MONIT_DIR" -maxdepth 1 -type f \
    \( -name 'teko*.monitrc' -o -name 'config-manager*.monitrc' -o -name 'forgejo*.monitrc' \
       -o -name 'grafana*.monitrc' -o -name 'loki*.monitrc' -o -name 'postfix*.monitrc' \) \
    ! -name 'teko-stack.monitrc' -print -delete 2>/dev/null || true

if [[ -f "$MONIT_MAIN" && ! -f "${MONIT_MAIN}.teko-original" ]]; then
    cp -a "$MONIT_MAIN" "${MONIT_MAIN}.teko-original"
fi

# /etc/monitrc enthält nur globale Monit-Einstellungen und den Include.
# Der lokale HTTP-Endpunkt gehört wie auf Remote-Clients ausschließlich der
# Client-Baseline-Datei cm-baseline.monitrc. Workload-/Management-Checks
# bleiben getrennt in teko-stack.monitrc. Damit existiert genau ein Owner je
# Konfigurationsbereich.
cat > "$MONIT_MAIN" <<'EOF'
# TEKO Monit bootstrap
set daemon 30
set logfile syslog facility log_daemon
set eventqueue
    basedir /var/lib/monit/events
    slots 100

include /etc/monit.d/*.monitrc
EOF
chown root:root "$MONIT_MAIN"
chmod 0600 "$MONIT_MAIN"

cat > "$MONIT_BASELINE" <<EOF
# Managed by Config Manager client baseline
# Local read-only status endpoint for Config Agent and Prometheus exporter.
set httpd port 2812
    use address 127.0.0.1
    allow localhost
    allow ${MONIT_HTTP_USER}:"${MONIT_HTTP_PASSWORD}"
EOF
chown root:root "$MONIT_BASELINE"
chmod 0600 "$MONIT_BASELINE"

log "4/7 Eine zentrale Monit Monitoring-Datei erzeugen"
cat > "$MONIT_STACK" <<EOF
# TEKO local stack monitoring
# This is the ONLY TEKO monitoring policy maintained by this package.

check program apache2-systemd with path "/usr/bin/systemctl is-active apache2.service"
    every 2 cycles
    if status != 0 then exec "/usr/bin/systemctl restart apache2.service"

check program postfix-systemd with path "/usr/bin/systemctl is-active postfix.service"
    every 2 cycles
    if status != 0 then exec "/usr/bin/systemctl restart postfix.service"

check program forgejo-systemd with path "/usr/bin/systemctl is-active forgejo.service"
    every 2 cycles
    if status != 0 then exec "/usr/bin/systemctl restart forgejo.service"

check program config-agent-systemd with path "/usr/bin/systemctl is-active config-agent.service"
    every 2 cycles
    if status != 0 then exec "/usr/bin/systemctl restart config-agent.service"

check program loki-systemd with path "/usr/bin/systemctl is-active loki.service"
    every 2 cycles
    if status != 0 then exec "/usr/bin/systemctl restart loki.service"

check program grafana-systemd with path "/usr/bin/systemctl is-active grafana.service"
    every 2 cycles
    if status != 0 then exec "/usr/bin/systemctl restart grafana.service"

check program teko-loki-importer-systemd with path "/usr/bin/systemctl is-active teko-loki-importer.service"
    every 2 cycles
    if status != 0 then exec "/usr/bin/systemctl restart teko-loki-importer.service"

check program teko-apache-loki-importer-systemd with path "/usr/bin/systemctl is-active teko-apache-loki-importer.service"
    every 2 cycles
    if status != 0 then exec "/usr/bin/systemctl restart teko-apache-loki-importer.service"

check host config-manager-https with address 127.0.0.1
    if failed port 443 type tcp with timeout 10 seconds then alert

check host postfix-smtp-local with address 127.0.0.1
    if failed port 25 protocol smtp with timeout 10 seconds then alert
EOF
chown root:root "$MONIT_STACK"
chmod 0600 "$MONIT_STACK"

# openSUSE/SLES: Monit 5.26 may expect /run/monit/monit.pid while the
# package unit does not create RuntimeDirectory=monit. /run is tmpfs, so a
# one-time mkdir would disappear after reboot. Keep the runtime directory
# persistent through systemd-tmpfiles and create it immediately as well.
MONIT_TMPFILES="/etc/tmpfiles.d/teko-monit.conf"
cat > "$MONIT_TMPFILES" <<'EOF'
d /run/monit 0755 root root -
EOF
chown root:root "$MONIT_TMPFILES"
chmod 0644 "$MONIT_TMPFILES"
systemd-tmpfiles --create "$MONIT_TMPFILES"
install -d -o root -g root -m 0755 /run/monit

monit -t

systemctl enable monit.service
systemctl restart monit.service
systemctl is-active --quiet monit.service || {
    echo "Monit konnte nicht gestartet werden. Diagnose:" >&2
    systemctl status monit.service --no-pager -l || true
    journalctl -u monit.service -n 100 --no-pager || true
    ls -ld /run /run/monit || true
    exit 1
}

log "5/7 Config-Agent Managed Configs vereinheitlichen"
[[ -d "$AGENT_DIR" ]] || {
    echo "Config-Agent fehlt unter $AGENT_DIR. Bitte zuerst setup_config_agent.sh ausführen." >&2
    exit 1
}
python3 - "$AGENT_MC" "$ROOT/config-agent/example/managed_configs.json.example" <<'PY'
import json, os, sys
target, source = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as f:
    teko = json.load(f)

current = {}
if os.path.isfile(target):
    try:
        with open(target, encoding="utf-8") as f:
            current = json.load(f)
    except Exception:
        current = {}

# Preserve unrelated/custom definitions but make all TEKO canonical keys exact.
current.update(teko)
tmp = target + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(current, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, target)
PY
chown root:root "$AGENT_MC"
chmod 0640 "$AGENT_MC"
systemctl restart config-agent.service

log "6/7 Validieren"
postfix check
monit -t
systemctl is-active --quiet postfix.service
systemctl is-active --quiet monit.service
systemctl is-active --quiet config-agent.service

# Safety assertion: Postfix must not listen on non-loopback IPv4.
if ss -lnt 2>/dev/null | awk '$4 ~ /:25$/ {print $4}' | grep -Evq '^(127\.0\.0\.1|::1|\[::1\]):25$'; then
    echo "FEHLER: Postfix lauscht unerwartet extern auf TCP/25." >&2
    ss -lntp | grep ':25' || true
    exit 1
fi

log "7/7 Fertig"
echo "Postfix:"
postconf -h myhostname inet_interfaces mynetworks 2>/dev/null || postconf -n | grep -E '^(myhostname|inet_interfaces|mynetworks) ='
echo
echo "Monit:"
echo "  Bootstrap: $MONIT_MAIN"
echo "  verwaltete Monitoring-Datei: $MONIT_STACK"
echo
echo "Config Manager / Agent:"
echo "  Managed configs: $AGENT_MC"
