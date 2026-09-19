#!/bin/bash
set -euo pipefail
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

AGENT_ENV="${TEKO_AGENT_ENV:-/opt/service/env/config-agent.env}"
HANDOFF="${TEKO_AGENT_TOKEN_HANDOFF:-/opt/service/env/.config-agent-token}"
MANAGER_ENV="${TEKO_MANAGER_ENV:-/srv/www/config-manager-standalone/standalone/data/config-manager.env}"
MANAGER_REGISTRY="${TEKO_MANAGER_REGISTRY:-/opt/service/config-manager/servers.json}"
MANAGER_TOKEN_DIR="${TEKO_MANAGER_TOKEN_DIR:-/opt/service/config-manager/tokens}"
MANAGER_LOCAL_SERVER_NAME="${TEKO_MANAGER_LOCAL_SERVER_NAME:-${SERVER_SHORTNAME:-teko}}"
MANAGER_LOCAL_TOKEN_FILE="${TEKO_MANAGER_LOCAL_TOKEN_FILE:-$MANAGER_TOKEN_DIR/${MANAGER_LOCAL_SERVER_NAME}.token}"
if [[ -n "${TEKO_MANAGER_WEB_GROUP:-}" ]]; then
  MANAGER_WEB_GROUP="$TEKO_MANAGER_WEB_GROUP"
elif getent group www >/dev/null 2>&1; then
  MANAGER_WEB_GROUP="www"
elif getent group www-data >/dev/null 2>&1; then
  MANAGER_WEB_GROUP="www-data"
else
  MANAGER_WEB_GROUP="$(id -gn)"
fi
MANAGER_CONFIG_PHP="${TEKO_MANAGER_CONFIG_PHP:-/srv/www/config-manager-standalone/config/config.php}"
MANAGER_RUNTIME_PHP="${TEKO_MANAGER_RUNTIME_PHP:-/srv/www/config-manager-standalone/lib/config_manager_runtime.php}"
FORGEJO_TOKEN_FILE="${TEKO_FORGEJO_TOKEN_FILE:-/opt/service/env/forgejo-api.token}"
AGENT_URL="${TEKO_AGENT_URL:-https://127.0.0.1:5008}"
FORGEJO_API="${TEKO_FORGEJO_API:-http://127.0.0.1:3000/api/v1}"
FORGEJO_ORG="${FORGEJO_ORG:-teko}"
FORGEJO_REPO="${FORGEJO_REPO:-config-deploy}"
NO_RESTART="${TEKO_TOKEN_SYNC_NO_RESTART:-0}"
NO_LIVE_TEST="${TEKO_TOKEN_SYNC_NO_LIVE_TEST:-0}"

log(){ printf '\n>>> %s\n' "$*"; }
die(){ echo "FEHLER: $*" >&2; exit 1; }
fp(){ printf '%s' "$1" | sha256sum | awk '{print substr($1,1,12)}'; }
read_kv(){ local f="$1" k="$2"; sed -n "s/^${k}=//p" "$f" | tail -n1 | tr -d '\r\n'; }

[[ $EUID -eq 0 ]] || die "Bitte als root/sudo ausfuehren."
[[ -f "$AGENT_ENV" && ! -L "$AGENT_ENV" ]] || die "Config-Agent ENV fehlt oder ist Symlink: $AGENT_ENV"
[[ -f "$MANAGER_ENV" && ! -L "$MANAGER_ENV" ]] || die "aktive Config-Manager ENV fehlt oder ist Symlink: $MANAGER_ENV"

log "Config-Agent API-Token als autoritative Quelle lesen"
AGENT_TOKEN="$(read_kv "$AGENT_ENV" CONFIG_AGENT_API_TOKEN)"
[[ ${#AGENT_TOKEN} -ge 32 ]] || die "CONFIG_AGENT_API_TOKEN fehlt/ist zu kurz in $AGENT_ENV"
case "$AGENT_TOKEN" in *CHANGE_ME*|*change_me*|*example*|*test*) die "CONFIG_AGENT_API_TOKEN ist ein Platzhalter";; esac
AGENT_FP="$(fp "$AGENT_TOKEN")"
echo "Agent Token Fingerprint : $AGENT_FP"

log "Root-only Token-Handoff synchronisieren"
install -d -o root -g root -m 0700 "$(dirname "$HANDOFF")"
tmp="$(mktemp "${HANDOFF}.tmp.XXXXXX")"
printf '%s' "$AGENT_TOKEN" > "$tmp"
chown root:root "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$HANDOFF"
echo "Handoff                  : $HANDOFF"

log "aktive Config-Manager ENV atomar synchronisieren"
mtmp="$(mktemp "${MANAGER_ENV}.tmp.XXXXXX")"
awk '!/^CONFIG_MANAGER_API_TOKEN=/ && !/^CONFIG_MANAGER_APITOKEN=/' "$MANAGER_ENV" > "$mtmp"
printf 'CONFIG_MANAGER_API_TOKEN=%s\n' "$AGENT_TOKEN" >> "$mtmp"
if getent passwd wwwrun >/dev/null 2>&1 && getent group www >/dev/null 2>&1; then
  chown wwwrun:www "$mtmp"
else
  chown --reference="$MANAGER_ENV" "$mtmp" 2>/dev/null || chown root:root "$mtmp"
fi
chmod 0640 "$mtmp"
mv -f "$mtmp" "$MANAGER_ENV"
MANAGER_TOKEN="$(read_kv "$MANAGER_ENV" CONFIG_MANAGER_API_TOKEN)"
MANAGER_FP="$(fp "$MANAGER_TOKEN")"
echo "Manager Token Fingerprint: $MANAGER_FP"
[[ "$AGENT_TOKEN" == "$MANAGER_TOKEN" ]] || die "Manager-/Agent-Token sind nach Sync nicht identisch"

log "dedizierten Runtime-Token fuer lokalen Config Manager bereitstellen"
getent group "$MANAGER_WEB_GROUP" >/dev/null 2>&1 || die "Config-Manager Web-Gruppe fehlt: $MANAGER_WEB_GROUP"
install -d -o root -g "$MANAGER_WEB_GROUP" -m 0750 "$(dirname "$MANAGER_LOCAL_TOKEN_FILE")"
ltmp="$(mktemp "${MANAGER_LOCAL_TOKEN_FILE}.tmp.XXXXXX")"
printf '%s' "$AGENT_TOKEN" > "$ltmp"
chown root:"$MANAGER_WEB_GROUP" "$ltmp"
chmod 0640 "$ltmp"
mv -f "$ltmp" "$MANAGER_LOCAL_TOKEN_FILE"
echo "Local Runtime Token       : $MANAGER_LOCAL_TOKEN_FILE ($(fp "$AGENT_TOKEN"))"

log "lokalen Fleet-Registry-Eintrag auf dedizierten Runtime-Token normalisieren"
if [[ -f "$MANAGER_REGISTRY" && ! -L "$MANAGER_REGISTRY" ]]; then
  python3 - "$MANAGER_REGISTRY" "$AGENT_URL" "$MANAGER_LOCAL_TOKEN_FILE" <<'PY_REGISTRY'
import json, os, sys, tempfile
path, local_url, local_token_file = sys.argv[1:]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
servers = data.get('servers')
if not isinstance(servers, list):
    raise SystemExit('Server-Registry enthaelt keine servers-Liste')
changed = False
for srv in servers:
    if not isinstance(srv, dict):
        continue
    url = str(srv.get('url', '')).rstrip('/')
    name = str(srv.get('name', ''))
    if url == local_url.rstrip('/') or (name == 'teko' and url in {'https://127.0.0.1:5008','http://127.0.0.1:5008'}):
        # Fuer den lokalen Agenten ist eine dedizierte Runtime-Token-Datei autoritativ.
        # Dadurch gibt es keine Mehrdeutigkeit zwischen ENV und Fleet-Registry.
        if 'token' in srv:
            srv.pop('token', None); changed = True
        if srv.get('token_file') != local_token_file:
            srv['token_file'] = local_token_file; changed = True
if changed:
    d = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(prefix='.servers.json.', dir=d, text=True)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write('\n')
            f.flush(); os.fsync(f.fileno())
        st = os.stat(path)
        os.chmod(tmp, st.st_mode & 0o777)
        try: os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError: pass
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
print('lokaler Registry-Token auf dedizierte Runtime-Datei gesetzt' if changed else 'lokaler Registry-Token bereits korrekt')
PY_REGISTRY
else
  echo "WARNUNG: Fleet-Registry nicht gefunden: $MANAGER_REGISTRY" >&2
fi

log "effektiven Config-Manager Runtime-Token pruefen"
if command -v php >/dev/null 2>&1 && [[ -f "$MANAGER_CONFIG_PHP" && -f "$MANAGER_RUNTIME_PHP" ]]; then
  runtime_fp="$(CONFIG_MANAGER_ENV_FILE="$MANAGER_ENV" php -r '
    require_once $argv[2];
    $servers=cm_load_config_manager_servers($argv[1]);
    $want=rtrim($argv[3], "/"); $tok="";
    foreach($servers as $s){ if(rtrim((string)($s["url"]??""), "/")===$want){$tok=(string)($s["token"]??""); break;} }
    if($tok===""){fwrite(STDERR,"lokaler Runtime-Server/Token fehlt\n"); exit(3);}
    echo substr(hash("sha256",$tok),0,12);
  ' "$MANAGER_CONFIG_PHP" "$MANAGER_RUNTIME_PHP" "$AGENT_URL")" || die "Config-Manager Runtime konnte nicht validiert werden"
  echo "Runtime Token Fingerprint: $runtime_fp"
  [[ "$runtime_fp" == "$AGENT_FP" ]] || die "Config-Manager verwendet zur Laufzeit weiterhin einen anderen Token (Runtime $runtime_fp / Agent $AGENT_FP)"
else
  echo "WARNUNG: PHP Runtime-Selbsttest nicht moeglich; php/config runtime fehlt." >&2
fi

# Verhindert versehentliche Vermischung der beiden Credential-Domaenen.
if [[ -s "$FORGEJO_TOKEN_FILE" && ! -L "$FORGEJO_TOKEN_FILE" ]]; then
  FORGEJO_TOKEN="$(tr -d '\r\n' < "$FORGEJO_TOKEN_FILE")"
  [[ -n "$FORGEJO_TOKEN" ]] || die "Forgejo Token-Datei ist leer: $FORGEJO_TOKEN_FILE"
  [[ "$FORGEJO_TOKEN" != "$AGENT_TOKEN" ]] || die "Forgejo-Token darf NICHT identisch zum Config-Agent API-Token sein"
  echo "Forgejo Token Fingerprint : $(fp "$FORGEJO_TOKEN") (separates Credential)"
fi

if [[ "$NO_RESTART" != "1" ]]; then
  log "Config-Agent neu starten, damit Datei und Laufzeit garantiert identisch sind"
  systemctl restart config-agent.service
  systemctl is-active --quiet config-agent.service || die "config-agent.service ist nach Restart nicht aktiv"
fi

wait_for_agent() {
  local max_wait="${TEKO_AGENT_READY_TIMEOUT:-30}"
  local i code
  log "Auf Config-Agent Readiness an ${AGENT_URL} warten (max. ${max_wait}s)"
  for ((i=1; i<=max_wait; i++)); do
    if ! systemctl is-active --quiet config-agent.service; then
      echo "FEHLER: config-agent.service ist waehrend des Starts beendet worden." >&2
      systemctl --no-pager --full status config-agent.service >&2 || true
      journalctl -u config-agent.service -n 80 --no-pager >&2 || true
      return 1
    fi
    # Jeder HTTP-Code beweist, dass TLS/HTTP auf Port 5008 bereits antwortet.
    # Auth wird erst im nachfolgenden echten API-Test bewertet.
    code="$(curl -ksS --connect-timeout 1 --max-time 2 -o /dev/null -w '%{http_code}' "$AGENT_URL/" 2>/dev/null || true)"
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
      echo "Config-Agent ist bereit nach ${i}s (HTTP ${code})."
      return 0
    fi
    sleep 1
  done
  echo "FEHLER: Config-Agent lauscht nach ${max_wait}s nicht auf ${AGENT_URL}." >&2
  systemctl --no-pager --full status config-agent.service >&2 || true
  journalctl -u config-agent.service -n 80 --no-pager >&2 || true
  if command -v ss >/dev/null 2>&1; then
    echo "--- Listener auf Port 5008 ---" >&2
    ss -ltnp 2>/dev/null | grep -E '(:5008\b|State)' >&2 || true
  fi
  return 1
}

if [[ "$NO_LIVE_TEST" != "1" ]]; then
  wait_for_agent || die "Config-Agent wurde nicht rechtzeitig bereit"
  log "Live-Selbsttest Config Manager -> Config-Agent"
  out="$(mktemp)"
  code="$(curl -ksS --connect-timeout 5 --max-time 20 -o "$out" -w '%{http_code}' \
      -H "X-API-Token: $AGENT_TOKEN" "$AGENT_URL/git_deployments" || true)"
  body="$(head -c 500 "$out" 2>/dev/null || true)"; rm -f "$out"
  [[ "$code" == "200" ]] || die "Config-Agent Auth-Selbsttest fehlgeschlagen: HTTP $code ${body:+Antwort: $body}"
  echo "Config-Agent /git_deployments: HTTP 200 OK"

  if [[ -s "$FORGEJO_TOKEN_FILE" && ! -L "$FORGEJO_TOKEN_FILE" ]]; then
    log "Live-Selbsttest Config-Agent/TEKO -> Forgejo"
    FORGEJO_TOKEN="$(tr -d '\r\n' < "$FORGEJO_TOKEN_FILE")"
    fcode="$(curl -sS --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' \
       -H "Authorization: token $FORGEJO_TOKEN" "$FORGEJO_API/user" || true)"
    [[ "$fcode" == "200" ]] || die "Forgejo Service-Token ungueltig: HTTP $fcode ($FORGEJO_API/user)"
    rcode="$(curl -sS --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' \
       -H "Authorization: token $FORGEJO_TOKEN" "$FORGEJO_API/repos/$FORGEJO_ORG/$FORGEJO_REPO" || true)"
    [[ "$rcode" == "200" ]] || die "Forgejo Repository-Zugriff fehlgeschlagen: HTTP $rcode ($FORGEJO_ORG/$FORGEJO_REPO)"
    echo "Forgejo API /user             : HTTP 200 OK"
    echo "Forgejo Repo $FORGEJO_ORG/$FORGEJO_REPO : HTTP 200 OK"
  else
    echo "WARNUNG: Forgejo Service-Token fehlt; Git Deploy/Upload bleibt deaktiviert." >&2
  fi
fi

log "Authentifizierung konsistent"
echo "Agent ENV   : $AGENT_ENV"
echo "Manager ENV : $MANAGER_ENV"
echo "Handoff     : $HANDOFF"
echo "RuntimeToken: $MANAGER_LOCAL_TOKEN_FILE"
echo "Forgejo     : $FORGEJO_TOKEN_FILE"
echo "Agent/Manager Fingerprint: $AGENT_FP"
