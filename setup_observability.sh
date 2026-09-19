#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$ROOT/teko-stack.conf"

[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

OBS_BASE="/srv/observability"
GRAFANA_BASE="$OBS_BASE/grafana"
GRAFANA_DATA="$GRAFANA_BASE/data"
GRAFANA_PROVISIONING="$GRAFANA_BASE/provisioning"
GRAFANA_DASHBOARDS="$GRAFANA_BASE/dashboards"
LOKI_DATA="$OBS_BASE/loki"
PROMETHEUS_BASE="$OBS_BASE/prometheus"
PROMETHEUS_DATA="$PROMETHEUS_BASE/data"
QUADLET="/etc/containers/systemd"
ENV_DIR="/opt/service/env"
GRAFANA_ENV="$ENV_DIR/grafana.env"
EXPORT_TOKEN_FILE="$ENV_DIR/loki-export.token"
CM_ENV="/srv/www/config-manager-standalone/standalone/data/config-manager.env"

echo ">>> 1/8 Pakete/Verzeichnisse"
if [[ "${TEKO_FORCE:-0}" == "1" ]]; then
  echo "FORCE: Quadlet-/Service-Definitionen werden neu erzeugt; Observability-Daten und Secrets bleiben erhalten."
  rm -f "$QUADLET/loki.container" "$QUADLET/grafana.container" "$QUADLET/prometheus.container" "$QUADLET/observability.network" \
        /etc/systemd/system/teko-loki-importer.service /etc/systemd/system/teko-apache-loki-importer.service \
        /etc/systemd/system/teko-system-loki-importer.service 2>/dev/null || true
fi
zypper --non-interactive install podman python3 curl openssl
mkdir -p "$OBS_BASE" "$GRAFANA_DATA" "$GRAFANA_PROVISIONING/datasources" "$GRAFANA_PROVISIONING/dashboards" "$GRAFANA_DASHBOARDS" "$LOKI_DATA" "$PROMETHEUS_DATA" "$QUADLET" "$ENV_DIR"
chown -R 472:472 "$GRAFANA_BASE"
chown -R 10001:10001 "$LOKI_DATA"
chown -R 65534:65534 "$PROMETHEUS_DATA"
chmod 750 "$OBS_BASE"
chmod 750 "$GRAFANA_BASE" "$GRAFANA_DATA" "$GRAFANA_PROVISIONING" "$GRAFANA_DASHBOARDS" "$LOKI_DATA" "$PROMETHEUS_BASE" "$PROMETHEUS_DATA"
chmod 700 "$ENV_DIR"

echo ">>> 2/8 Grafana-Admin und Audit-Export-Token"
if [[ ! -f "$GRAFANA_ENV" ]]; then
    GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 36 | tr -d '\n/=+' | cut -c1-32)"
    install -o root -g root -m 0600 /dev/null "$GRAFANA_ENV"
    {
      echo "GF_SECURITY_ADMIN_USER=admin"
      echo "GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD"
      echo "GF_USERS_ALLOW_SIGN_UP=false"
      echo "GF_AUTH_ANONYMOUS_ENABLED=false"
      echo "GF_SERVER_DOMAIN=$GRAFANA_FQDN"
      echo "GF_SERVER_ROOT_URL=https://$GRAFANA_FQDN/"
      echo "GF_ANALYTICS_REPORTING_ENABLED=false"
      echo "GF_ANALYTICS_CHECK_FOR_UPDATES=false"
    } > "$GRAFANA_ENV"
    echo "Grafana Admin-Passwort wurde neu erzeugt."
else
    GRAFANA_ADMIN_PASSWORD=""
    echo "Grafana ENV existiert bereits und wird nicht ersetzt."
fi

if [[ ! -f "$EXPORT_TOKEN_FILE" ]]; then
    EXPORT_TOKEN="$(openssl rand -hex 32)"
    install -o root -g root -m 0600 /dev/null "$EXPORT_TOKEN_FILE"
    printf '%s' "$EXPORT_TOKEN" > "$EXPORT_TOKEN_FILE"
else
    EXPORT_TOKEN="$(cat "$EXPORT_TOKEN_FILE")"
fi

[[ -f "$CM_ENV" ]] || {
    echo "Config-Manager ENV fehlt: $CM_ENV" >&2
    echo "Bitte zuerst setup_config_manager.sh/setup_teko_local.sh ausfuehren." >&2
    exit 1
}

TMP="$(mktemp "${CM_ENV}.tmp.XXXXXX")"
awk '!/^CONFIG_MANAGER_LOKI_EXPORT_TOKEN=/' "$CM_ENV" > "$TMP"
printf 'CONFIG_MANAGER_LOKI_EXPORT_TOKEN=%s\n' "$EXPORT_TOKEN" >> "$TMP"
chown --reference="$CM_ENV" "$TMP"
chmod --reference="$CM_ENV" "$TMP"
mv -f "$TMP" "$CM_ENV"
# Config-Manager Runtime-Daten muessen fuer Apache konsistent les-/schreibbar bleiben.
# Ein frueherer Bootstrap darf das Verzeichnis nicht auf root:wwwrun umbiegen.
chown wwwrun:www "$(dirname "$CM_ENV")" "$CM_ENV"
chmod 0770 "$(dirname "$CM_ENV")"
chmod 0640 "$CM_ENV"

echo ">>> 3/8 Loki/Grafana Konfiguration"
install -o root -g root -m 0644 "$ROOT/observability/loki/loki.yaml" "$OBS_BASE/loki.yaml"
install -o 472 -g 472 -m 0644 "$ROOT/observability/grafana/provisioning/datasources/loki.yaml" "$GRAFANA_PROVISIONING/datasources/loki.yaml"
install -o root -g root -m 0644 "$ROOT/observability/prometheus/prometheus.yml" "$PROMETHEUS_BASE/prometheus.yml"
install -o 472 -g 472 -m 0644 "$ROOT/observability/grafana/provisioning/datasources/prometheus.yaml" "$GRAFANA_PROVISIONING/datasources/prometheus.yaml"
install -o 472 -g 472 -m 0644 "$ROOT/observability/grafana/provisioning/dashboards/teko.yaml" "$GRAFANA_PROVISIONING/dashboards/teko.yaml"
# The dashboard directory is fully managed by TEKO. Remove stale/renamed
# dashboards before provisioning so old UIDs (for example a duplicate Monit
# dashboard) disappear after an update. Grafana provisioning has
# disableDeletion=false for the same reason.
rm -f "$GRAFANA_DASHBOARDS"/teko-*.json 2>/dev/null || true
for dashboard in "$ROOT"/observability/grafana/dashboards/teko-*.json; do
  [[ -f "$dashboard" ]] || continue
  install -o 472 -g 472 -m 0644 "$dashboard" "$GRAFANA_DASHBOARDS/$(basename "$dashboard")"
done

cat > "$QUADLET/observability.network" <<'EOF'
[Network]
NetworkName=observability
EOF

cat > "$QUADLET/loki.container" <<EOF
[Unit]
Description=Local Infrastructure Loki
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=loki
Image=${LOKI_IMAGE}
Network=observability.network
PublishPort=127.0.0.1:${LOKI_HTTP_PORT}:3100
Volume=${LOKI_DATA}:/loki
Volume=${OBS_BASE}/loki.yaml:/etc/loki/local-config.yaml:ro
Exec=-config.file=/etc/loki/local-config.yaml

[Service]
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "$QUADLET/prometheus.container" <<EOF
[Unit]
Description=Local Infrastructure Prometheus
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=prometheus
Image=${PROMETHEUS_IMAGE}
Network=observability.network
PublishPort=127.0.0.1:${PROMETHEUS_HTTP_PORT}:9090
Volume=${PROMETHEUS_DATA}:/prometheus
Volume=${PROMETHEUS_BASE}/prometheus.yml:/etc/prometheus/prometheus.yml:ro
Exec=--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --web.enable-remote-write-receiver

[Service]
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "$QUADLET/grafana.container" <<EOF
[Unit]
Description=Local Infrastructure Grafana
After=loki.service prometheus.service
Wants=loki.service prometheus.service

[Container]
ContainerName=grafana
Image=${GRAFANA_IMAGE}
Network=observability.network
PublishPort=127.0.0.1:${GRAFANA_HTTP_PORT}:3000
EnvironmentFile=${GRAFANA_ENV}
Volume=${GRAFANA_DATA}:/var/lib/grafana
Volume=${GRAFANA_PROVISIONING}:/etc/grafana/provisioning:ro
Volume=${GRAFANA_DASHBOARDS}:/var/lib/grafana/dashboards:ro

[Service]
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$QUADLET/observability.network" "$QUADLET/loki.container" "$QUADLET/prometheus.container" "$QUADLET/grafana.container"

echo ">>> 4/8 Images laden / Quadlets starten"
podman pull "$LOKI_IMAGE"
podman pull "$PROMETHEUS_IMAGE"
podman pull "$GRAFANA_IMAGE"
systemctl daemon-reload
systemctl enable loki.service prometheus.service grafana.service >/dev/null 2>&1 || true
# restart statt start: dadurch werden auch bereits vorhandene Quadlets nach
# einem Setup-/Konfigurationslauf sicher mit der neuen Definition gestartet.
systemctl restart loki.service
systemctl restart prometheus.service
systemctl restart grafana.service

echo ">>> 5/8 Grafana Apache-VHost"
"$ROOT/bin/teko-hosts.sh"
"$ROOT/bin/teko-apache-https.sh"

mkdir -p /etc/apache2/ssl
GCRT="/etc/apache2/ssl/grafana-teko.crt"
GKEY="/etc/apache2/ssl/grafana-teko.key"

if [[ ! -f "$GCRT" || ! -f "$GKEY" ]]; then
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
    -keyout "$GKEY" -out "$GCRT" \
    -subj "/CN=${GRAFANA_FQDN}" \
    -addext "subjectAltName=DNS:${GRAFANA_FQDN},DNS:grafana,DNS:${SERVER_FQDN},IP:${SERVER_IP}"
  chmod 600 "$GKEY"
  chmod 644 "$GCRT"
fi

cat > /etc/apache2/vhosts.d/grafana-teko.conf <<EOF
<VirtualHost *:80>
    ServerName ${GRAFANA_FQDN}
    Redirect permanent / https://${GRAFANA_FQDN}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${GRAFANA_FQDN}
    SSLEngine on
    SSLCertificateFile ${GCRT}
    SSLCertificateKeyFile ${GKEY}

    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "443"

    ProxyPass        / http://127.0.0.1:${GRAFANA_HTTP_PORT}/
    ProxyPassReverse / http://127.0.0.1:${GRAFANA_HTTP_PORT}/

    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "same-origin"
    Header always set X-Frame-Options "SAMEORIGIN"

    ErrorLog /var/log/apache2/grafana_teko_error.log
    CustomLog /var/log/apache2/grafana_teko_access.log combined
</VirtualHost>
EOF

systemctl restart apache2

echo ">>> 6/8 Loki Importer"
install -o root -g root -m 0750 "$ROOT/observability/loki-importer.py" /usr/local/sbin/teko-loki-importer.py
install -d -o root -g root -m 0700 /var/lib/teko-loki-importer

cat > /etc/systemd/system/teko-loki-importer.service <<EOF
[Unit]
Description=Config Manager Audit to Loki importer
After=network-online.target apache2.service loki.service
Wants=network-online.target
Requires=loki.service

[Service]
Type=simple
User=root
Group=root
Environment=TEKO_AUDIT_EXPORT_URL=https://${CONFIG_MANAGER_FQDN}/api/audit_export.php
Environment=TEKO_LOKI_PUSH_URL=http://127.0.0.1:${LOKI_HTTP_PORT}/loki/api/v1/push
Environment=TEKO_AUDIT_EXPORT_TOKEN_FILE=${EXPORT_TOKEN_FILE}
Environment=TEKO_LOKI_STATE_FILE=/var/lib/teko-loki-importer/state.json
Environment=TEKO_LOKI_POLL_SECONDS=5
ExecStart=/usr/bin/python3 /usr/local/sbin/teko-loki-importer.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/opt/service/env
ReadWritePaths=/var/lib/teko-loki-importer
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now teko-loki-importer.service

# Apache access/error/ModSecurity audit logs -> Loki
install -o root -g root -m 0750 "$ROOT/observability/apache-loki-importer.py" /usr/local/sbin/teko-apache-loki-importer.py
install -d -o root -g root -m 0700 /var/lib/teko-apache-loki-importer
cat > /etc/systemd/system/teko-apache-loki-importer.service <<EOF
[Unit]
Description=Apache logs to Loki importer
After=network-online.target apache2.service loki.service
Wants=network-online.target
Requires=loki.service

[Service]
Type=simple
User=root
Group=root
Environment=TEKO_LOKI_PUSH_URL=http://127.0.0.1:${LOKI_HTTP_PORT}/loki/api/v1/push
Environment=TEKO_APACHE_LOKI_STATE_FILE=/var/lib/teko-apache-loki-importer/state.json
Environment=TEKO_APACHE_LOKI_POLL_SECONDS=2
ExecStart=/usr/bin/python3 /usr/local/sbin/teko-apache-loki-importer.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/var/log/apache2
ReadWritePaths=/var/lib/teko-apache-loki-importer
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
# Always restart importers after replacing their Python files. `enable --now`
# alone leaves an already running process on the old in-memory code.
systemctl enable teko-loki-importer.service teko-apache-loki-importer.service >/dev/null 2>&1 || true
systemctl restart teko-loki-importer.service teko-apache-loki-importer.service

# Postfix + Monit journald -> Loki. One cursor-backed reader is used so no
# fixed /var/log/mail path is required on openSUSE and no journal entries are
# duplicated after service restarts.
install -o root -g root -m 0750 "$ROOT/observability/system-loki-importer.py" /usr/local/sbin/teko-system-loki-importer.py
install -d -o root -g root -m 0700 /var/lib/teko-system-loki-importer
cat > /etc/systemd/system/teko-system-loki-importer.service <<EOF
[Unit]
Description=Postfix and Monit event logs to Loki importer
After=network-online.target loki.service postfix.service monit.service
Wants=network-online.target
Requires=loki.service

[Service]
Type=simple
User=root
Group=root
Environment=TEKO_LOKI_PUSH_URL=http://127.0.0.1:${LOKI_HTTP_PORT}/loki/api/v1/push
Environment=TEKO_SYSTEM_LOKI_STATE_FILE=/var/lib/teko-system-loki-importer/state.json
Environment=TEKO_SYSTEM_LOKI_POLL_SECONDS=2
ExecStart=/usr/bin/python3 /usr/local/sbin/teko-system-loki-importer.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/teko-system-loki-importer
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable teko-system-loki-importer.service >/dev/null 2>&1 || true
systemctl restart teko-system-loki-importer.service

echo ">>> 7/8 Warten/Pruefen"

wait_http() {
  local name="$1" url="$2" service="$3" tries="${4:-30}"
  local i
  for i in $(seq 1 "$tries"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "$name ready"
      return 0
    fi
    sleep 1
  done
  return 1
}

# Loki zuerst pruefen.
if ! wait_http "Loki" "http://127.0.0.1:${LOKI_HTTP_PORT}/ready" loki.service 45; then
  echo "Loki antwortet nicht; einmaliger kontrollierter Restart." >&2
  systemctl reset-failed loki.service || true
  systemctl restart loki.service
  wait_http "Loki" "http://127.0.0.1:${LOKI_HTTP_PORT}/ready" loki.service 30 || {
    systemctl status loki.service --no-pager -l || true
    journalctl -u loki.service -n 100 --no-pager || true
    podman ps -a || true
    exit 1
  }
fi

# Prometheus zentral bereitstellen. Der Port bleibt lokal; externer Remote-Write
# wird nur ueber einen bewusst konfigurierten Management-Ingress freigegeben.
if ! wait_http "Prometheus" "http://127.0.0.1:${PROMETHEUS_HTTP_PORT}/-/ready" prometheus.service 45; then
  echo "Prometheus antwortet nicht; einmaliger kontrollierter Restart." >&2
  systemctl reset-failed prometheus.service || true
  systemctl restart prometheus.service
  wait_http "Prometheus" "http://127.0.0.1:${PROMETHEUS_HTTP_PORT}/-/ready" prometheus.service 30 || {
    systemctl status prometheus.service --no-pager -l || true
    journalctl -u prometheus.service -n 100 --no-pager || true
    exit 1
  }
fi

# Grafana kann beim ersten Containerstart (DB-Migration/Provisioning) laenger
# brauchen. Falls Port/API noch nicht da ist, genau einmal neu starten und
# danach erneut warten. So bleibt ein echter Fehler sichtbar, statt nur ein
# nichtssagendes curl(7) zu liefern.
if ! wait_http "Grafana" "http://127.0.0.1:${GRAFANA_HTTP_PORT}/api/health" grafana.service 45; then
  echo "Grafana antwortet noch nicht auf 127.0.0.1:${GRAFANA_HTTP_PORT}; einmaliger kontrollierter Restart." >&2
  systemctl reset-failed grafana.service || true
  systemctl restart grafana.service
  if ! wait_http "Grafana" "http://127.0.0.1:${GRAFANA_HTTP_PORT}/api/health" grafana.service 45; then
    echo "FEHLER: Grafana ist auch nach Restart nicht erreichbar." >&2
    systemctl status grafana.service --no-pager -l || true
    journalctl -u grafana.service -n 120 --no-pager || true
    podman ps -a || true
    ss -lntp | grep -E ":(${GRAFANA_HTTP_PORT}|${LOKI_HTTP_PORT})\b" || true
    exit 1
  fi
fi

curl -fsS "http://127.0.0.1:${LOKI_HTTP_PORT}/ready"
curl -fsS "http://127.0.0.1:${PROMETHEUS_HTTP_PORT}/-/ready"
curl -fsS "http://127.0.0.1:${GRAFANA_HTTP_PORT}/api/health"

echo ">>> 8/8 Fertig"
echo "Grafana: https://${GRAFANA_FQDN}/"
echo "Loki:       nur lokal 127.0.0.1:${LOKI_HTTP_PORT}"
echo "Prometheus: nur lokal 127.0.0.1:${PROMETHEUS_HTTP_PORT}"
echo "Audit REST: https://${CONFIG_MANAGER_FQDN}/api/audit_export.php (local-only + token)"
if [[ -n "$GRAFANA_ADMIN_PASSWORD" ]]; then
  echo
  echo "============================================================"
  echo " Grafana Login - jetzt notieren"
  echo " Benutzer: admin"
  echo " Passwort: $GRAFANA_ADMIN_PASSWORD"
  echo "============================================================"
else
  echo "Grafana Admin-Zugang blieb unveraendert."
fi
