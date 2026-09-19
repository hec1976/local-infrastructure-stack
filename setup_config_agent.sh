#!/bin/bash
#
# setup_config_agent.sh
#
# Installiert Abhängigkeiten und deployt den Config-Agent auf openSUSE Leap.
#
# Secrets:
#   CONFIG_AGENT_SECRET
#       Internes Secret des Config-Agenten.
#       Bleibt ausschließlich auf dem Agent-Host.
#
#   CONFIG_AGENT_API_TOKEN
#       API-Authentifizierung zwischen Config-Manager und Config-Agent.
#       Wird zusätzlich über eine root-only Handoff-Datei bereitgestellt.
#
# Verwendung:
#   ./setup_config_agent.sh [Quellordner]
#
# Beispiel:
#   ./setup_config_agent.sh ./config-agent
#
# Ohne Argument wird ./config-agent erwartet.
# Zielpfad:
#   /opt/service/config-agent
#

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1090
source "$SCRIPT_ROOT/teko-stack.conf"
if [[ "${CONFIG_AGENT_REMOTE_MODE:-0}" != "1" ]]; then
    "$SCRIPT_ROOT/bin/teko-hosts.sh"
fi

SOURCE_DIR="${1:-./config-agent}"

APP_DIR="/opt/service/config-agent"
ENV_DIR="/opt/service/env"
SSL_DIR="/opt/service/ssl"

ENV_FILE="$ENV_DIR/config-agent.env"
TOKEN_HANDOFF_FILE="$ENV_DIR/.config-agent-token"
IDENTITY_FILE="/var/lib/service/config-agent/identity.json"

log() {
    echo -e "\n>>> $*"
}

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root bzw. mit sudo ausführen." >&2
    exit 1
fi

if [[ ! -f "$SOURCE_DIR/config-agent.pl" ]]; then
    echo "Quellordner '$SOURCE_DIR' enthält kein config-agent.pl, Pfad prüfen." >&2
    exit 1
fi


# ---------------------------------------------------------------------------
# 1. Repositories
# ---------------------------------------------------------------------------

log "1/7: Repositories aktualisieren"

# Der Config-Agent ist die Control-Plane-Basis. Ein defektes optionales
# Workload-/Baseline-Repository darf Repair/Update des Agents nicht blockieren.
# infrastructure-baseline wird deshalb fuer diesen Basisschritt temporaer
# deaktiviert und anschliessend in seinem vorherigen Zustand wiederhergestellt.
_BASELINE_REPO_WAS_PRESENT=0
_BASELINE_REPO_WAS_ENABLED=0
# Nicht anhand fester zypper-Spaltenpositionen parsen: diese unterscheiden sich
# je nach Version/Locale. Alias in der Tabellenzeile erkennen und den Enabled-
# Zustand separat ueber `zypper lr -E` ermitteln.
if zypper lr 2>/dev/null | grep -Eq '\|[[:space:]]*infrastructure-baseline[[:space:]]*\|'; then
    _BASELINE_REPO_WAS_PRESENT=1
    if zypper lr -E 2>/dev/null | grep -Eq '\|[[:space:]]*infrastructure-baseline[[:space:]]*\|'; then
        _BASELINE_REPO_WAS_ENABLED=1
    fi
    zypper --non-interactive mr -d infrastructure-baseline >/dev/null 2>&1 || true
fi
restore_optional_repo(){
    if [[ "$_BASELINE_REPO_WAS_PRESENT" == "1" && "$_BASELINE_REPO_WAS_ENABLED" == "1" ]]; then
        zypper --non-interactive mr -e infrastructure-baseline >/dev/null 2>&1 || true
    fi
}
trap restore_optional_repo EXIT

zypper --non-interactive refresh


# ---------------------------------------------------------------------------
# 2. Abhängigkeiten
# ---------------------------------------------------------------------------

log "2/7: Abhängigkeiten installieren"

zypper --non-interactive install \
    git \
    unzip \
    rsync \
    perl-Mojolicious \
    perl-Net-CIDR \
    perl-IO-Socket-SSL \
    perl-XML-LibXML \
    openssl \
    curl \
    tar \
    gzip \
    python3

restore_optional_repo
_BASELINE_REPO_WAS_ENABLED=0

# perl-IO-Socket-SSL wird von Mojo::IOLoop für HTTPS benötigt.


# ---------------------------------------------------------------------------
# 3. Agent-Code
# ---------------------------------------------------------------------------

log "3/7: Code nach $APP_DIR kopieren"

install -d -o root -g root -m 0755 /opt/service /opt/service_script /opt/mmbb_services /opt/mmbb_script
install -d -o root -g root -m 0700 /var/lib/service/config-agent/secrets
install -d -o root -g root -m 0755 /etc/systemd/system/alloy.service.d
mkdir -p "$APP_DIR"

rsync -a --delete \
    --exclude 'global.json' \
    --exclude 'managed_configs.json' \
    --exclude 'git_deploy.json' \
    --exclude 'managed_configs.json.lock' \
    "$SOURCE_DIR"/ "$APP_DIR"/


# ---------------------------------------------------------------------------
# 4. TLS
# ---------------------------------------------------------------------------

log "4/7: TLS-Zertifikat anlegen (falls noch keines existiert)"

mkdir -p "$SSL_DIR"

HOSTNAME_FQDN="${CONFIG_AGENT_FQDN:-$SERVER_FQDN}"

PRIMARY_IP="${CONFIG_AGENT_BIND_IP:-$SERVER_IP}"

# Stabile Host-Identitaet fuer Control Plane und Observability-Korrelation.
# Enrollment kann eine Host-ID/Labels vorgeben; fuer lokale/Legacy-Installationen
# wird deterministisch aus dem FQDN abgeleitet.
CONFIG_AGENT_HOST_ID_VALUE="${CONFIG_AGENT_HOST_ID:-}"
if [[ -z "$CONFIG_AGENT_HOST_ID_VALUE" ]]; then
    CONFIG_AGENT_HOST_ID_VALUE="host-$(printf '%s' "$HOSTNAME_FQDN" | tr '[:upper:]' '[:lower:]' | sha256sum | awk '{print substr($1,1,16)}')"
fi
CONFIG_AGENT_LABELS_JSON_VALUE="${CONFIG_AGENT_LABELS_JSON:-{}}"
CONFIG_AGENT_GROUPS_JSON_VALUE="${CONFIG_AGENT_GROUPS_JSON:-[]}"
install -d -o root -g root -m 0700 "$(dirname "$IDENTITY_FILE")"
/usr/bin/python3 - "$IDENTITY_FILE" "$CONFIG_AGENT_HOST_ID_VALUE" "$HOSTNAME_FQDN" "$CONFIG_AGENT_LABELS_JSON_VALUE" "$CONFIG_AGENT_GROUPS_JSON_VALUE" <<'PY_IDENTITY'
import json, os, sys, tempfile
path, host_id, hostname, labels_raw, groups_raw = sys.argv[1:]
try: labels=json.loads(labels_raw)
except Exception: labels={}
try: groups=json.loads(groups_raw)
except Exception: groups=[]
if not isinstance(labels,dict): labels={}
if not isinstance(groups,list): groups=[]
data={"schema_version":1,"host_id":host_id,"hostname":hostname,"labels":labels,"groups":groups}
d=os.path.dirname(path); fd,tmp=tempfile.mkstemp(prefix='.identity.',dir=d,text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(data,f,indent=2,ensure_ascii=False); f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY_IDENTITY
chown root:root "$IDENTITY_FILE"
chmod 0600 "$IDENTITY_FILE"

if [[ ! -f "$SSL_DIR/agent.local.crt" || ! -f "$SSL_DIR/agent.local.key" ]]; then

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -days 825 \
        -keyout "$SSL_DIR/agent.local.key" \
        -out "$SSL_DIR/agent.local.crt" \
        -subj "/CN=${HOSTNAME_FQDN}" \
        -addext "subjectAltName=DNS:${HOSTNAME_FQDN},IP:${PRIMARY_IP:-127.0.0.1},IP:127.0.0.1"

    chmod 600 "$SSL_DIR/agent.local.key"
    chmod 644 "$SSL_DIR/agent.local.crt"

    echo "Selbstsigniertes Zertifikat erzeugt:"
    echo "  CN: ${HOSTNAME_FQDN}"
    echo
    echo "HINWEIS:"
    echo "  Für produktiven Betrieb später durch ein CA-Zertifikat ersetzen."
else
    echo "Zertifikat existiert bereits und wird nicht überschrieben."
fi


# ---------------------------------------------------------------------------
# 5. Agent installieren
# ---------------------------------------------------------------------------

log "5/7: Config-Agent installieren"

if [[ "${TEKO_FORCE:-0}" == "1" ]]; then
    echo "FORCE: Config-Agent-Konfigurationen werden auf den Paketstand zurueckgesetzt."
    rm -f "$APP_DIR/global.json" "$APP_DIR/managed_configs.json" "$APP_DIR/git_deploy.json" \
          "$APP_DIR/managed_configs.json.lock"
fi

cd "$APP_DIR"

chmod +x _install.sh _analyze.sh _remove.sh 2>/dev/null || true

/bin/bash ./_install.sh --no-start

# Unterstützte TEKO/MMBB Deploy-Roots müssen existieren, bevor Git-Deploy
# global.json validiert wird. Damit bleiben bestehende MMBB-Profile und die
# neueren /opt/service*-Pfade unter demselben strikten Path-Guard nutzbar.
install -d -o root -g root -m 0755 /opt/service /opt/service_script /opt/mmbb_services /opt/mmbb_script
install -d -o root -g root -m 0700 /var/lib/service/config-agent/secrets
install -d -o root -g root -m 0755 /etc/systemd/system/alloy.service.d

# Ein-Server-Konfiguration nach Installation konsistent halten.
AGENT_LISTEN="127.0.0.1:5008"
# Einheitliche ACL auf allen Hosts: Manager-IP plus Loopback. Auf dem
# Management-Host ist SERVER_IP zugleich die eigene Manager-IP.
AGENT_ALLOWED_IPS="${SERVER_IP}/32,127.0.0.1/32"
if [[ "${CONFIG_AGENT_REMOTE_MODE:-0}" == "1" ]]; then
    : "${CONFIG_MANAGER_IP:?CONFIG_MANAGER_IP ist im Remote-Modus erforderlich}"
    AGENT_LISTEN="${CONFIG_AGENT_BIND_IP:-$SERVER_IP}:${CONFIG_AGENT_PORT:-5008}"
    AGENT_ALLOWED_IPS="${CONFIG_MANAGER_IP}/32,127.0.0.1/32"
fi

REMOTE_MODE="${CONFIG_AGENT_REMOTE_MODE:-0}"
FORGEJO_TOKEN_PRESENT=0
[[ -s /opt/service/env/forgejo-api.token ]] && FORGEJO_TOKEN_PRESENT=1

python3 - "$APP_DIR/global.json" "$APP_DIR/git_deploy.json" "https://${FORGEJO_FQDN}" "$AGENT_LISTEN" "$AGENT_ALLOWED_IPS" "$REMOTE_MODE" "$FORGEJO_TOKEN_PRESENT" <<'PY'
import json, sys
global_file, deploy_file, forgejo_url, agent_listen, allowed_csv, remote_mode, forgejo_token_present = sys.argv[1:8]
remote_mode = remote_mode == "1"
forgejo_token_present = forgejo_token_present == "1"

with open(global_file, encoding="utf-8") as f:
    cfg = json.load(f)

cfg["listen"] = agent_listen
cfg["allowed_ips"] = [x for x in allowed_csv.split(",") if x]
# Legacy-Upgrades: fruehere global.json koennen den Schalter noch nicht enthalten.
# Nur bei fehlendem Key den aktuellen sicheren Paket-Default setzen; ein bewusst
# konfiguriertes false bleibt unveraendert.
cfg.setdefault("auto_create_backups", True)

forgejo = cfg.setdefault("forgejo", {})
forgejo["url"] = forgejo_url
forgejo["token_file"] = "/opt/service/env/forgejo-api.token"
forgejo["verify_tls"] = False
git_upload = cfg.setdefault("git_upload", {})
git_upload["allowed_owners"] = ["teko"]
git_deploy = cfg.setdefault("git_deploy", {})

# Einheitliches Agent-Schema fuer Management-Host und Remote-Clients.
# Enrollment verteilt den Forgejo-Service-Token ueber den gepinnten SSH-Kanal,
# damit Git Deploy/Repository Upload auf jedem verwalteten Host identisch
# vorbereitet sind. Ein fehlender Token wird nicht durch stille Deaktivierung
# kaschiert; die Runtime meldet dann den fehlenden Credential explizit.
git_upload["enabled"] = True
git_deploy["enabled"] = True
gd_roots = git_deploy.setdefault("allowed_roots", [])
for canonical_root in ("/opt/service", "/opt/service_script", "/opt/mmbb_services", "/opt/mmbb_script"):
    if canonical_root not in gd_roots:
        gd_roots.append(canonical_root)
allowed_roots = cfg.setdefault("allowed_roots", [])
for canonical_root in ("/etc", "/opt", "/srv", "/var/lib", "/var/log", "/usr/local"):
    if canonical_root not in allowed_roots:
        allowed_roots.append(canonical_root)
# File Manager: Host weit lesen/browsen, aber nur in administrativen Baeumen schreiben.
# Legacy-Key wird bei jedem Rollout entfernt, damit alle Hosts exakt dasselbe aktuelle Schema verwenden.
cfg.pop("file_manager_roots", None)
cfg["file_manager_read_roots"] = ["/"]
cfg["file_manager_write_roots"] = ["/etc", "/opt", "/srv", "/var/lib", "/var/log", "/usr/local"]
with open(global_file + ".tmp", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
import os
os.replace(global_file + ".tmp", global_file)

if os.path.isfile(deploy_file):
    with open(deploy_file, encoding="utf-8") as f:
        deploy = json.load(f)
    profiles = deploy.get("profiles")
    if not isinstance(profiles, dict):
        profiles = {}

    # Alte, vom TEKO-Paket stammende Beispielprofile nicht weiter als aktive
    # Produktions-Defaults verwenden. Der Single-Server-Stack besitzt ein
    # eigenes, vom Forgejo-Bootstrap angelegtes Repository teko/config-deploy.
    legacy_urls = {
        "https://git.local/service/l2p-agent.git",
        "https://git.local/service/postfix_attachment.git",
        "http://git.local:3000/service/l2p-agent.git",
        "http://git.local:3000/service/postfix_attachment.git",
        "http://git.internal.local:3000/service/l2p-agent.git",
        "http://git.internal.local:3000/service/postfix_attachment.git",
    }
    for key in list(profiles):
        p = profiles.get(key)
        if isinstance(p, dict) and str(p.get("repository", "")) in legacy_urls:
            del profiles[key]

    if not profiles:
        profiles["teko-config-deploy"] = {
            "repository": forgejo_url.rstrip("/") + "/teko/config-deploy.git",
            "branch": "main",
            "target": "/opt/service/config-deploy",
            "owner": "root",
            "group": "root",
            "preserve": [],
        }
    else:
        # Nur historische HTTP-/Port-3000-URLs migrieren; benutzerdefinierte
        # Repositories bleiben unangetastet.
        for p in profiles.values():
            if not isinstance(p, dict):
                continue
            repo = str(p.get("repository", ""))
            repo = repo.replace("http://git.internal.local:3000/", forgejo_url.rstrip("/") + "/")
            repo = repo.replace("http://git.local:3000/", forgejo_url.rstrip("/") + "/")
            if repo:
                p["repository"] = repo

    deploy["schema_version"] = 2
    deploy["profiles"] = profiles
    tmp = deploy_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(deploy, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, deploy_file)
PY
chmod 0640 "$APP_DIR/global.json" "$APP_DIR/git_deploy.json" 2>/dev/null || true


# ---------------------------------------------------------------------------
# 6. Secrets / API-Token
# ---------------------------------------------------------------------------

log "6/7: Agent-Secret und API-Token prüfen"

mkdir -p "$ENV_DIR"

touch "$ENV_FILE"
# Explizite Capability-Scopes fuer den host-spezifischen Agent-Token.
# Bestehende Werte werden respektiert; neue Installationen erhalten die fuer
# Config Manager benoetigten Rollen ohne Wildcard.
REQUIRED_TOKEN_SCOPES='status.read,config.read,config.write,file.read,file.manage,baseline.manage,package.manage,security.manage,git.deploy,service.control'
if ! grep -q '^CONFIG_AGENT_TOKEN_SCOPES=' "$ENV_FILE" 2>/dev/null; then
    printf '%s
' "CONFIG_AGENT_TOKEN_SCOPES=$REQUIRED_TOKEN_SCOPES" >> "$ENV_FILE"
else
    # Bestehende Installationen behalten ihre Scopes, erhalten aber spaeter
    # ergaenzte Pflicht-Scopes nachtraeglich. Ohne diesen Merge blieb z. B.
    # security.manage auf aelteren Agenten dauerhaft fehlend und jede
    # Firewall-Aktion des Portals endete in HTTP 403.
    CURRENT_TOKEN_SCOPES="$(sed -n 's/^CONFIG_AGENT_TOKEN_SCOPES=//p' "$ENV_FILE" | tail -n1)"
    MERGED_TOKEN_SCOPES="$CURRENT_TOKEN_SCOPES"
    if [[ "$CURRENT_TOKEN_SCOPES" != "*" ]]; then
        IFS=',' read -r -a _req_scopes <<< "$REQUIRED_TOKEN_SCOPES"
        for _scope in "${_req_scopes[@]}"; do
            [[ ",$MERGED_TOKEN_SCOPES," == *",$_scope,"* ]] && continue
            MERGED_TOKEN_SCOPES="${MERGED_TOKEN_SCOPES:+$MERGED_TOKEN_SCOPES,}$_scope"
        done
    fi
    if [[ "$MERGED_TOKEN_SCOPES" != "$CURRENT_TOKEN_SCOPES" ]]; then
        _env_tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
        grep -v '^CONFIG_AGENT_TOKEN_SCOPES=' "$ENV_FILE" > "$_env_tmp"
        printf '%s
' "CONFIG_AGENT_TOKEN_SCOPES=$MERGED_TOKEN_SCOPES" >> "$_env_tmp"
        chmod 600 "$_env_tmp"; mv -f "$_env_tmp" "$ENV_FILE"
        log "Agent-Token-Scopes ergaenzt: $MERGED_TOKEN_SCOPES"
    fi
fi

chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"


# ---------------------------------------------------------------------------
# Alte Variable aus älteren Versionen entfernen
# ---------------------------------------------------------------------------

if grep -q '^API_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    sed -i '/^API_TOKEN=/d' "$ENV_FILE"
    echo "Alten API_TOKEN-Eintrag entfernt."
fi


# ---------------------------------------------------------------------------
# CONFIG_AGENT_SECRET
# ---------------------------------------------------------------------------

CURRENT_SECRET="$(
    sed -n 's/^CONFIG_AGENT_SECRET=//p' "$ENV_FILE" \
        | tail -n1
)"

if [[ -z "$CURRENT_SECRET" \
   || "$CURRENT_SECRET" == *CHANGE_ME* \
   || "$CURRENT_SECRET" == "<langes-zufaelliges-secret>" \
   || ${#CURRENT_SECRET} -lt 32 ]]; then

    NEW_SECRET="$(openssl rand -hex 32)"

    sed -i '/^CONFIG_AGENT_SECRET=/d' "$ENV_FILE"

    printf 'CONFIG_AGENT_SECRET=%s\n' "$NEW_SECRET" >> "$ENV_FILE"

    echo "Neues internes CONFIG_AGENT_SECRET generiert."
else
    echo "CONFIG_AGENT_SECRET ist bereits gesetzt und wird nicht verändert."
fi


# ---------------------------------------------------------------------------
# CONFIG_AGENT_API_TOKEN
# ---------------------------------------------------------------------------

CURRENT_API_TOKEN="$(
    sed -n 's/^CONFIG_AGENT_API_TOKEN=//p' "$ENV_FILE" \
        | tail -n1
)"

if [[ -z "$CURRENT_API_TOKEN" \
   || "$CURRENT_API_TOKEN" == *CHANGE_ME* \
   || "$CURRENT_API_TOKEN" == "<langer-zufaelliger-token>" \
   || ${#CURRENT_API_TOKEN} -lt 32 ]]; then

    NEW_API_TOKEN="$(openssl rand -hex 32)"

    sed -i '/^CONFIG_AGENT_API_TOKEN=/d' "$ENV_FILE"

    printf 'CONFIG_AGENT_API_TOKEN=%s\n' "$NEW_API_TOKEN" >> "$ENV_FILE"

    CURRENT_API_TOKEN="$NEW_API_TOKEN"

    echo "Neues CONFIG_AGENT_API_TOKEN generiert."
else
    echo "CONFIG_AGENT_API_TOKEN ist bereits gesetzt und wird nicht verändert."
fi


# ---------------------------------------------------------------------------
# Rechte nochmals sicherstellen
# ---------------------------------------------------------------------------

chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"


# ---------------------------------------------------------------------------
# API-Token für Config-Manager bereitstellen
#
# WICHTIG:
# Nur der API-Token wird übergeben.
# CONFIG_AGENT_SECRET verlässt den Agent niemals.
# ---------------------------------------------------------------------------

install \
    -o root \
    -g root \
    -m 0600 \
    /dev/null \
    "$TOKEN_HANDOFF_FILE"

printf '%s' "$CURRENT_API_TOKEN" > "$TOKEN_HANDOFF_FILE"

echo "API-Token-Handoff aktualisiert:"
echo "  $TOKEN_HANDOFF_FILE"


# ---------------------------------------------------------------------------
# 7. Dienst
# ---------------------------------------------------------------------------

log "7/7: Dienst aktivieren, starten und analysieren"

systemctl daemon-reload
systemctl enable config-agent.service
systemctl restart config-agent.service

sleep 1

if ! systemctl is-active --quiet config-agent.service; then

    echo "Config-Agent ist nicht aktiv:" >&2

    journalctl \
        -u config-agent.service \
        --no-pager \
        -n 40 || true

    exit 1
fi

./_analyze.sh || true


# ---------------------------------------------------------------------------
# Abschluss
# ---------------------------------------------------------------------------

log "Fertig."

LISTEN_PORT="$(
    grep -oE '"listen":\s*"[^"]*:[0-9]+"' "$APP_DIR/global.json" \
        | grep -oE '[0-9]+$' \
        | head -n1 \
        || echo 5008
)"

echo
echo "Config-Agent:"
echo "  https://${PRIMARY_IP:-<server-ip>}:${LISTEN_PORT}"
echo
echo "ENV-Datei:"
echo "  $ENV_FILE"
echo
echo "Enthält:"
echo "  CONFIG_AGENT_SECRET"
echo "  CONFIG_AGENT_API_TOKEN"
echo
echo "API-Token-Handoff:"
echo "  $TOKEN_HANDOFF_FILE"
echo
echo "Das interne CONFIG_AGENT_SECRET wird NICHT an den Config-Manager weitergegeben."
echo
echo "setup_config_manager.sh kann $TOKEN_HANDOFF_FILE automatisch lesen,"
echo "wenn Config-Agent und Config-Manager auf demselben Host installiert sind."
echo
echo "Bei selbstsigniertem TLS-Zertifikat muss TLS-Verify im Portal"
echo "vorerst deaktiviert bleiben."
