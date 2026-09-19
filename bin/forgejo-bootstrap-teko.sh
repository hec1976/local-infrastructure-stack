#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck disable=SC1090
source "$STACK_ROOT/teko-stack.conf"

ORG="${FORGEJO_ORG:-teko}"
REPO="${FORGEJO_REPO:-config-deploy}"
OBS_REPO="${FORGEJO_OBSERVABILITY_REPO:-observability-client}"
TEAM="${FORGEJO_TEAM:-teko-deploy}"
SERVICE_USER="${FORGEJO_SERVICE_USER:-svc-teko-deploy}"
SERVICE_EMAIL="${FORGEJO_SERVICE_EMAIL:-svc-teko-deploy@teko.local}"
TEAM_PERMISSION="${FORGEJO_TEAM_PERMISSION:-write}"
TOKEN_FILE="${FORGEJO_TOKEN_FILE:-/opt/service/env/forgejo-api.token}"
TOKEN_SCOPES="${FORGEJO_SERVICE_TOKEN_SCOPES:-write:repository,write:organization,read:user}"
TOKEN_CAPABILITY_VERSION="3"
TOKEN_META_FILE="${TOKEN_FILE}.meta"
API_BASE="${FORGEJO_LOCAL_API:-http://127.0.0.1:${FORGEJO_HTTP_PORT:-3000}/api/v1}"
CONTAINER="${FORGEJO_CONTAINER:-forgejo}"

log(){ printf '\n>>> %s\n' "$*"; }
die(){ echo "FEHLER: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte als root/sudo ausfuehren."
command -v podman >/dev/null 2>&1 || die "podman fehlt"
command -v curl >/dev/null 2>&1 || die "curl fehlt"
command -v python3 >/dev/null 2>&1 || die "python3 fehlt"
podman container exists "$CONTAINER" || die "Forgejo-Container '$CONTAINER' fehlt"

forgejo_cli(){ podman exec "$CONTAINER" forgejo "$@"; }
user_exists(){
    local wanted="$1"
    forgejo_cli admin user list 2>/dev/null | awk -v u="$wanted" '$1 ~ /^[0-9]+$/ && $2 == u {found=1} END {exit(found?0:1)}'
}

# Greenfield-Readiness: Erst wenn die Forgejo-CLI die SQLite-Datenbank lesen
# kann, ist die interne Initialisierung abgeschlossen. Eine HTTP-Startseite
# allein reicht nicht, weil Forgejo dort im Installationsmodus bereits 200/404
# liefern kann.
log "Forgejo Datenbank / CLI Readiness pruefen"
CLI_READY=0
for _ in $(seq 1 180); do
    if forgejo_cli admin user list >/dev/null 2>&1; then
        CLI_READY=1
        break
    fi
    sleep 1
done
if [[ "$CLI_READY" != "1" ]]; then
    echo "Forgejo Service Status:" >&2
    systemctl status forgejo.service --no-pager -l >&2 || true
    echo "Forgejo Container Logs:" >&2
    podman logs --tail 100 "$CONTAINER" >&2 || true
    die "Forgejo SQLite/CLI wurde nicht bereit"
fi

# Auf einem neuen Server existiert noch kein Administrator. Der Installer
# erzeugt deshalb genau einmal einen lokalen Admin und legt das zufaellige
# Passwort ausschliesslich in einer root-lesbaren Datei ab.
ADMIN_USER="${FORGEJO_BOOTSTRAP_ADMIN_USER:-gitadmin}"
ADMIN_EMAIL="${FORGEJO_BOOTSTRAP_ADMIN_EMAIL:-gitadmin@teko.local}"
ADMIN_ENV_FILE="${FORGEJO_ADMIN_ENV_FILE:-/opt/service/env/forgejo-admin.env}"

EXISTING_ADMIN="$(forgejo_cli admin user list --admin 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $2; exit}')"
if [[ -z "$EXISTING_ADMIN" ]]; then
    log "Forgejo Erstinstallation: lokalen Administrator anlegen"
    install -d -o root -g root -m 0700 "$(dirname "$ADMIN_ENV_FILE")"
    ADMIN_PASSWORD="$(openssl rand -base64 48 | tr -d '\n/=+' | cut -c1-36)"
    [[ ${#ADMIN_PASSWORD} -ge 24 ]] || die "Admin-Passwort konnte nicht sicher erzeugt werden"
    forgejo_cli admin user create \
        --username "$ADMIN_USER" \
        --password "$ADMIN_PASSWORD" \
        --email "$ADMIN_EMAIL" \
        --admin \
        --must-change-password=false >/dev/null
    tmp="$(mktemp "${ADMIN_ENV_FILE}.tmp.XXXXXX")"
    {
        printf 'FORGEJO_ADMIN_USER=%s\n' "$ADMIN_USER"
        printf 'FORGEJO_ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
        printf 'FORGEJO_ADMIN_EMAIL=%s\n' "$ADMIN_EMAIL"
    } > "$tmp"
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$ADMIN_ENV_FILE"
    unset ADMIN_PASSWORD
    echo "Forgejo Admin erstellt: $ADMIN_USER"
    echo "Admin-Zugang sicher gespeichert: $ADMIN_ENV_FILE"
    EXISTING_ADMIN="$ADMIN_USER"
else
    ADMIN_USER="$EXISTING_ADMIN"
    echo "Forgejo Administrator vorhanden: $ADMIN_USER"
fi

# Nach INSTALL_LOCK + DB-Initialisierung muss die echte REST-API antworten.
log "Forgejo REST API Readiness pruefen"
API_READY=0
for _ in $(seq 1 180); do
    if curl -fsS "${API_BASE%/api/v1}/api/v1/version" >/dev/null 2>&1; then
        API_READY=1
        break
    fi
    sleep 1
done
if [[ "$API_READY" != "1" ]]; then
    echo "Direkte Forgejo API Antwort:" >&2
    curl -sS -i "${API_BASE%/api/v1}/api/v1/version" >&2 || true
    echo "Forgejo Container Logs:" >&2
    podman logs --tail 100 "$CONTAINER" >&2 || true
    die "Forgejo REST API ist nach der automatischen Initialisierung nicht bereit"
fi

log "Forgejo Service-User pruefen"
if user_exists "$SERVICE_USER"; then
    echo "Service-User vorhanden: $SERVICE_USER"
else
    forgejo_cli admin user create \
        --username "$SERVICE_USER" \
        --email "$SERVICE_EMAIL" \
        --random-password \
        --random-password-length 40 \
        --must-change-password=false >/dev/null
    echo "Service-User erstellt: $SERVICE_USER"
fi

# Fuer das idempotente Org/Team/Repo-Bootstrap wird kurzfristig ein Token des
# ersten Forgejo-Administrators erzeugt. Er wird am Ende wieder geloescht.
# ADMIN_USER wurde beim Greenfield-/Existing-Check oben bereits eindeutig
# bestimmt. Dadurch funktioniert derselbe Bootstrap sowohl bei einer leeren
# Installation als auch idempotent auf bestehenden Servern.
[[ -n "$ADMIN_USER" ]] || die "Kein Forgejo-Administrator verfuegbar"

ADMIN_TOKEN_NAME="teko-bootstrap-$RANDOM-$$"
ADMIN_TOKEN="$(forgejo_cli admin user generate-access-token \
    --username "$ADMIN_USER" --token-name "$ADMIN_TOKEN_NAME" \
    --scopes all --raw 2>/dev/null | tr -d '\r\n')"
[[ ${#ADMIN_TOKEN} -ge 20 ]] || die "Temporärer Forgejo-Admin-Token konnte nicht erzeugt werden"

cleanup_admin_token(){
    if [[ -n "${ADMIN_TOKEN:-}" ]]; then
        curl -sS -o /dev/null -X DELETE \
            -H "Authorization: token $ADMIN_TOKEN" \
            "$API_BASE/users/$ADMIN_USER/tokens/$ADMIN_TOKEN_NAME" || true
    fi
}
trap cleanup_admin_token EXIT

api_call(){
    local method="$1" path="$2" body="${3:-}" out
    out="$(mktemp)"
    if [[ -n "$body" ]]; then
        API_STATUS="$(curl -sS -o "$out" -w '%{http_code}' -X "$method" \
            -H "Authorization: token $ADMIN_TOKEN" -H 'Content-Type: application/json' \
            --data "$body" "$API_BASE$path" || true)"
    else
        API_STATUS="$(curl -sS -o "$out" -w '%{http_code}' -X "$method" \
            -H "Authorization: token $ADMIN_TOKEN" "$API_BASE$path" || true)"
    fi
    API_BODY="$(cat "$out" 2>/dev/null || true)"
    rm -f "$out"
}

# Der Repository-Upload-Service muss die verwaltete Organisation sehen und dort
# Repositories erstellen koennen. Ein als "restricted" angelegter Altbenutzer
# kann bei privaten Organisationen in API-Sichtbarkeitspruefungen mit 404
# scheitern. Bestehende Installationen werden deshalb explizit auf einen
# normalen, weiterhin nicht-administrativen Service-User migriert.
log "Forgejo Service-User Capability-Modus pruefen"
svc_payload='{"login_name":"","source_id":0,"restricted":false,"admin":false,"active":true,"prohibit_login":false,"allow_create_organization":false,"allow_git_hook":false,"allow_import_local":false,"max_repo_creation":-1}'
api_call PATCH "/admin/users/$SERVICE_USER" "$svc_payload"
status="$API_STATUS"
[[ "$status" == "200" ]] || die "Service-User '$SERVICE_USER' konnte nicht auf Repository-Create-Modus aktualisiert werden (HTTP $status): $API_BODY"
echo "Service-User Capability-Modus: normaler Non-Admin Automation-User"

log "Organisation '$ORG' pruefen"
api_call GET "/orgs/$ORG"
status="$API_STATUS"
if [[ "$status" == "200" ]]; then
    echo "Organisation vorhanden: $ORG"
elif [[ "$status" == "404" ]]; then
    payload="$(python3 - "$ORG" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"full_name":"TEKO","description":"TEKO managed infrastructure","visibility":"private"}))
PY
)"
    api_call POST "/orgs" "$payload"
    status="$API_STATUS"
    [[ "$status" == "201" ]] || die "Organisation '$ORG' konnte nicht erstellt werden (HTTP $status): $API_BODY"
    echo "Organisation erstellt: $ORG"
else
    die "Organisation '$ORG' konnte nicht geprueft werden (HTTP $status): $API_BODY"
fi

log "Repository '$ORG/$REPO' pruefen"
api_call GET "/repos/$ORG/$REPO"
status="$API_STATUS"
if [[ "$status" == "200" ]]; then
    echo "Repository vorhanden: $ORG/$REPO"
elif [[ "$status" == "404" ]]; then
    payload="$(python3 - "$REPO" <<'PY'
import json,sys
print(json.dumps({
  "name":sys.argv[1],
  "description":"TEKO managed configuration deployment repository",
  "private":True,
  "auto_init":True,
  "default_branch":"main",
  "readme":"Default"
}))
PY
)"
    api_call POST "/orgs/$ORG/repos" "$payload"
    status="$API_STATUS"
    [[ "$status" == "201" ]] || die "Repository '$ORG/$REPO' konnte nicht erstellt werden (HTTP $status): $API_BODY"
    echo "Repository erstellt: $ORG/$REPO"
else
    die "Repository '$ORG/$REPO' konnte nicht geprueft werden (HTTP $status): $API_BODY"
fi

log "Repository '$ORG/$OBS_REPO' pruefen"
api_call GET "/repos/$ORG/$OBS_REPO"
status="$API_STATUS"
if [[ "$status" == "200" ]]; then
    echo "Repository vorhanden: $ORG/$OBS_REPO"
elif [[ "$status" == "404" ]]; then
    payload="$(python3 - "$OBS_REPO" <<'PYOBSREPO'
import json,sys
print(json.dumps({
  "name":sys.argv[1],
  "description":"Managed observability client package deployment",
  "private":True,
  "auto_init":True,
  "default_branch":"main",
  "readme":"Default"
}))
PYOBSREPO
)"
    api_call POST "/orgs/$ORG/repos" "$payload"
    status="$API_STATUS"
    [[ "$status" == "201" ]] || die "Repository '$ORG/$OBS_REPO' konnte nicht erstellt werden (HTTP $status): $API_BODY"
    echo "Repository erstellt: $ORG/$OBS_REPO"
else
    die "Repository '$ORG/$OBS_REPO' konnte nicht geprueft werden (HTTP $status): $API_BODY"
fi

log "Team '$TEAM' pruefen"
api_call GET "/orgs/$ORG/teams?limit=100"
status="$API_STATUS"
[[ "$status" == "200" ]] || die "Teams konnten nicht gelesen werden (HTTP $status): $API_BODY"
TEAM_ID="$(printf '%s' "$API_BODY" | python3 -c 'import json,sys; n=sys.argv[1]; a=json.load(sys.stdin); print(next((x.get("id","") for x in a if x.get("name")==n),""))' "$TEAM")"
if [[ -z "$TEAM_ID" ]]; then
    payload="$(python3 - "$TEAM" "$TEAM_PERMISSION" <<'PY'
import json,sys
print(json.dumps({
  "name":sys.argv[1],
  "description":"TEKO Config Manager Git deployment service",
  "permission":sys.argv[2],
  "includes_all_repositories":False,
  "can_create_org_repo":True,
  # Forgejo >= 11 requires explicit repository-unit permissions when a
  # non-owner team is created.  The deploy service only needs Git code
  # access; keep the team deliberately least-privileged.
  "units_map": {
    "repo.code": sys.argv[2]
  }
}))
PY
)"
    api_call POST "/orgs/$ORG/teams" "$payload"
    status="$API_STATUS"
    [[ "$status" == "201" ]] || die "Team '$TEAM' konnte nicht erstellt werden (HTTP $status): $API_BODY"
    TEAM_ID="$(printf '%s' "$API_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    [[ -n "$TEAM_ID" ]] || die "Team '$TEAM' wurde erstellt, aber Team-ID fehlt"
    echo "Team erstellt: $TEAM (permission=$TEAM_PERMISSION)"
else
    echo "Team vorhanden: $TEAM (ID $TEAM_ID)"
fi

# Der technische Upload-Service darf innerhalb der verwalteten TEKO-Organisation
# neue Repositories anlegen. Das ist fuer "Git Repository Upload -> Neu" noetig.
# Bestehende Installationen werden idempotent auf denselben Team-Stand gebracht.
payload="$(python3 - "$TEAM" "$TEAM_PERMISSION" <<'PYTEAM'
import json,sys
print(json.dumps({
  "name":sys.argv[1],
  "description":"TEKO Config Manager Git deployment service",
  "permission":sys.argv[2],
  "includes_all_repositories":False,
  "can_create_org_repo":True,
  "units_map":{"repo.code":sys.argv[2]}
}))
PYTEAM
)"
api_call PATCH "/teams/$TEAM_ID" "$payload"
status="$API_STATUS"
[[ "$status" == "200" ]] || die "Team '$TEAM' konnte fuer Repository-Erstellung nicht aktualisiert werden (HTTP $status): $API_BODY"
echo "Team Repository-Erstellung: aktiviert"

# Mitgliedschaft und Repository-Zuordnung sind idempotente PUT-Operationen.
api_call PUT "/teams/$TEAM_ID/members/$SERVICE_USER"
status="$API_STATUS"
[[ "$status" == "204" || "$status" == "201" ]] || die "Service-User konnte Team nicht zugeordnet werden (HTTP $status): $API_BODY"
api_call PUT "/teams/$TEAM_ID/repos/$ORG/$REPO"
status="$API_STATUS"
[[ "$status" == "204" || "$status" == "201" ]] || die "Repository konnte Team nicht zugeordnet werden (HTTP $status): $API_BODY"
api_call PUT "/teams/$TEAM_ID/repos/$ORG/$OBS_REPO"
status="$API_STATUS"
[[ "$status" == "204" || "$status" == "201" ]] || die "Observability-Repository konnte Team nicht zugeordnet werden (HTTP $status): $API_BODY"
echo "Team-Zuordnung aktiv: $SERVICE_USER -> $TEAM -> $ORG/$REPO, $ORG/$OBS_REPO"

log "Service-Token fuer Config Manager / Config-Agent"
install -d -o root -g root -m 0700 "$(dirname "$TOKEN_FILE")"
TOKEN_OK=0
if [[ -s "$TOKEN_FILE" && ! -L "$TOKEN_FILE" && -s "$TOKEN_META_FILE" && ! -L "$TOKEN_META_FILE" ]]; then
    existing="$(tr -d '\r\n' < "$TOKEN_FILE")"
    meta_version="$(sed -n 's/^capability_version=//p' "$TOKEN_META_FILE" | head -n1)"
    meta_scopes="$(sed -n 's/^scopes=//p' "$TOKEN_META_FILE" | head -n1)"
    code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: token $existing" "$API_BASE/user" || true)"
    if [[ "$code" == "200" && "$meta_version" == "$TOKEN_CAPABILITY_VERSION" && "$meta_scopes" == "$TOKEN_SCOPES" ]]; then
        perm_body="$(mktemp)"
        perm_code="$(curl -sS -o "$perm_body" -w '%{http_code}' -H "Authorization: token $existing"             "$API_BASE/users/$SERVICE_USER/orgs/$ORG/permissions" || true)"
        can_create="false"
        if [[ "$perm_code" == "200" ]]; then
            can_create="$(python3 - "$perm_body" <<'PYMETA'
import json,sys
try:
    d=json.load(open(sys.argv[1], encoding='utf-8'))
    print('true' if d.get('can_create_repository') is True else 'false')
except Exception:
    print('false')
PYMETA
)"
        fi
        rm -f "$perm_body"
        if [[ "$can_create" == "true" ]]; then
            TOKEN_OK=1
            echo "Vorhandener Forgejo Service-Token ist gueltig und besitzt Repository-Erstellrechte."
        fi
    fi
fi

TOKEN_REPO_ARGS=()
if forgejo_cli admin user generate-access-token --help 2>&1 | grep -q -- '--repo'; then
    TOKEN_REPO_ARGS=(--repo all)
fi

if [[ "$TOKEN_OK" != "1" ]]; then
    if [[ -s "$TOKEN_FILE" ]]; then
        echo "Vorhandener Forgejo Service-Token ist fuer die aktuelle Capability-Policy veraltet und wird rotiert."
    fi
    token_name="teko-config-manager-$(date +%Y%m%d%H%M%S)"
    SERVICE_TOKEN="$(forgejo_cli admin user generate-access-token \
        --username "$SERVICE_USER" --token-name "$token_name" \
        --scopes "$TOKEN_SCOPES" "${TOKEN_REPO_ARGS[@]}" --raw 2>/dev/null | tr -d '\r\n')"
    [[ ${#SERVICE_TOKEN} -ge 20 ]] || die "Service-Token konnte nicht erzeugt werden"
    tmp="$(mktemp "${TOKEN_FILE}.tmp.XXXXXX")"
    printf '%s' "$SERVICE_TOKEN" > "$tmp"
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$TOKEN_FILE"
    meta_tmp="$(mktemp "${TOKEN_META_FILE}.tmp.XXXXXX")"
    {
        printf 'capability_version=%s\n' "$TOKEN_CAPABILITY_VERSION"
        printf 'scopes=%s\n' "$TOKEN_SCOPES"
        printf 'service_user=%s\n' "$SERVICE_USER"
        printf 'organization=%s\n' "$ORG"
    } > "$meta_tmp"
    chown root:root "$meta_tmp"
    chmod 0600 "$meta_tmp"
    mv -f "$meta_tmp" "$TOKEN_META_FILE"
    echo "Service-Token erzeugt: $TOKEN_FILE"
fi

FP="$(sha256sum "$TOKEN_FILE" | awk '{print substr($1,1,12)}')"
echo "Token-Fingerprint: $FP"

# Verwaiste Capability-Probes aus abgebrochenen/frueheren Setup-Laeufen
# duerfen nicht im produktiven Organisations-Namespace liegen bleiben. Nur der
# reservierte Prefix wird bereinigt und die Loeschung erfolgt mit dem temporaeren
# Bootstrap-Admin-Token, niemals mit dem Least-Privilege Service-Token.
api_call GET "/orgs/$ORG/repos?limit=100"
if [[ "$API_STATUS" == "200" ]]; then
    while IFS= read -r stale_probe; do
        [[ -n "$stale_probe" ]] || continue
        api_call DELETE "/repos/$ORG/$stale_probe"
        if [[ "$API_STATUS" == "204" ]]; then
            echo "Verwaistes Capability-Probe-Repository entfernt: $ORG/$stale_probe"
        else
            die "Verwaistes Capability-Probe-Repository '$ORG/$stale_probe' konnte nicht entfernt werden (HTTP $API_STATUS): $API_BODY"
        fi
    done < <(python3 - <<'PYCLEAN' "$API_BODY"
import json,sys
try:
    data=json.loads(sys.argv[1])
except Exception:
    data=[]
for repo in data if isinstance(data,list) else []:
    name=repo.get('name','') if isinstance(repo,dict) else ''
    if name.startswith('teko-capability-probe-'):
        print(name)
PYCLEAN
)
fi

# End-to-End Capability-Probe mit exakt dem Token, den Config-Agent spaeter
# verwendet. Dadurch kann das Setup nicht mehr erfolgreich enden, wenn Lesen
# funktioniert, Repository-Erstellung aber in Forgejo mit 403/404 scheitert.
log "Service-Token Repository-Create End-to-End pruefen"
SERVICE_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
probe_repo="teko-capability-probe-$(date +%s)-$$"
probe_payload="$(python3 - "$probe_repo" <<'PYPROBE'
import json,sys
print(json.dumps({"name":sys.argv[1],"description":"temporary TEKO repository-create capability probe","private":True,"auto_init":False,"default_branch":"main"}))
PYPROBE
)"
probe_body="$(mktemp)"
probe_code="$(curl -sS -o "$probe_body" -w '%{http_code}' -X POST \
    -H "Authorization: token $SERVICE_TOKEN" -H 'Content-Type: application/json' \
    --data "$probe_payload" "$API_BASE/orgs/$ORG/repos" || true)"
if [[ "$probe_code" != "201" ]]; then
    probe_msg="$(cat "$probe_body" 2>/dev/null || true)"
    rm -f "$probe_body"
    die "Service-Token kann in Organisation '$ORG' kein Repository erstellen (HTTP $probe_code): $probe_msg"
fi
rm -f "$probe_body"

# Das Repository gehoert der Organisation, nicht dem Service-User. Forgejo
# verweigert deshalb DELETE mit dem Service-Token korrekt mit 403 ("user should
# be the owner of the repo"). Fuer den Capability-Nachweis ist ausschliesslich
# das erfolgreiche POST/201 relevant. Das temporaere Probe-Repository wird mit
# dem ohnehin nur waehrend dieses Bootstraps vorhandenen Admin-Token entfernt.
api_call DELETE "/repos/$ORG/$probe_repo"
probe_delete_code="$API_STATUS"
if [[ "$probe_delete_code" != "204" ]]; then
    die "Capability-Probe-Repository '$ORG/$probe_repo' wurde erfolgreich mit dem Service-Token erstellt, konnte aber durch den Bootstrap-Admin nicht entfernt werden (HTTP $probe_delete_code): $API_BODY"
fi
echo "Service-Token Repository-Erstellung: OK (Create 201; Cleanup via Bootstrap-Admin)"

log "Repository-Grundstruktur sicherstellen"
# Keine bestehende Datei wird ueberschrieben. Nur fehlende Scaffold-Dateien
# werden ueber die Contents-API angelegt.
SERVICE_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
ensure_file(){
    local path="$1" content="$2" encoded status body payload
    status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: token $SERVICE_TOKEN" \
        "$API_BASE/repos/$ORG/$REPO/contents/$path?ref=main" || true)"
    [[ "$status" == "200" ]] && return 0
    [[ "$status" == "404" ]] || die "Repository-Datei '$path' konnte nicht geprueft werden (HTTP $status)"
    encoded="$(printf '%s' "$content" | base64 -w0)"
    payload="$(python3 - "$encoded" "$path" <<'PY'
import json,sys
print(json.dumps({"content":sys.argv[1],"message":"TEKO bootstrap: add "+sys.argv[2],"branch":"main"}))
PY
)"
    body="$(mktemp)"
    status="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
        -H "Authorization: token $SERVICE_TOKEN" -H 'Content-Type: application/json' \
        --data "$payload" "$API_BASE/repos/$ORG/$REPO/contents/$path" || true)"
    if [[ "$status" != "201" ]]; then
        msg="$(cat "$body" 2>/dev/null || true)"; rm -f "$body"
        die "Scaffold-Datei '$path' konnte nicht erzeugt werden (HTTP $status): $msg"
    fi
    rm -f "$body"
}

ensure_file "profiles/.gitkeep" ""
ensure_file "configs/postfix/.gitkeep" ""
ensure_file "configs/apache/.gitkeep" ""
ensure_file "configs/monit/.gitkeep" ""
ensure_file "configs/modsecurity/.gitkeep" ""
ensure_file "configs/baseline/generic-linux/README.md" $'# Generic Linux Client Baseline\n\nDie Baseline besitzt nur die Host-Grundlage:\n\n- Config Agent / Host-ID\n- lokaler Monit HTTP/XML-Zugang fuer Server Health\n- Monit Credential\n\nSoftware-Rollout von Monit, Grafana Alloy und Monit Prometheus Exporter erfolgt ueber das Deploy-Profil `observability-client`. Workloads wie Apache, Postfix, Rspamd, Redis oder ModSecurity bleiben rollen-/dienstspezifisch unter `configs/`.\n'
ensure_file "configs/baseline/generic-linux/monit/README.md" $'# Monit Baseline\n\nHier liegen zusaetzliche generische Monit-Checks. Die HTTP-Grundkonfiguration wird ueber **Client Baseline** initialisiert. Service-spezifische Checks gehoeren in die jeweilige Workload-Konfiguration.\n'
ensure_file "configs/observability/alloy/README.md" $'# Grafana Alloy\n\nDie generische Alloy-Konfiguration gehoert zum RPM `client-baseline` und wird ueber das Deploy-Profil `observability-client` installiert. Zusaetzliche workload-spezifische Quellen (Postfix, Rspamd, Apache usw.) werden hier bzw. unter den jeweiligen Dienstkonfigurationen versioniert.\n'
ensure_file "profiles/generic-linux/README.md" $'# Generic Linux Profil\n\nVerknuepft die Client-Baseline mit einem Host bzw. einer Servergruppe. Keine Workload-Pakete in dieses Profil aufnehmen.\n'
ensure_file "profiles/mailserver/README.md" $'# Mailserver Profil\n\nErweitert `generic-linux` um mailserver-spezifische Konfigurationen, z. B. Postfix, Rspamd, Redis sowie deren Monit-/Alloy-Erweiterungen.\n'
ensure_file "profiles/webserver/README.md" $'# Webserver Profil\n\nErweitert `generic-linux` um Apache/ModSecurity und passende Monit-/Alloy-Erweiterungen.\n'
ensure_file "scripts/.gitkeep" ""
ensure_file "manifests/README.md" $'# TEKO Manifests\n\nDeployment-Manifeste und Metadaten fuer TEKO.\n'
ensure_file "TEKO-STRUCTURE.md" $'# TEKO config-deploy\n\nVerwaltete Struktur:\n\n- `profiles/` – Rollen/Zuordnungen (`generic-linux`, `mailserver`, `webserver`)\n- `configs/baseline/generic-linux/` – generische Client-Baseline (Monit + Alloy)\n- `configs/` – workload-spezifische Dienstkonfigurationen\n- `scripts/` – versionierte Hilfsskripte\n- `manifests/` – Deployment-Manifeste und Metadaten\n\nGrundsatz: Client Baseline verwaltet nur Config-Agent/Host-Identitaet und Monit-Zugang. Monit-Paket, Grafana Alloy und Monit Prometheus Exporter werden ueber das Deploy-Profil `observability-client` via Git Deploy verteilt. Apache, Postfix, Rspamd usw. bleiben rollen-/dienstspezifisch.\n\nZugriff fuer den Config Manager erfolgt ueber den Service-User `svc-teko-deploy`.\n'
# Observability Client ist ein eigenes Deployment-Repository.
# deploy-profile.json beschreibt den Sollzustand; install.sh ist der explizite
# Executor und wird durch Git Deploy als post_deploy im aktiven Release gestartet.
ensure_repo_file(){
    local repo="$1" path="$2" content="$3" encoded status body payload sha
    body="$(mktemp)"
    status="$(curl -sS -o "$body" -w '%{http_code}' \
        -H "Authorization: token $SERVICE_TOKEN" \
        "$API_BASE/repos/$ORG/$repo/contents/$path?ref=main" || true)"
    encoded="$(printf '%s' "$content" | base64 -w0)"
    if [[ "$status" == "200" ]]; then
        sha="$(python3 - "$body" <<'PYGETSHA'
import json,sys
try: print(json.load(open(sys.argv[1], encoding='utf-8')).get('sha',''))
except Exception: print('')
PYGETSHA
)"
        [[ -n "$sha" ]] || { rm -f "$body"; die "SHA fuer $repo/$path fehlt"; }
        payload="$(python3 - "$encoded" "$path" "$sha" <<'PYPUT'
import json,sys
print(json.dumps({"content":sys.argv[1],"message":"bootstrap: update "+sys.argv[2],"branch":"main","sha":sys.argv[3]}))
PYPUT
)"
        status="$(curl -sS -o "$body" -w '%{http_code}' -X PUT \
            -H "Authorization: token $SERVICE_TOKEN" -H 'Content-Type: application/json' \
            --data "$payload" "$API_BASE/repos/$ORG/$repo/contents/$path" || true)"
        [[ "$status" == "200" ]] || { msg="$(cat "$body")"; rm -f "$body"; die "Repository-Datei '$repo/$path' konnte nicht aktualisiert werden (HTTP $status): $msg"; }
    elif [[ "$status" == "404" ]]; then
        payload="$(python3 - "$encoded" "$path" <<'PYPOST'
import json,sys
print(json.dumps({"content":sys.argv[1],"message":"bootstrap: add "+sys.argv[2],"branch":"main"}))
PYPOST
)"
        status="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
            -H "Authorization: token $SERVICE_TOKEN" -H 'Content-Type: application/json' \
            --data "$payload" "$API_BASE/repos/$ORG/$repo/contents/$path" || true)"
        [[ "$status" == "201" ]] || { msg="$(cat "$body")"; rm -f "$body"; die "Repository-Datei '$repo/$path' konnte nicht erzeugt werden (HTTP $status): $msg"; }
    else
        msg="$(cat "$body")"; rm -f "$body"; die "Repository-Datei '$repo/$path' konnte nicht geprueft werden (HTTP $status): $msg"
    fi
    rm -f "$body"
}

delete_repo_file(){
    local repo="$1" path="$2" body status sha payload
    body="$(mktemp)"
    status="$(curl -sS -o "$body" -w '%{http_code}' -H "Authorization: token $SERVICE_TOKEN" \
      "$API_BASE/repos/$ORG/$repo/contents/$path?ref=main" || true)"
    if [[ "$status" == "404" ]]; then rm -f "$body"; return 0; fi
    [[ "$status" == "200" ]] || { rm -f "$body"; return 0; }
    sha="$(python3 - "$body" <<'PYDELSHA'
import json,sys
try: print(json.load(open(sys.argv[1], encoding='utf-8')).get('sha',''))
except Exception: print('')
PYDELSHA
)"
    rm -f "$body"
    [[ -n "$sha" ]] || return 0
    payload="$(python3 - "$sha" "$path" <<'PYDEL'
import json,sys
print(json.dumps({"sha":sys.argv[1],"message":"bootstrap: remove legacy "+sys.argv[2],"branch":"main"}))
PYDEL
)"
    curl -fsS -X DELETE -H "Authorization: token $SERVICE_TOKEN" -H 'Content-Type: application/json' \
      --data "$payload" "$API_BASE/repos/$ORG/$repo/contents/$path" >/dev/null || true
}

OBS_PROFILE_JSON="$(cat <<'OBSPROFILE'
{
  "schema_version": 1,
  "id": "observability-client",
  "description": "Installiert die generische Observability-Software. install.sh wird durch Git Deploy gestartet und setzt den Paketplan aus deploy-profile.json um.",
  "package_repositories": [
    {
      "id": "infrastructure-baseline",
      "url": "https://config-manager.local/baseline-repo/",
      "local_path": "/srv/www/baseline-repo",
      "gpg_check": false,
      "refresh": true
    }
  ],
  "packages": [
    {"name": "monit", "state": "present"},
    {"name": "alloy", "state": "present"},
    {"name": "monit-prometheus-exporter", "state": "present"},
    {"name": "client-baseline", "state": "present"}
  ]
}
OBSPROFILE
)"
OBS_PACKAGES_JSON="$(cat <<'OBSPACKAGES'
{
  "schema_version": 1,
  "repository": "infrastructure-baseline",
  "meta_package": "client-baseline",
  "packages": ["monit", "alloy", "monit-prometheus-exporter", "client-baseline"],
  "ownership": {
    "package_management": ["package install/update", "alloy base config", "service activation"],
    "client_baseline": ["host identity", "monit access credential"]
  }
}
OBSPACKAGES
)"
OBS_INSTALL_SH="$(cat <<'OBSINSTALL'
#!/bin/bash
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MANIFEST="$ROOT/deploy-profile.json"
[[ -r "$MANIFEST" ]] || { echo "FEHLER: deploy-profile.json fehlt: $MANIFEST" >&2; exit 2; }
[[ $(id -u) -eq 0 ]] || { echo "FEHLER: install.sh muss als root laufen." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FEHLER: python3 fehlt." >&2; exit 2; }
command -v zypper >/dev/null 2>&1 || { echo "FEHLER: zypper fehlt; derzeit werden SLES/openSUSE Clients unterstuetzt." >&2; exit 2; }

TMP="$(mktemp -d /tmp/observability-client.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$MANIFEST" "$TMP" <<'PYPLAN'
import json,os,sys
manifest,outdir=sys.argv[1:3]
with open(manifest,encoding='utf-8') as f:
    d=json.load(f)
repos=d.get('package_repositories') or []
pkgs=d.get('packages') or []
if not repos:
    raise SystemExit('deploy-profile.json: package_repositories fehlt')
for i,r in enumerate(repos):
    if not isinstance(r,dict) or not r.get('id'):
        raise SystemExit('deploy-profile.json: ungueltiges package_repositories Element')
    vals=[str(r.get('id','')),str(r.get('url','')),str(r.get('local_path','')), '1' if r.get('gpg_check') else '0', '1' if r.get('refresh',True) else '0']
    open(os.path.join(outdir,'repo-%d'%i),'w').write('\n'.join(vals)+'\n')
open(os.path.join(outdir,'repo-count'),'w').write(str(len(repos)))
names=[]
for p in pkgs:
    if not isinstance(p,dict):
        raise SystemExit('deploy-profile.json: ungueltiges packages Element')
    state=str(p.get('state','present'))
    name=str(p.get('name',''))
    if state != 'present':
        raise SystemExit('deploy-profile.json: derzeit ist nur state=present erlaubt: '+name)
    if not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+._-' for c in name):
        raise SystemExit('deploy-profile.json: ungueltiger Paketname: '+name)
    names.append(name)
if not names:
    raise SystemExit('deploy-profile.json: packages fehlt/leer')
open(os.path.join(outdir,'packages'),'w').write('\n'.join(names)+'\n')
PYPLAN

echo "============================================================"
echo " Observability Client Installation"
echo "============================================================"

repo_https_preflight(){
  local url="$1" meta ca curl_rc
  [[ "$url" == https://* ]] || return 0
  meta="${url%/}/repodata/repomd.xml"
  command -v curl >/dev/null 2>&1 || { echo "FEHLER: curl fehlt fuer Repository-Preflight." >&2; return 1; }

  # Enrollment installiert den aktuellen Config-Manager-Trust-Anchor. Vor dem
  # Paket-Deploy wird der Trust Store vorsichtshalber aktualisiert, damit
  # libzypp denselben Zertifikatsstand verwendet wie curl.
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates >/dev/null 2>&1 || true
  elif command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract >/dev/null 2>&1 || true
  fi

  ca=""
  for f in /etc/pki/trust/anchors/infrastructure-config-manager.crt /etc/pki/trust/anchors/teko-config-manager.crt; do
    if [[ -s "$f" ]] && openssl x509 -in "$f" -noout >/dev/null 2>&1; then
      ca="$f"; break
    fi
  done
  echo ">>> Repository-Preflight: $meta"
  repo_host="${url#https://}"; repo_host="${repo_host%%/*}"
  repo_resolved="$(getent ahostsv4 "$repo_host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  echo "    Host: $repo_host -> ${repo_resolved:-nicht aufgeloest}"
  if [[ -n "$ca" ]]; then
    if curl -fsS --connect-timeout 8 --max-time 20 --cacert "$ca" -o /dev/null "$meta"; then
      :
    else
      curl_rc=$?
      echo "FEHLER: Repository-Metadaten sind ueber HTTPS nicht lesbar: $meta" >&2
      echo "        curl rc=$curl_rc · Trust-Anchor: $ca" >&2
      echo "        Pruefe Config-Manager Apache Alias /baseline-repo/, TLS-Trust und Namensaufloesung." >&2
      return "$curl_rc"
    fi
  else
    if curl -fsS --connect-timeout 8 --max-time 20 -o /dev/null "$meta"; then
      :
    else
      curl_rc=$?
      echo "FEHLER: Repository-Metadaten sind ueber HTTPS nicht lesbar: $meta" >&2
      echo "        curl rc=$curl_rc · kein lokaler Config-Manager Trust-Anchor gefunden." >&2
      echo "        Erwartet: /etc/pki/trust/anchors/infrastructure-config-manager.crt" >&2
      echo "        Agent ueber Managed Hosts -> Agent Lifecycle -> Reparieren aktualisieren." >&2
      return "$curl_rc"
    fi
  fi
  echo "[OK] Repository-Metadaten ueber HTTPS erreichbar"
}

REPO_COUNT="$(cat "$TMP/repo-count")"
for ((i=0;i<REPO_COUNT;i++)); do
  mapfile -t R < "$TMP/repo-$i"
  RID="${R[0]}"; RURL="${R[1]}"; RLOCAL="${R[2]}"; RGPG="${R[3]}"; RREFRESH="${R[4]}"
  SOURCE="$RURL"
  if [[ -n "$RLOCAL" && -r "$RLOCAL/repodata/repomd.xml" ]]; then SOURCE="file://$RLOCAL"; fi
  [[ -n "$SOURCE" ]] || { echo "FEHLER: Repository $RID hat weder gueltige URL noch local_path." >&2; exit 3; }
  echo ""; echo ">>> Repository: $RID -> $SOURCE"
  repo_https_preflight "$SOURCE"
  zypper --non-interactive rr "$RID" >/dev/null 2>&1 || true
  if [[ "$RGPG" == "1" ]]; then
    zypper --non-interactive ar -f "$SOURCE" "$RID"
  else
    zypper --non-interactive ar -f -G "$SOURCE" "$RID"
  fi
  if [[ "$RREFRESH" == "1" ]]; then zypper --non-interactive refresh "$RID"; fi
done

mapfile -t PACKAGES < "$TMP/packages"
echo ""; echo ">>> Pakete installieren/aktualisieren: ${PACKAGES[*]}"
zypper --non-interactive install --no-recommends "${PACKAGES[@]}"

echo ""; echo ">>> Paketstatus pruefen"
for pkg in "${PACKAGES[@]}"; do
  rpm -q "$pkg" >/dev/null || { echo "FEHLER: Paket nicht installiert: $pkg" >&2; exit 4; }
  echo "[OK] $pkg: $(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$pkg")"
done

systemctl daemon-reload

# Alloy-Servicekonto ist Teil der Installationslogik. Nicht darauf vertrauen,
# dass ein Vendor-RPM den Account auf jeder Distribution korrekt angelegt hat.
# Vor jedem Runtime-Setup wird der effektive User/Group-Wert aus der Unit gelesen,
# bei Bedarf repariert und hart verifiziert. So kann 217/USER nicht erst im
# Healthcheck sichtbar werden.
ensure_alloy_service_account(){
  command -v alloy >/dev/null 2>&1 || return 0
  local au ag nologin
  au="$(systemctl show -p User --value alloy.service 2>/dev/null || true)"
  ag="$(systemctl show -p Group --value alloy.service 2>/dev/null || true)"
  if [[ -z "$au" ]]; then
    au="$(systemctl cat alloy.service 2>/dev/null | sed -n 's/^[[:space:]]*User[[:space:]]*=[[:space:]]*//p' | tail -n1 | tr -d '\r' || true)"
  fi
  if [[ -z "$ag" ]]; then
    ag="$(systemctl cat alloy.service 2>/dev/null | sed -n 's/^[[:space:]]*Group[[:space:]]*=[[:space:]]*//p' | tail -n1 | tr -d '\r' || true)"
  fi
  [[ -n "$au" ]] || au="alloy"
  [[ -n "$ag" ]] || ag="$au"
  [[ "$au" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { echo "FEHLER: ungueltiger Alloy User: $au" >&2; exit 5; }
  [[ "$ag" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { echo "FEHLER: ungueltige Alloy Group: $ag" >&2; exit 5; }
  getent group "$ag" >/dev/null 2>&1 || { echo "[REPAIR] Alloy-Gruppe $ag wird angelegt"; groupadd --system "$ag"; }
  if ! getent passwd "$au" >/dev/null 2>&1; then
    echo "[REPAIR] Alloy-User $au wird angelegt"
    nologin="$(command -v nologin || true)"; [[ -n "$nologin" ]] || nologin=/sbin/nologin
    useradd --system --gid "$ag" --home-dir /var/lib/alloy --shell "$nologin" --no-create-home "$au"
  fi
  getent passwd "$au" >/dev/null 2>&1 || { echo "FEHLER: Alloy User $au fehlt weiterhin" >&2; exit 5; }
  getent group "$ag" >/dev/null 2>&1 || { echo "FEHLER: Alloy Group $ag fehlt weiterhin" >&2; exit 5; }
  install -d -o "$au" -g "$ag" -m 0750 /var/lib/alloy /var/lib/alloy/data
  chown -R "$au:$ag" /var/lib/alloy
  echo "[OK] Alloy-Servicekonto: $au:$ag"
  systemctl reset-failed alloy.service >/dev/null 2>&1 || true
}

if command -v monit >/dev/null 2>&1; then systemctl enable --now monit.service; fi
ensure_alloy_service_account
if command -v alloy >/dev/null 2>&1; then
  # %%{_libexecdir} ist distributionsabhaengig: auf SUSE kann das /usr/lib
  # statt /usr/libexec sein. Den vom RPM tatsaechlich installierten Konfigurator
  # ermitteln, damit wir nicht still in den unsicheren Restart-Fallback fallen.
  ALLOY_CONFIGURATOR=""
  for candidate in \
    /usr/libexec/client-baseline/configure-observability-client \
    /usr/lib/client-baseline/configure-observability-client; do
    if [[ -x "$candidate" ]]; then ALLOY_CONFIGURATOR="$candidate"; break; fi
  done
  if [[ -z "$ALLOY_CONFIGURATOR" ]] && rpm -q client-baseline >/dev/null 2>&1; then
    ALLOY_CONFIGURATOR="$(rpm -ql client-baseline 2>/dev/null | grep -E '/client-baseline/configure-observability-client$' | head -n1 || true)"
    [[ -x "$ALLOY_CONFIGURATOR" ]] || ALLOY_CONFIGURATOR=""
  fi
  if [[ -n "$ALLOY_CONFIGURATOR" ]]; then
    echo "[INFO] Alloy-Konfigurator: $ALLOY_CONFIGURATOR"
    # Der package-eigene Konfigurator validiert mit den effektiven Alloy-
    # Servicerechten, setzt die Dateirechte, startet den Dienst und prueft
    # mehrere Sekunden den stabilen Zustand.
    "$ALLOY_CONFIGURATOR"
  else
    echo "FEHLER: client-baseline ist installiert, aber configure-observability-client wurde nicht gefunden." >&2
    rpm -ql client-baseline >&2 2>&1 || true
    exit 5
  fi
fi
if rpm -q monit-prometheus-exporter >/dev/null 2>&1; then
  if [[ -s /var/lib/service/config-agent/secrets/monit-status.env ]]; then
    systemctl enable monit-prometheus-exporter.service >/dev/null 2>&1 || true
    systemctl restart monit-prometheus-exporter.service
  else
    echo "[INFO] Monit Exporter installiert, aber noch nicht gestartet: Monit-Credential fehlt."
    echo "       Credential unter Managed Hosts -> Baseline setzen."
  fi
fi

echo ""; echo ">>> Healthcheck"
systemctl is-active --quiet monit.service && echo "[OK] monit.service aktiv" || { echo "FEHLER: monit.service nicht aktiv" >&2; exit 5; }
systemctl is-active --quiet alloy.service && echo "[OK] alloy.service aktiv" || {
  echo "FEHLER: alloy.service nicht aktiv" >&2
  systemctl --no-pager --full status alloy.service >&2 2>&1 || true
  journalctl -u alloy.service -n 50 --no-pager >&2 2>&1 || true
  exit 5
}
if [[ -s /var/lib/service/config-agent/secrets/monit-status.env ]]; then
  systemctl is-active --quiet monit-prometheus-exporter.service && echo "[OK] monit-prometheus-exporter.service aktiv" || { echo "FEHLER: monit-prometheus-exporter.service nicht aktiv" >&2; exit 5; }
fi

echo ""; echo "Observability Client Installation erfolgreich."
OBSINSTALL
)"
ensure_repo_file "$OBS_REPO" "README.md" $'# Observability Client\n\nSoftware-Deployment fuer verwaltete Linux-Hosts.\n\nPakete:\n- monit\n- alloy\n- monit-prometheus-exporter\n- client-baseline\n\n`deploy-profile.json` definiert Repository und Paket-Sollzustand. **`install.sh` ist der ausfuehrende Installer** und wird von Git Deploy nach Aktivierung des Releases automatisch als `post_deploy` gestartet. Die RPMs selbst liegen im internen RPM-Repository. Die Client Baseline verwaltet danach nur Host-Identitaet und den Monit-Zugang.\n'
ensure_repo_file "$OBS_REPO" "deploy-profile.json" "$OBS_PROFILE_JSON"
ensure_repo_file "$OBS_REPO" "packages.json" "$OBS_PACKAGES_JSON"
ensure_repo_file "$OBS_REPO" "install.sh" "$OBS_INSTALL_SH"
ensure_repo_file "$REPO" "configs/observability/alloy/README.md" $'# Grafana Alloy\n\nDie generische Alloy-Konfiguration gehoert zum RPM `client-baseline` und wird ueber das Deploy-Profil `observability-client` installiert. Zusaetzliche workload-spezifische Quellen (Postfix, Rspamd, Apache usw.) werden hier bzw. unter den jeweiligen Dienstkonfigurationen versioniert.\n'
ensure_repo_file "$REPO" "TEKO-STRUCTURE.md" $'# TEKO config-deploy\n\nDieses Repository enthaelt workload-spezifische Konfigurationen und Rollenprofile. Die generische Observability-Software liegt bewusst im separaten Repository `teko/observability-client`.\n\nGrundsatz:\n- Client Baseline: Host-Identitaet + Monit-Zugang\n- observability-client: Paketplan fuer Monit, Alloy, Exporter und client-baseline\n- config-deploy: workload-spezifische Konfigurationen fuer Postfix, Rspamd, Apache usw.\n'

# Legacy-Skriptdeployment im alten config-deploy Repository entfernen.
delete_repo_file "$REPO" "deploy/observability-client/install.sh"
delete_repo_file "$REPO" "deploy/observability-client/verify.sh"
delete_repo_file "$REPO" "deploy/observability-client/README.md"
delete_repo_file "$REPO" "manifests/observability-client.json"

echo
echo "======================================================================"
echo " Forgejo Repository-Struktur bereit"
echo "======================================================================"
echo "Organisation : $ORG"
echo "Repository   : $ORG/$REPO"
echo "Observability: $ORG/$OBS_REPO"
echo "URL          : https://${FORGEJO_FQDN}/$ORG/$REPO"
echo "Clone        : https://${FORGEJO_FQDN}/$ORG/$REPO.git"
echo "Team         : $TEAM ($TEAM_PERMISSION)"
echo "Service-User : $SERVICE_USER"
echo "Token-Datei  : $TOKEN_FILE"
echo "======================================================================"
