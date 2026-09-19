#!/bin/bash
#
# setup_config_manager.sh
#
# Installiert Apache + PHP auf openSUSE Leap und deployt das eigenständige
# Config-Manager-Portal (config-manager-standalone).
#
# Verwendung (als root bzw. mit sudo):
#   ./setup_config_manager.sh [Quellordner] [Zielordner]
#
# Beispiel:
#   ./setup_config_manager.sh ./config-manager-standalone /srv/www/config-manager-standalone
#
# Ohne Argumente werden folgende Defaults verwendet:
#   Quellordner: ./config-manager-standalone (relativ zum Skript-Aufrufort)
#   Zielordner:  /srv/www/config-manager-standalone

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1090
source "$SCRIPT_ROOT/teko-stack.conf"


SOURCE_DIR="${1:-./config-manager-standalone}"
TARGET_DIR="${2:-/srv/www/config-manager-standalone}"
VHOST_FILE="/etc/apache2/vhosts.d/config-manager.conf"
APACHE_USER="wwwrun"
APACHE_GROUP="www"
APACHE_SSL_DIR="/etc/apache2/ssl"
APACHE_SSL_CRT="$APACHE_SSL_DIR/config-manager.crt"
APACHE_SSL_KEY="$APACHE_SSL_DIR/config-manager.key"

# PHP-Uploadgrenzen vor dem Schreiben in die Apache-Konfiguration streng
# validieren. Dadurch koennen Environment-Overrides keine Apache-Direktiven
# einschleusen.
validate_php_size() {
    local key="$1" value="$2"
    if [[ ! "$value" =~ ^[1-9][0-9]*[KMG]$ ]]; then
        echo "FEHLER: $key='$value' ist ungueltig (erwartet z.B. 512M oder 1G)." >&2
        exit 1
    fi
}
validate_php_uint() {
    local key="$1" value="$2" min="$3" max="$4"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < min || value > max )); then
        echo "FEHLER: $key='$value' ist ungueltig (erlaubt: $min..$max)." >&2
        exit 1
    fi
}

validate_php_size CONFIG_MANAGER_PHP_POST_MAX_SIZE "$CONFIG_MANAGER_PHP_POST_MAX_SIZE"
validate_php_size CONFIG_MANAGER_PHP_UPLOAD_MAX_FILESIZE "$CONFIG_MANAGER_PHP_UPLOAD_MAX_FILESIZE"
validate_php_uint CONFIG_MANAGER_PHP_MAX_FILE_UPLOADS "$CONFIG_MANAGER_PHP_MAX_FILE_UPLOADS" 1 10000
validate_php_uint CONFIG_MANAGER_PHP_MAX_INPUT_VARS "$CONFIG_MANAGER_PHP_MAX_INPUT_VARS" 1000 100000
validate_php_uint CONFIG_MANAGER_PHP_MAX_EXECUTION_TIME "$CONFIG_MANAGER_PHP_MAX_EXECUTION_TIME" 30 3600
validate_php_uint CONFIG_MANAGER_PHP_MAX_INPUT_TIME "$CONFIG_MANAGER_PHP_MAX_INPUT_TIME" 30 3600

log() { echo -e "\n>>> $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root bzw. mit sudo ausführen." >&2
    exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Quellordner '$SOURCE_DIR' nicht gefunden." >&2
    exit 1
fi

"$SCRIPT_ROOT/bin/teko-hosts.sh"

log "1/8: Repositories aktualisieren"
zypper --non-interactive refresh

log "2/8: Apache und PHP installieren"
zypper --non-interactive install \
    apache2 apache2-mod_php8 apache2-utils \
    php8 php8-cli php8-curl php8-sqlite php8-openssl php8-ctype php8-mbstring sudo
# Hinweis: mod_ssl ist bei openSUSE bereits Teil des apache2-Hauptpakets,
# kein eigenes Paket noetig - nur a2enmod ssl aktiviert es (siehe Schritt 3).
# Hinweis: json und session brauchen kein eigenes Paket mehr, die sind seit
# PHP 8 fest im Basispaket php8 enthalten. php8-cli liefert das "php8"-Kommando
# für die Zeile, apache2-mod_php8 allein reicht dafuer nicht.

log "3/8: PHP-Modul aktivieren, Apache-Dienst aktivieren"
a2enmod php8 || true
a2enmod ssl || true
systemctl enable apache2

log "4/8: Firewall-Ports öffnen (falls firewalld aktiv)"
if systemctl is-active --quiet firewalld; then
    firewall-cmd --add-service=http --permanent
    firewall-cmd --add-service=https --permanent
    firewall-cmd --reload
else
    echo "firewalld ist nicht aktiv, Schritt übersprungen."
fi

log "5/8: Projekt nach $TARGET_DIR kopieren"

# Benutzerbestand bleibt beim normalen Update persistent.
# Bei einem expliziten --force wird der lokale Bootstrap-Admin bewusst wieder
# auf admin/admin gesetzt. Das ist fuer reproduzierbare Neuaufbauten/Testsysteme
# gewollt; weitere lokale Benutzer in users.json bleiben erhalten.
USERS_FILE="$TARGET_DIR/standalone/data/users.json"

if [[ "${TEKO_FORCE:-0}" == "1" ]]; then
    echo "FORCE: Config-Manager-Code und verwalteter Desired-State werden neu deployt."
    echo "FORCE: Config-Manager-Admin wird nach dem Deployment auf admin/admin zurueckgesetzt."
    rm -f "$TARGET_DIR/standalone/data/desired_state.json" 2>/dev/null || true
fi
mkdir -p "$(dirname "$TARGET_DIR")"
rsync -a --delete \
    --exclude 'standalone/data/config-manager.env' \
    --exclude 'standalone/data/users.json' \
    --exclude 'standalone/data/audit_log.sqlite*' \
    --exclude 'standalone/data/desired_state.json' \
    --exclude 'standalone/data/security_policies.json' \
    --exclude 'standalone/data/deploy_profiles.json' \
    --exclude 'standalone/data/deploy_profiles_backups/' \
    --exclude 'standalone/data/git-upload-staging/' \
    "$SOURCE_DIR"/ "$TARGET_DIR"/

log "6/8: Lokale Konfiguration und Berechtigungen setzen"
mkdir -p "$TARGET_DIR/standalone/data"
ENV_FILE="$TARGET_DIR/standalone/data/config-manager.env"

if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_FILE.example" "$ENV_FILE"
    echo "Neue standalone/data/config-manager.env aus der Vorlage angelegt."
    CREATED_NEW_ENV_FILE=1
else
    CREATED_NEW_ENV_FILE=0
fi

# ---------------------------------------------------------------------------
# Config-Agent API-Token synchronisieren
#
# Prioritaet:
#   1. Explizit beim Setup uebergebenes CONFIG_AGENT_API_TOKEN
#   2. Root-only Handoff-Datei des Agent-Setups
#
# Sobald ein Token gefunden wurde, wird CONFIG_MANAGER_API_TOKEN IMMER auf
# denselben Wert gesetzt. Damit kann nach einer Token-Rotation kein alter
# Manager-Token stehen bleiben und einen HTTP 401 verursachen.
# ---------------------------------------------------------------------------

TOKEN_HANDOFF_FILE="/opt/service/env/.config-agent-token"

if [[ -n "${CONFIG_AGENT_API_TOKEN:-}" ]]; then
    echo "API-Token wurde explizit an setup_config_manager.sh uebergeben."
elif [[ -r "$TOKEN_HANDOFF_FILE" ]]; then
    CONFIG_AGENT_API_TOKEN="$(tr -d '\r\n' < "$TOKEN_HANDOFF_FILE")"
    echo "API-Token automatisch von setup_config_agent.sh uebernommen (gleicher Host)."
fi

# Ein-Server-Modell: Manager spricht lokal mit dem Agenten.
CONFIG_AGENT_URL="${CONFIG_AGENT_URL_OVERRIDE:-https://127.0.0.1:${CONFIG_AGENT_PORT}}"

if [[ -n "${CONFIG_AGENT_API_TOKEN:-}" ]]; then
    if [[ ${#CONFIG_AGENT_API_TOKEN} -lt 32 ]]; then
        echo "FEHLER: CONFIG_AGENT_API_TOKEN ist kuerzer als 32 Zeichen." >&2
        exit 1
    fi

    # Alten/inkonsistenten Wert vollstaendig entfernen und genau einmal neu setzen.
    # Temp-Datei im selben Verzeichnis + mv = atomare Aktualisierung.
    ENV_TMP="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    awk '!/^CONFIG_MANAGER_API_TOKEN=/ && !/^CONFIG_MANAGER_APITOKEN=/' "$ENV_FILE" > "$ENV_TMP"
    printf 'CONFIG_MANAGER_API_TOKEN=%s\n' "$CONFIG_AGENT_API_TOKEN" >> "$ENV_TMP"

    chown "$APACHE_USER:$APACHE_GROUP" "$ENV_TMP"
    chmod 640 "$ENV_TMP"
    mv -f "$ENV_TMP" "$ENV_FILE"

    TOKEN_FP="$(printf '%s' "$CONFIG_AGENT_API_TOKEN" | sha256sum | awk '{print substr($1,1,12)}')"
    echo "CONFIG_MANAGER_API_TOKEN mit Agent synchronisiert (Fingerprint: ${TOKEN_FP})."
else
    echo "WARNUNG: Kein CONFIG_AGENT_API_TOKEN gefunden." >&2
    echo "         Erwartet wird entweder:" >&2
    echo "           - CONFIG_AGENT_API_TOKEN beim Aufruf" >&2
    echo "           - $TOKEN_HANDOFF_FILE" >&2
    echo "         Manager/Agent-API wird sonst mit HTTP 401 fehlschlagen." >&2
fi

if [[ -n "${CONFIG_AGENT_URL:-}" ]]; then
    sed -i '/^CONFIG_MANAGER_SERVERS_0_NAME=/d' "$ENV_FILE"
    sed -i '/^CONFIG_MANAGER_SERVERS_0_URL=/d' "$ENV_FILE"
    printf 'CONFIG_MANAGER_SERVERS_0_NAME=%s\n' "$SERVER_SHORTNAME" >> "$ENV_FILE"
    printf 'CONFIG_MANAGER_SERVERS_0_URL=%s\n' "$CONFIG_AGENT_URL" >> "$ENV_FILE"
sed -i '/^CONFIG_MANAGER_PUBLIC_BASE_URL=/d' "$ENV_FILE"
printf 'CONFIG_MANAGER_PUBLIC_BASE_URL=https://%s\n' "$CONFIG_MANAGER_FQDN" >> "$ENV_FILE"
    echo "Config-Agent gesetzt: ${SERVER_SHORTNAME} -> ${CONFIG_AGENT_URL}"
fi

# ---------------------------------------------------------------------------
# Fleet Registry / Desired State
#
# Die ENV-Werte von Server 0 bleiben als Rueckwaertskompatibilitaet erhalten.
# Fuer mehrere Systeme wird ab v1.6.0 eine separate, secret-freie Registry
# verwendet. Sie wird NICHT bei Upgrades ueberschrieben.
# ---------------------------------------------------------------------------
CONFIG_MANAGER_STATE_DIR="/opt/service/config-manager"
SERVER_REGISTRY_FILE="${CONFIG_MANAGER_SERVER_REGISTRY_FILE:-$CONFIG_MANAGER_STATE_DIR/servers.json}"
DESIRED_STATE_FILE="${CONFIG_MANAGER_DESIRED_STATE_FILE:-$TARGET_DIR/standalone/data/desired_state.json}"

mkdir -p "$CONFIG_MANAGER_STATE_DIR"
chown root:"$APACHE_GROUP" "$CONFIG_MANAGER_STATE_DIR"
chmod 750 "$CONFIG_MANAGER_STATE_DIR"

# Einheitlicher Token-Speicher fuer lokale und Remote-Agenten.
# Registry, Enrollment und Token-Lifecycle verwenden ausschliesslich diesen Pfad.
CONFIG_MANAGER_TOKEN_DIR="${CONFIG_MANAGER_TOKEN_DIR:-$CONFIG_MANAGER_STATE_DIR/tokens}"
install -d -o root -g "$APACHE_GROUP" -m 0750 "$CONFIG_MANAGER_TOKEN_DIR"

# Der lokale Config-Agent ist immer ueber einen dedizierten Runtime-Token
# angebunden.  Dieser wird bei jedem Setup aus dem bereits synchronisierten
# CONFIG_MANAGER_API_TOKEN regeneriert.  Dadurch kann ein fehlender/alter
# local-agent.token niemals die komplette Portal-Runtime blockieren.
LOCAL_AGENT_TOKEN_FILE="${CONFIG_MANAGER_LOCAL_TOKEN_FILE:-$CONFIG_MANAGER_TOKEN_DIR/${SERVER_SHORTNAME}.token}"
CURRENT_MANAGER_TOKEN="$(sed -n 's/^CONFIG_MANAGER_API_TOKEN=//p' "$ENV_FILE" | tail -n1 | tr -d '\r\n')"
if [[ -n "$CURRENT_MANAGER_TOKEN" ]]; then
    [[ ${#CURRENT_MANAGER_TOKEN} -ge 32 ]] || { echo "FEHLER: CONFIG_MANAGER_API_TOKEN ist fuer lokalen Runtime-Token zu kurz." >&2; exit 1; }
    LOCAL_TOKEN_TMP="$(mktemp "${LOCAL_AGENT_TOKEN_FILE}.tmp.XXXXXX")"
    printf '%s' "$CURRENT_MANAGER_TOKEN" > "$LOCAL_TOKEN_TMP"
    chown root:"$APACHE_GROUP" "$LOCAL_TOKEN_TMP"
    chmod 0640 "$LOCAL_TOKEN_TMP"
    mv -f "$LOCAL_TOKEN_TMP" "$LOCAL_AGENT_TOKEN_FILE"
    echo "Lokaler Runtime-Token synchronisiert: $LOCAL_AGENT_TOKEN_FILE"
else
    echo "WARNUNG: CONFIG_MANAGER_API_TOKEN fehlt; lokaler Runtime-Token konnte nicht regeneriert werden." >&2
fi

if [[ ! -f "$SERVER_REGISTRY_FILE" ]]; then
    cat > "$SERVER_REGISTRY_FILE" <<EOF_FLEET
{
  "schema_version": 1,
  "servers": [
    {
      "name": "${SERVER_SHORTNAME}",
      "url": "${CONFIG_AGENT_URL}",
      "groups": ["local", "mail"],
      "labels": {
        "env": "lab",
        "role": "mailrelay"
      }
    }
  ]
}
EOF_FLEET
    echo "Fleet-Registry angelegt: $SERVER_REGISTRY_FILE"
else
    echo "Fleet-Registry existiert bereits und wird nicht ueberschrieben: $SERVER_REGISTRY_FILE"
fi
chown root:"$APACHE_GROUP" "$SERVER_REGISTRY_FILE"
chmod 640 "$SERVER_REGISTRY_FILE"
# Registry v1 erhaelt eine stabile Host-ID. Der lokale Eintrag MUSS dieselbe
# Identitaet wie der Config-Agent/Alloy verwenden. Der Agent leitet seine ID aus
# dem FQDN ab (z.B. teko.local), nicht aus dem Kurzname (teko).
/usr/bin/python3 - "$SERVER_REGISTRY_FILE" "$SERVER_SHORTNAME" /var/lib/service/config-agent/identity.json <<'PY_HOSTID_MIGRATE'
import hashlib,json,os,sys,tempfile
p, local_name, identity_path=sys.argv[1:4]
try: d=json.load(open(p,encoding='utf-8'))
except Exception: raise SystemExit(0)
agent_host_id=''
try:
    ident=json.load(open(identity_path,encoding='utf-8'))
    agent_host_id=str(ident.get('host_id') or '').strip()
except Exception:
    pass
changed=False
for srv in d.get('servers',[]):
    if not isinstance(srv,dict): continue
    name=str(srv.get('name') or '').strip()
    # Lokaler Manager/Agent: die vom Agenten erzeugte Identity ist autoritativ.
    if name.lower()==local_name.strip().lower() and agent_host_id:
        if str(srv.get('host_id') or '') != agent_host_id:
            srv['host_id']=agent_host_id; changed=True
        continue
    if not srv.get('host_id'):
        key=name.lower()
        if key:
            srv['host_id']='host-'+hashlib.sha256(key.encode()).hexdigest()[:16]; changed=True
if changed:
    st=os.stat(p); fd,tmp=tempfile.mkstemp(prefix='.hostid.',dir=os.path.dirname(p),text=True)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f: json.dump(d,f,indent=2,ensure_ascii=False); f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.chown(tmp,st.st_uid,st.st_gid); os.chmod(tmp,st.st_mode & 0o777); os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
PY_HOSTID_MIGRATE

# Bestehende Registry-Tokenpfade auf den kanonischen Token-Speicher migrieren.
# Legacy-Dateien werden nur kopiert, nicht geloescht. Fehlende Remote-Tokens
# bleiben als degradierter Einzelserver sichtbar und blockieren das Portal nicht.
/usr/bin/python3 - "$SERVER_REGISTRY_FILE" "$CONFIG_MANAGER_TOKEN_DIR" "$APACHE_GROUP" "$CURRENT_MANAGER_TOKEN" <<'PY_TOKEN_MIGRATE'
import json, os, re, sys, tempfile, pwd, grp, stat
reg_path, token_dir, web_group, manager_token = sys.argv[1:5]
name_re=re.compile(r'^[A-Za-z0-9._:-]{1,128}$')
def safe_name(n): return re.sub(r'[^A-Za-z0-9._-]','_',n)+'.token'
def valid_token(t): return len(t)>=32 and not bool(re.search(r'\s',t))
def read_token(path):
    if not path or not os.path.isabs(path) or os.path.islink(path) or not os.path.isfile(path): return ''
    try:
        with open(path,encoding='utf-8') as f: t=f.read(4097).strip()
        return t if valid_token(t) else ''
    except Exception: return ''
def write_token(path,tok):
    if not valid_token(tok): return False
    os.makedirs(os.path.dirname(path),mode=0o750,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.migrate-token.',dir=os.path.dirname(path),text=True)
    try:
        with os.fdopen(fd,'w') as f:
            f.write(tok+'\n'); f.flush(); os.fsync(f.fileno())
        os.chown(tmp,0,grp.getgrnam(web_group).gr_gid); os.chmod(tmp,0o640); os.replace(tmp,path)
        return True
    finally:
        try:
            if os.path.exists(tmp): os.unlink(tmp)
        except Exception: pass
try:
    with open(reg_path,encoding='utf-8') as f: data=json.load(f)
except Exception:
    raise SystemExit(0)
changed=False
for srv in data.get('servers',[]):
    if not isinstance(srv,dict): continue
    name=str(srv.get('name','')).strip()
    if not name_re.match(name): continue
    dst=os.path.join(token_dir,safe_name(name))
    old=str(srv.get('token_file','')).strip()
    if not os.path.isfile(dst):
        tok=read_token(old)
        host=''
        try:
            from urllib.parse import urlparse
            host=(urlparse(str(srv.get('url',''))).hostname or '').lower()
        except Exception: pass
        if not tok and host in ('127.0.0.1','::1','localhost') and valid_token(manager_token): tok=manager_token
        if tok: write_token(dst,tok)
    if old != dst:
        srv['token_file']=dst; changed=True
if changed:
    fd,tmp=tempfile.mkstemp(prefix='.servers.',dir=os.path.dirname(reg_path),text=True)
    try:
        with os.fdopen(fd,'w') as f:
            json.dump(data,f,indent=2,ensure_ascii=False); f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.chown(tmp,0,grp.getgrnam(web_group).gr_gid); os.chmod(tmp,0o640); os.replace(tmp,reg_path)
    finally:
        try:
            if os.path.exists(tmp): os.unlink(tmp)
        except Exception: pass
PY_TOKEN_MIGRATE

# Privilegierter, eng begrenzter Writer fuer die Web-Serververwaltung.
# Apache erhaelt KEIN allgemeines Schreibrecht auf /opt/service/config-manager.
install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$SCRIPT_ROOT/bin/teko-server-registry-write.py" /usr/local/libexec/teko-server-registry-write.py
install -o root -g root -m 0755 "$SCRIPT_ROOT/bin/teko-agent-token-manager.py" /usr/local/libexec/teko-agent-token-manager.py
cat > /etc/sudoers.d/teko-config-manager-server-registry <<EOF_SUDO
${APACHE_USER} ALL=(root) NOPASSWD: /usr/bin/python3 /usr/local/libexec/teko-server-registry-write.py
${APACHE_USER} ALL=(root) NOPASSWD: /usr/bin/python3 /usr/local/libexec/teko-agent-token-manager.py
EOF_SUDO
chmod 0440 /etc/sudoers.d/teko-config-manager-server-registry
visudo -cf /etc/sudoers.d/teko-config-manager-server-registry >/dev/null

# Aktuellen Remote-Agent-Repair-Bundle bereitstellen. Der privilegierte
# Token/Agent-Manager kann damit einen bereits registrierten Agenten ueber den
# bestehenden SSH-Recovery-Kanal auf exakt den Stack-Stand dieses Managers
# aktualisieren. Das Archiv enthaelt ausschliesslich Code/Templates, keine Secrets.
AGENT_REPAIR_BUNDLE="$CONFIG_MANAGER_STATE_DIR/agent-repair-bundle.tar.gz"
REPAIR_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$REPAIR_TMP_DIR"' EXIT
mkdir -p "$REPAIR_TMP_DIR/teko-agent-bundle"
cp -a "$SCRIPT_ROOT/config-agent" "$REPAIR_TMP_DIR/teko-agent-bundle/"
cp -a "$SCRIPT_ROOT/setup_config_agent.sh" "$SCRIPT_ROOT/setup_remote_config_agent.sh" "$SCRIPT_ROOT/teko-stack.conf" "$REPAIR_TMP_DIR/teko-agent-bundle/"
# Der Lifecycle-Repair muss denselben Manager-Trust wie ein Erst-Enrollment
# transportieren. Ohne dieses Zertifikat kann ein bereits vorhandener Client
# das interne HTTPS-RPM-Repository nicht verifizieren.
# Fail closed: ohne Trust-Anchor ist das Repair-Bundle wertlos, weil der
# reparierte Client das interne HTTPS-Repository danach weiterhin nicht
# verifizieren kann. Frueher wurde das Zertifikat hier stillschweigend
# ausgelassen und der Fehler trat erst beim Observability-Deploy auf.
if [[ ! -r "$APACHE_SSL_CRT" ]]; then
    echo "FEHLER: Config-Manager TLS-Zertifikat nicht lesbar: $APACHE_SSL_CRT" >&2
    echo "        Ohne dieses Zertifikat kann kein gueltiges Agent-Repair-Bundle gebaut werden." >&2
    exit 1
fi
cp -a "$APACHE_SSL_CRT" "$REPAIR_TMP_DIR/teko-agent-bundle/config-manager-ca.crt"
tar -C "$REPAIR_TMP_DIR" -czf "${AGENT_REPAIR_BUNDLE}.tmp" teko-agent-bundle
# Repair-Bundle vor der Installation hart validieren. Unter `set -o pipefail` darf
# hier bewusst kein `tar -tzf ... | grep -q ...` verwendet werden: grep -q beendet
# sich beim ersten Treffer, tar erhaelt SIGPIPE und die Pipeline wird faelschlich
# als Fehler gewertet. Die Inhaltsliste wird deshalb genau einmal materialisiert.
REPAIR_CONTENTS="$REPAIR_TMP_DIR/repair-bundle.contents"
tar -tzf "${AGENT_REPAIR_BUNDLE}.tmp" > "$REPAIR_CONTENTS"
for required in \
  teko-agent-bundle/setup_config_agent.sh \
  teko-agent-bundle/setup_remote_config_agent.sh \
  teko-agent-bundle/teko-stack.conf \
  teko-agent-bundle/config-agent/VERSION; do
    grep -Fx -- "$required" "$REPAIR_CONTENTS" >/dev/null || {
        echo "FEHLER: Remote-Agent Repair-Bundle unvollstaendig: $required fehlt." >&2
        exit 1
    }
done
grep -Fx -- "teko-agent-bundle/config-manager-ca.crt" "$REPAIR_CONTENTS" >/dev/null || {
    echo "FEHLER: Remote-Agent Repair-Bundle enthaelt den Config-Manager Trust-Anchor nicht." >&2
    exit 1
}
chown root:root "${AGENT_REPAIR_BUNDLE}.tmp"
chmod 0600 "${AGENT_REPAIR_BUNDLE}.tmp"
mv -f "${AGENT_REPAIR_BUNDLE}.tmp" "$AGENT_REPAIR_BUNDLE"
rm -rf "$REPAIR_TMP_DIR"
trap - EXIT
echo "Remote-Agent Repair-Bundle aktualisiert: $AGENT_REPAIR_BUNDLE"

# Registry-/Policy-Pfade in der Runtime-ENV exakt einmal setzen/aktualisieren.
ENV_TMP="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
awk '!/^CONFIG_MANAGER_SERVER_REGISTRY_FILE=/ && !/^CONFIG_MANAGER_DESIRED_STATE_FILE=/' "$ENV_FILE" > "$ENV_TMP"
printf 'CONFIG_MANAGER_SERVER_REGISTRY_FILE=%s\n' "$SERVER_REGISTRY_FILE" >> "$ENV_TMP"
printf 'CONFIG_MANAGER_DESIRED_STATE_FILE=%s\n' "$DESIRED_STATE_FILE" >> "$ENV_TMP"
chown "$APACHE_USER:$APACHE_GROUP" "$ENV_TMP"
chmod 640 "$ENV_TMP"
mv -f "$ENV_TMP" "$ENV_FILE"

if [[ ! -f "$DESIRED_STATE_FILE" ]]; then
    mkdir -p "$(dirname "$DESIRED_STATE_FILE")"
    if [[ -f "$TARGET_DIR/config/desired_state.example.json" ]]; then
        cp "$TARGET_DIR/config/desired_state.example.json" "$DESIRED_STATE_FILE"
    else
        printf '%s\n' '{"schema_version":1,"policies":{}}' > "$DESIRED_STATE_FILE"
    fi
    echo "Desired-State-Datei angelegt: $DESIRED_STATE_FILE"
fi

# Lokales TEKO-Lab: Der Config-Agent verwendet standardmaessig ein selbstsigniertes
# Zertifikat. Fuer den Loopback-Agenten ist deshalb das kompatible Self-Signed-
# Profil der Default: Zertifikatskette und Hostname werden nicht durch cURL
# validiert. Die Verbindung bleibt weiterhin HTTPS-verschluesselt und der API-
# Token bleibt zwingend erforderlich.
#
# Fuer Umgebungen mit eigener CA kann beim Setup explizit gehaertet werden:
#   CONFIG_MANAGER_TLS_VERIFY=true \
#   CONFIG_MANAGER_TLS_VERIFY_HOST=true \
#   CONFIG_MANAGER_TLS_CA_FILE=/pfad/ca.pem \
#   ./setup_config_manager.sh ...
#
# Wichtig: Nicht nur sed verwenden. Bei aelteren/bestehenden ENV-Dateien koennen
# die Keys fehlen; dann muss der Installer sie atomar einfuegen.
TLS_VERIFY_VALUE="${CONFIG_MANAGER_TLS_VERIFY:-false}"
TLS_VERIFY_HOST_VALUE="${CONFIG_MANAGER_TLS_VERIFY_HOST:-false}"
TLS_CA_FILE_VALUE="${CONFIG_MANAGER_TLS_CA_FILE:-}"

upsert_env_key() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    awk -v k="$key" 'index($0, k "=") != 1 { print }' "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chown "$APACHE_USER:$APACHE_GROUP" "$tmp"
    chmod 640 "$tmp"
    mv -f "$tmp" "$ENV_FILE"
}

upsert_env_key CONFIG_MANAGER_TLS_VERIFY "$TLS_VERIFY_VALUE"
upsert_env_key CONFIG_MANAGER_TLS_VERIFY_HOST "$TLS_VERIFY_HOST_VALUE"
upsert_env_key CONFIG_MANAGER_TLS_CA_FILE "$TLS_CA_FILE_VALUE"

echo "Config-Manager TLS-Profil: verify=${TLS_VERIFY_VALUE}, verify_host=${TLS_VERIFY_HOST_VALUE}, ca_file=${TLS_CA_FILE_VALUE:-<leer>}"

# Auch eine bereits bestehende Fleet-Registry kann pro Server alte, strengere
# TLS-Werte enthalten. Der lokale Loopback-Agent folgt deshalb explizit dem
# beim Setup gewaehlten Profil. Remote-Agenten werden NICHT angefasst; sie
# koennen weiterhin Zertifikat-Pinning/CA-Verifikation verwenden.
python3 - "$SERVER_REGISTRY_FILE" "$CONFIG_AGENT_URL" "$TLS_VERIFY_VALUE" "$TLS_VERIFY_HOST_VALUE" "$TLS_CA_FILE_VALUE" <<'PY_TLS_REGISTRY'
import json, os, sys
path, local_url, verify_raw, verify_host_raw, ca_file = sys.argv[1:]

def as_bool(v):
    return str(v).strip().lower() in {"1", "true", "yes", "on", "enabled", "enable"}

with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
changed = False
for srv in cfg.get("servers", []):
    if not isinstance(srv, dict):
        continue
    url = str(srv.get("url", "")).rstrip("/")
    if url == local_url.rstrip("/") or url.startswith("https://127.0.0.1:5008"):
        wanted = {
            "verify": as_bool(verify_raw),
            "verify_host": as_bool(verify_host_raw),
            "ca_file": ca_file,
        }
        if srv.get("tls") != wanted:
            srv["tls"] = wanted
            changed = True
if changed:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
PY_TLS_REGISTRY
chown root:"$APACHE_GROUP" "$SERVER_REGISTRY_FILE"
chmod 640 "$SERVER_REGISTRY_FILE"

# Privilegierter, eng begrenzter Writer fuer die Web-Serververwaltung.
# Apache erhaelt KEIN allgemeines Schreibrecht auf /opt/service/config-manager.
install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$SCRIPT_ROOT/bin/teko-server-registry-write.py" /usr/local/libexec/teko-server-registry-write.py
install -o root -g root -m 0755 "$SCRIPT_ROOT/bin/teko-agent-token-manager.py" /usr/local/libexec/teko-agent-token-manager.py
cat > /etc/sudoers.d/teko-config-manager-server-registry <<EOF_SUDO
${APACHE_USER} ALL=(root) NOPASSWD: /usr/bin/python3 /usr/local/libexec/teko-server-registry-write.py
${APACHE_USER} ALL=(root) NOPASSWD: /usr/bin/python3 /usr/local/libexec/teko-agent-token-manager.py
EOF_SUDO
chmod 0440 /etc/sudoers.d/teko-config-manager-server-registry
visudo -cf /etc/sudoers.d/teko-config-manager-server-registry >/dev/null

# Webcode darf vom Apache-Benutzer gelesen, aber nicht verändert werden.
chown -R "root:$APACHE_GROUP" "$TARGET_DIR"
find "$TARGET_DIR" -type d -exec chmod 750 {} \;
find "$TARGET_DIR" -type f -exec chmod 640 {} \;

# Nur Laufzeitdaten sind für wwwrun schreibbar.
chown -R "$APACHE_USER:$APACHE_GROUP" "$TARGET_DIR/standalone/data"
chmod 770 "$TARGET_DIR/standalone/data"
find "$TARGET_DIR/standalone/data" -type f -exec chmod 640 {} \;

# Desired State ist Runtime-Control-Data und wird ueber die berechtigte GUI
# atomar gespeichert. Die Server-Registry bleibt dagegen root-owned.
if [[ -f "$DESIRED_STATE_FILE" ]]; then
    chown "$APACHE_USER:$APACHE_GROUP" "$DESIRED_STATE_FILE"
    chmod 640 "$DESIRED_STATE_FILE"
fi

chmod 750 "$TARGET_DIR/standalone/create_user.php"
chmod 640 "$ENV_FILE"

log "6c/8: Observability Data Plane Auth fuer Apache vorbereiten"
OBS_AUTH_FILE="/opt/service/config-manager/observability.htpasswd"
install -o root -g root -m 0755 "$SCRIPT_ROOT/bin/teko-observability-auth-sync.py" /usr/local/libexec/teko-observability-auth-sync.py
# Alte Python-Ingest-Schicht aus frueheren Releases vollstaendig entfernen.
# Apache proxyt Loki/Prometheus jetzt direkt auf localhost.
systemctl disable --now observability-ingest.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/observability-ingest.service
rm -rf /opt/service/observability-ingest
systemctl daemon-reload
/usr/bin/python3 /usr/local/libexec/teko-observability-auth-sync.py --registry "$SERVER_REGISTRY_FILE" --output "$OBS_AUTH_FILE"
LOCAL_OBS_HOST_ID="$(/usr/bin/python3 - <<'PY_LOCAL_OBS_ID'
import json
try:
    d=json.load(open('/var/lib/service/config-agent/identity.json',encoding='utf-8'))
    print(str(d.get('host_id') or '').strip())
except Exception:
    pass
PY_LOCAL_OBS_ID
)"
if [[ -n "$LOCAL_OBS_HOST_ID" ]] && ! grep -q "^${LOCAL_OBS_HOST_ID}:" "$OBS_AUTH_FILE"; then
    echo "FEHLER: lokaler Alloy-Host ${LOCAL_OBS_HOST_ID} fehlt nach Auth-Sync in $OBS_AUTH_FILE" >&2
    exit 1
fi

log "7/8: TLS-Zertifikat und Apache-Vhost anlegen"
install -d -o root -g root -m 0755 "${BASELINE_REPO_DIR:-/srv/www/baseline-repo}"
mkdir -p "$APACHE_SSL_DIR"
if [[ ! -f "$APACHE_SSL_CRT" || ! -f "$APACHE_SSL_KEY" ]]; then
    openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
        -keyout "$APACHE_SSL_KEY" \
        -out "$APACHE_SSL_CRT" \
        -subj "/CN=${CONFIG_MANAGER_FQDN}" \
        -addext "subjectAltName=DNS:${CONFIG_MANAGER_FQDN},DNS:config-manager,DNS:${SERVER_FQDN},DNS:${SERVER_SHORTNAME},IP:${SERVER_IP}"
    chmod 600 "$APACHE_SSL_KEY"
    chmod 644 "$APACHE_SSL_CRT"
    echo "Selbstsigniertes Apache-Zertifikat erzeugt fuer CN=${CONFIG_MANAGER_FQDN} (Test/Schulbetrieb)."
else
    echo "Apache-Zertifikat existiert bereits, wird nicht ueberschrieben."
fi

# Management-Server vertraut seinem eigenen Config-Manager-Zertifikat.
# Remote-Clients erhalten denselben Trust Anchor beim Enrollment.
if [[ -r "$APACHE_SSL_CRT" && -d /etc/pki/trust/anchors ]]; then
    install -o root -g root -m 0644 "$APACHE_SSL_CRT" /etc/pki/trust/anchors/infrastructure-config-manager.crt
    if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates >/dev/null 2>&1 || true
    elif command -v update-ca-trust >/dev/null 2>&1; then
        update-ca-trust extract >/dev/null 2>&1 || true
    fi
fi

cat > "$VHOST_FILE" <<EOF
<VirtualHost *:80>
    ServerName ${CONFIG_MANAGER_FQDN}
    Redirect permanent / https://${CONFIG_MANAGER_FQDN}/

    ErrorLog /var/log/apache2/config-manager_error.log
    CustomLog /var/log/apache2/config-manager_access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName ${CONFIG_MANAGER_FQDN}
    DocumentRoot $TARGET_DIR/public

    SSLEngine on
    SSLCertificateFile $APACHE_SSL_CRT
    SSLCertificateKeyFile $APACHE_SSL_KEY

    # TEKO Config Manager: Upload-Limits bewusst auf VirtualHost-Ebene setzen.
    # Damit gelten sie bereits beim Parsen des multipart/form-data Request-Bodys
    # und nicht erst in einem spaeter zusammengefuehrten Directory-Kontext.
    # Das ist insbesondere fuer max_file_uploads bei Verzeichnis-Uploads wichtig.
    php_admin_value post_max_size ${CONFIG_MANAGER_PHP_POST_MAX_SIZE}
    php_admin_value upload_max_filesize ${CONFIG_MANAGER_PHP_UPLOAD_MAX_FILESIZE}
    php_admin_value max_file_uploads ${CONFIG_MANAGER_PHP_MAX_FILE_UPLOADS}
    php_admin_value max_input_vars ${CONFIG_MANAGER_PHP_MAX_INPUT_VARS}
    php_admin_value max_execution_time ${CONFIG_MANAGER_PHP_MAX_EXECUTION_TIME}
    php_admin_value max_input_time ${CONFIG_MANAGER_PHP_MAX_INPUT_TIME}

    <Directory $TARGET_DIR/public>
        Require all granted
        AllowOverride None
        Options -Indexes
    </Directory>

    # Interne RPM-Paketquelle fuer Managed Clients. Statischer Inhalt:
    # keine PHP-/CRS-Verarbeitung, damit repodata/*.xml und RPMs unveraendert
    # ausgeliefert werden.
    Alias /baseline-repo/ "${BASELINE_REPO_DIR:-/srv/www/baseline-repo}/"
    <Directory "${BASELINE_REPO_DIR:-/srv/www/baseline-repo}">
        Require all granted
        AllowOverride None
        Options -Indexes
    </Directory>
    <Location "/baseline-repo/">
        Require all granted
        <IfModule security2_module>
            SecRuleEngine Off
        </IfModule>
    </Location>
    # Observability Data Plane: Apache ist der einzige externe Proxy.
    # Loki und Prometheus bleiben ausschliesslich auf localhost gebunden.
    # Die bestehenden host-spezifischen Config-Agent-Tokens werden direkt
    # durch Apache Basic Auth gegen eine root-verwaltete htpasswd-Datei geprueft.
    ProxyPass        /observability-ingest/loki/api/v1/push http://127.0.0.1:3100/loki/api/v1/push
    ProxyPassReverse /observability-ingest/loki/api/v1/push http://127.0.0.1:3100/loki/api/v1/push
    ProxyPass        /observability-ingest/prometheus/api/v1/write http://127.0.0.1:9090/api/v1/write
    ProxyPassReverse /observability-ingest/prometheus/api/v1/write http://127.0.0.1:9090/api/v1/write
    <Location "/observability-ingest/">
        AuthType Basic
        AuthName "Observability ingest"
        AuthBasicProvider file
        AuthUserFile /opt/service/config-manager/observability.htpasswd
        Require valid-user
        LimitRequestBody 33554432
        <IfModule security2_module>
            SecRuleEngine Off
        </IfModule>
    </Location>

    # Loki importer: REST-Export darf nur vom lokalen TEKO-Server aufgerufen werden.
    <Location "/api/audit_export.php">
        Require local
    </Location>

    # OWASP CRS False-Positive-Ausnahme fuer interne Config-IDs.
    #
    # Die Config-Manager-IDs (z.B. "apache-config-manager-vhost") sind keine
    # Dateipfade, enthalten aber Begriffe wie "apache" und "config", die von
    # den generischen LFI-Regeln des CRS als Dateizugriffsindikatoren gewertet
    # werden koennen. Die Anwendung validiert config_name/config_names gegen
    # die serverseitige Liste der bekannten Managed-Config-IDs. Deshalb werden
    # ausschliesslich diese beiden Parameter und ausschliesslich fuer /index.php
    # aus der LFI-Regelfamilie herausgenommen. Alle anderen CRS-Pruefungen
    # (SQLi, XSS, RCE, Protokollanomalien usw.) bleiben unveraendert aktiv.
    <IfModule security2_module>
        <Location "/index.php">
            SecRuleUpdateTargetByTag "attack-lfi" "!ARGS:config_name"
            SecRuleUpdateTargetByTag "attack-lfi" "!ARGS:config_names"
        </Location>
    </IfModule>

    # standalone/, config/ und lib/ sind zusaetzlich per .htaccess gesperrt
    # (Require all denied), liegen aber ohnehin ausserhalb des DocumentRoot.

    ErrorLog /var/log/apache2/config-manager_ssl_error.log
    CustomLog /var/log/apache2/config-manager_ssl_access.log combined
</VirtualHost>
EOF
echo "Vhost geschrieben: $VHOST_FILE (Port 80 + 443)"
echo "PHP-Uploadgrenzen: post_max_size=${CONFIG_MANAGER_PHP_POST_MAX_SIZE}, upload_max_filesize=${CONFIG_MANAGER_PHP_UPLOAD_MAX_FILESIZE}, max_file_uploads=${CONFIG_MANAGER_PHP_MAX_FILE_UPLOADS}, max_input_vars=${CONFIG_MANAGER_PHP_MAX_INPUT_VARS}"
echo "HINWEIS: Selbstsigniertes Zertifikat, Browser zeigt eine Warnung. Echtes/CA-Zertifikat"
echo "         und WAF-Haertung kommen im naechsten Projektschritt dazu."

log "8/8: Apache/HTTPS aktivieren und neu starten"
"$SCRIPT_ROOT/bin/teko-apache-https.sh"

log "Fertig."
echo "Portal erreichbar unter: https://${CONFIG_MANAGER_FQDN}/"
echo "Observability Data Plane: https://${CONFIG_MANAGER_FQDN}/observability-ingest/"
echo "Forgejo erreichbar unter: https://${FORGEJO_FQDN}/"

log "Admin-Benutzer anlegen"
PHP_BIN="$(command -v php8 || command -v php || true)"
if [[ -z "$PHP_BIN" ]]; then
    echo "Kein PHP-CLI gefunden (weder 'php8' noch 'php'). php8-cli installiert?" >&2
    exit 1
fi

run_as_apache_user() {
    # $1 = zu setzende Umgebungsvariable (KEY=WERT), Rest = Kommando
    local envvar="$1"; shift
    if command -v sudo >/dev/null 2>&1; then
        env "$envvar" sudo -u "$APACHE_USER" -E "$@"
    else
        # Fallback ohne sudo, z.B. auf Minimalsystemen ohne sudo-Paket.
        su -s /bin/bash -c "export ${envvar}; export CM_BOOTSTRAP_ALLOW_WEAK=${CM_BOOTSTRAP_ALLOW_WEAK:-0}; export CM_FORCE_PASSWORD_CHANGE=${CM_FORCE_PASSWORD_CHANGE:-0}; $(printf '%q ' "$@")" "$APACHE_USER"
    fi
}

RESET_ADMIN=0
if [[ "${TEKO_FORCE:-0}" == "1" ]]; then
    RESET_ADMIN=1
elif [[ ! -f "$TARGET_DIR/standalone/data/users.json" ]]; then
    RESET_ADMIN=1
fi

if [[ "$RESET_ADMIN" -eq 1 ]]; then
    ADMIN_USER="admin"
    # Greenfield und explizites --force verwenden bewusst den deterministischen
    # Bootstrap-Zugang admin/admin. Der erste Login erzwingt die Aenderung.
    # Bei --force ist das Zuruecksetzen absichtlich Teil der Reset-Semantik.
    ADMIN_PASSWORD="admin"
    GENERATED_PASSWORD=1
    FORCE_PASSWORD_CHANGE=1

    if [[ "$FORCE_PASSWORD_CHANGE" -eq 1 ]]; then
        export CM_BOOTSTRAP_ALLOW_WEAK=1 CM_FORCE_PASSWORD_CHANGE=1
        run_as_apache_user "CM_NEW_PASSWORD=$ADMIN_PASSWORD" \
            "$PHP_BIN" "$TARGET_DIR/standalone/create_user.php" "$ADMIN_USER" "AdminPortal,ConfigManager"
        unset CM_BOOTSTRAP_ALLOW_WEAK CM_FORCE_PASSWORD_CHANGE
    else
        run_as_apache_user "CM_NEW_PASSWORD=$ADMIN_PASSWORD" \
            "$PHP_BIN" "$TARGET_DIR/standalone/create_user.php" "$ADMIN_USER" "AdminPortal,ConfigManager"
    fi

    # Klartext-Zugang nur in einer root-lesbaren Datei hinterlegen. Dadurch kann
    # die Abschlussuebersicht den Zugang bei Greenfield-Installationen erneut
    # anzeigen, ohne ihn in allgemeine Konfigurationsdateien zu schreiben.
    install -d -o root -g root -m 0700 "$(dirname "$CONFIG_MANAGER_ADMIN_ENV_FILE")"
    CM_CRED_TMP="$(mktemp "${CONFIG_MANAGER_ADMIN_ENV_FILE}.tmp.XXXXXX")"
    {
        printf 'CONFIG_MANAGER_ADMIN_USER=%s\n' "$ADMIN_USER"
        printf 'CONFIG_MANAGER_ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
        printf 'CONFIG_MANAGER_ADMIN_URL=https://%s/\n' "$CONFIG_MANAGER_FQDN"
    } > "$CM_CRED_TMP"
    chown root:root "$CM_CRED_TMP"
    chmod 0600 "$CM_CRED_TMP"
    mv -f "$CM_CRED_TMP" "$CONFIG_MANAGER_ADMIN_ENV_FILE"

    echo ""
    echo "=================================================================="
    echo " Login-Daten (jetzt notieren, werden nicht erneut angezeigt):"
    echo "   Benutzername: $ADMIN_USER"
    echo "   Passwort:     $ADMIN_PASSWORD"
    if [[ "$FORCE_PASSWORD_CHANGE" -eq 1 ]]; then
        echo "   HINWEIS: Initialzugang admin/admin - Passwortaenderung beim ersten Login ist Pflicht."
    fi
    echo "   Sicher gespeichert: $CONFIG_MANAGER_ADMIN_ENV_FILE (root:root 0600)"
    echo "=================================================================="
    echo ""
else
    echo "standalone/data/users.json existiert bereits; ohne --force werden Benutzer und Passwoerter nicht angetastet."
fi

if [[ -z "${CONFIG_AGENT_API_TOKEN:-}" || -z "${CONFIG_AGENT_URL:-}" ]]; then
    echo "Noch offen (Token/URL wurden nicht automatisch gefunden):"
    echo "  $ENV_FILE"
    echo ""
    echo "Laeuft der Config-Agent auf DIESEM Host, pruefen:"
    echo "  ls -l /opt/service/env/.config-agent-token"
    echo "  ls -l /opt/service/config-agent/global.json"
    echo ""
    echo "Laeuft der Config-Agent auf einem ANDEREN Host, Token/URL explizit mitgeben:"
    echo "  sudo CONFIG_AGENT_API_TOKEN=xxxxx CONFIG_AGENT_URL=https://<agent-ip>:5008 \\"
    echo "       ADMIN_USER=hec ./setup_config_manager.sh"
fi
