#!/bin/bash
set -euo pipefail
umask 077

AGENT_ENV="/opt/service/env/config-agent.env"
IDENTITY="/var/lib/service/config-agent/identity.json"
SECRET_DIR="/var/lib/service/config-agent/secrets"
ALLOY_SECRET="$SECRET_DIR/alloy-observability.env"
ALLOY_CONFIG="/etc/alloy/config.alloy"
ALLOY_TMP=""

log(){ printf '%s\n' "$*"; }
fail(){ printf 'FEHLER: %s\n' "$*" >&2; exit 6; }
alloy_diag(){
  printf '\n--- alloy.service status ---\n' >&2
  systemctl --no-pager --full status alloy.service >&2 2>&1 || :
  printf '\n--- alloy.service journal (letzte 50 Zeilen) ---\n' >&2
  journalctl -u alloy.service -n 50 --no-pager >&2 2>&1 || :
}

[[ -r "$AGENT_ENV" ]] || fail "Config-Agent Environment fehlt oder ist nicht lesbar: $AGENT_ENV"
TOKEN="$(sed -n 's/^CONFIG_AGENT_API_TOKEN=//p' "$AGENT_ENV" | head -n1)"
[[ ${#TOKEN} -ge 32 ]] || fail "CONFIG_AGENT_API_TOKEN fehlt oder ist zu kurz."

read -r HOST_ID HOSTNAME_VALUE < <(python3 - "$IDENTITY" <<'PY'
import hashlib,json,socket,sys
p=sys.argv[1]
hn=socket.getfqdn() or socket.gethostname() or 'unknown'
hid=''
try:
    with open(p, encoding='utf-8') as f:
        d=json.load(f)
    hid=str(d.get('host_id') or '')
    hn=str(d.get('hostname') or hn)
except Exception:
    pass
if not hid:
    hid='host-'+hashlib.sha256(hn.lower().encode()).hexdigest()[:16]
print(hid,hn)
PY
)

install -d -o root -g root -m 0700 "$SECRET_DIR"
printf 'OBSERVABILITY_INGEST_USER=%s\nOBSERVABILITY_INGEST_PASSWORD=%s\n' "$HOST_ID" "$TOKEN" > "$ALLOY_SECRET"
chown root:root "$ALLOY_SECRET"
chmod 0600 "$ALLOY_SECRET"

# Den effektiven systemd-Serviceuser robust ermitteln. `systemctl show User=` kann
# auf inkonsistenten/teilinstallierten Vendor-Paketen leer sein. Deshalb zuerst
# systemctl show, danach die Unit selbst auswerten und als letzte sichere Vorgabe
# den vom offiziellen Alloy-RPM verwendeten Konto-Namen `alloy` verwenden.
resolve_unit_value(){
  local key="$1" val=""
  val="$(systemctl show -p "$key" --value alloy.service 2>/dev/null || true)"
  if [[ -z "$val" ]]; then
    val="$(systemctl cat alloy.service 2>/dev/null | sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" | tail -n1 | tr -d '\r' || true)"
  fi
  printf '%s' "$val"
}

ALLOY_USER="$(resolve_unit_value User)"
ALLOY_GROUP="$(resolve_unit_value Group)"
[[ -n "$ALLOY_USER" ]] || ALLOY_USER="alloy"
[[ -n "$ALLOY_GROUP" ]] || ALLOY_GROUP="$ALLOY_USER"

[[ "$ALLOY_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fail "ungueltiger Alloy-Serviceuser: $ALLOY_USER"
[[ "$ALLOY_GROUP" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fail "ungueltige Alloy-Servicegruppe: $ALLOY_GROUP"

if ! getent group "$ALLOY_GROUP" >/dev/null 2>&1; then
  log "[REPAIR] Alloy-Systemgruppe fehlt: $ALLOY_GROUP -> wird angelegt"
  groupadd --system "$ALLOY_GROUP" || fail "Alloy-Systemgruppe konnte nicht angelegt werden: $ALLOY_GROUP"
fi
if ! getent passwd "$ALLOY_USER" >/dev/null 2>&1; then
  log "[REPAIR] Alloy-Systembenutzer fehlt: $ALLOY_USER -> wird angelegt"
  NOLOGIN="$(command -v nologin || true)"
  [[ -n "$NOLOGIN" ]] || NOLOGIN="/sbin/nologin"
  useradd --system --gid "$ALLOY_GROUP" --home-dir /var/lib/alloy --shell "$NOLOGIN" --no-create-home "$ALLOY_USER" \
    || fail "Alloy-Systembenutzer konnte nicht angelegt werden: $ALLOY_USER"
fi

# Harte Vorbedingung: systemd darf nie in den Start laufen, wenn das konfigurierte
# Konto nicht aufloesbar ist. Damit wird status=217/USER vor dem Restart abgefangen.
getent passwd "$ALLOY_USER" >/dev/null 2>&1 || fail "Alloy-Serviceuser nicht aufloesbar: $ALLOY_USER"
getent group "$ALLOY_GROUP" >/dev/null 2>&1 || fail "Alloy-Servicegruppe nicht aufloesbar: $ALLOY_GROUP"
log "[OK] Alloy-Servicekonto: $ALLOY_USER:$ALLOY_GROUP"

install -d -o "$ALLOY_USER" -g "$ALLOY_GROUP" -m 0750 /var/lib/alloy /var/lib/alloy/data
chown -R "$ALLOY_USER:$ALLOY_GROUP" /var/lib/alloy

install -d -o root -g root -m 0755 /etc/alloy
ALLOY_TMP="$(mktemp /etc/alloy/.config.alloy.XXXXXX)"
cleanup_tmp(){ [[ -n "${ALLOY_TMP:-}" && -e "$ALLOY_TMP" ]] && rm -f "$ALLOY_TMP" || :; }
trap cleanup_tmp EXIT

cat > "$ALLOY_TMP" <<EOFALLOY
// Managed by package: client-baseline
logging { level = "info" }

loki.source.journal "system" {
  forward_to = [loki.write.central.receiver]
}

loki.write "central" {
  external_labels = { host_id = "$HOST_ID", hostname = "$HOSTNAME_VALUE", source = "alloy", job = "systemd-journal" }
  endpoint {
    url = "https://config-manager.local/observability-ingest/loki/api/v1/push"
    basic_auth {
      username = sys.env("OBSERVABILITY_INGEST_USER")
      password = sys.env("OBSERVABILITY_INGEST_PASSWORD")
    }
  }
}

prometheus.exporter.unix "host" { }
prometheus.scrape "host" {
  targets = prometheus.exporter.unix.host.targets
  forward_to = [prometheus.remote_write.central.receiver]
}
prometheus.scrape "monit" {
  targets = [{ "__address__" = "127.0.0.1:9108", "job" = "monit" }]
  forward_to = [prometheus.remote_write.central.receiver]
}
prometheus.remote_write "central" {
  external_labels = { host_id = "$HOST_ID", hostname = "$HOSTNAME_VALUE", source = "alloy", job = "systemd-journal" }
  endpoint {
    url = "https://config-manager.local/observability-ingest/prometheus/api/v1/write"
    basic_auth {
      username = sys.env("OBSERVABILITY_INGEST_USER")
      password = sys.env("OBSERVABILITY_INGEST_PASSWORD")
    }
  }
}
EOFALLOY
chown root:root "$ALLOY_TMP"
chmod 0644 "$ALLOY_TMP"

# Syntax/Komponenten vor dem Aktivieren validieren. Nicht per runuser auf den
# Alloy-Serviceuser wechseln: Git-Deploy kann in einem gehaerteten systemd-
# Kontext ohne CAP_SETGID laufen; runuser/initgroups wuerde dort mit
# "cannot set groups: Operation not permitted" scheitern.
#
# Die reale Lesbarkeit und Laufzeit unter dem effektiven Servicekonto prueft
# anschliessend systemd selbst: Datei wird root:root 0644 installiert, Alloy
# gestartet und muss mehrere Sekunden stabil aktiv bleiben.
if command -v alloy >/dev/null 2>&1; then
  if ! env \
    OBSERVABILITY_INGEST_USER="$HOST_ID" \
    OBSERVABILITY_INGEST_PASSWORD="$TOKEN" \
    alloy validate "$ALLOY_TMP"; then
    fail "erzeugte Alloy-Konfiguration ist ungueltig; bestehende Konfiguration bleibt unveraendert."
  fi
fi

mv -f "$ALLOY_TMP" "$ALLOY_CONFIG"
ALLOY_TMP=""
chown root:root "$ALLOY_CONFIG"
chmod 0644 "$ALLOY_CONFIG"
log "[OK] Alloy-Konfiguration: $ALLOY_CONFIG (root:root 0644)"

if getent passwd "$ALLOY_USER" >/dev/null 2>&1; then
  for g in systemd-journal adm; do
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$ALLOY_USER" || :
  done
fi

systemctl daemon-reload
systemctl enable monit.service >/dev/null 2>&1 || :
systemctl start monit.service >/dev/null 2>&1 || :

if command -v alloy >/dev/null 2>&1; then
  systemctl enable alloy.service >/dev/null 2>&1 || :
  systemctl reset-failed alloy.service >/dev/null 2>&1 || :
  if ! systemctl restart alloy.service; then
    alloy_diag
    fail "alloy.service konnte nicht gestartet werden."
  fi
  # Ein sofortiger Start kann erfolgreich gemeldet werden, obwohl Alloy kurz
  # danach wegen Runtime-/Rechtefehlern beendet wird. Deshalb einige Sekunden
  # stabilen Active-Zustand verlangen.
  for i in 1 2 3 4 5; do
    sleep 1
    if ! systemctl is-active --quiet alloy.service; then
      alloy_diag
      fail "alloy.service ist nach dem Start wieder beendet worden."
    fi
  done
  log "[OK] alloy.service aktiv und stabil"
fi

if [[ -s "$SECRET_DIR/monit-status.env" ]]; then
  systemctl enable monit-prometheus-exporter.service >/dev/null 2>&1 || :
  systemctl restart monit-prometheus-exporter.service || :
fi
