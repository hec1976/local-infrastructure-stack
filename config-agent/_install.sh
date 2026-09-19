#!/usr/bin/env bash
# Generic Systemd Service Installer
# Version: 1.3.0
#
# Installationsmodell:
#   /opt/.../service/<unit>.example       = Paket-Template (regulaere Datei)
#   /etc/systemd/system/<unit>            = installierte Unit (regulaere Datei)
#   /opt/.../service/<unit>               = Symlink auf die installierte Unit
#
# Damit liest systemd beim Boot ausschliesslich aus /etc und haengt nicht von
# der Verfuegbarkeit eines /opt-Dateisystems ab.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="$SCRIPT_DIR/service-install.ini"
ACTION="install"
DRY_RUN=0
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./_install.sh [options]

Standard ohne Optionen:
  - Verzeichnisse, Dateien und Rechte aus service-install.ini anwenden
  - Unit-Template als regulaere Datei unter /etc/systemd/system installieren
  - Rueckwaerts-Symlink im service/-Ordner erstellen
  - daemon-reload ausfuehren
  - Start/Enable/Restart gemaess [service] in der INI ausfuehren

Optionen:
  --check          Nur INI, Pfade, Benutzer, Gruppen und Unit pruefen
  --start          Nach Installation starten; aktiver Dienst wird neu gestartet
  --restart        Nach Installation neu starten
  --enable         Aktivieren und starten
  --no-start       Start/Enable/Restart aus der INI fuer diesen Lauf unterdruecken
  --dry-run        Aenderungen nur anzeigen
  --config FILE    Andere INI-Datei verwenden
  -v, --verbose    Zusaetzliche Ausgaben
  -h, --help       Hilfe
USAGE
}
log()  { printf '[i ] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[!!] %s\n' "$*" >&2; }
die()  { printf '[ERR] %s\n' "$*" >&2; exit 1; }
verb() { ((VERBOSE)) && printf '[..] %s\n' "$*" || true; }

run() {
  if ((DRY_RUN)); then
    printf '[DRY]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

CLI_START_MODE=''
while (($#)); do
  case "$1" in
    --config) shift; (($#)) || die '--config benoetigt eine Datei'; CONFIG_FILE="$1" ;;
    --check) ACTION="check" ;;
    --start) CLI_START_MODE='start' ;;
    --restart) CLI_START_MODE='restart' ;;
    --enable) CLI_START_MODE='enable' ;;
    --no-start) CLI_START_MODE='none' ;;
    --dry-run) DRY_RUN=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    --internal-remove) ACTION='remove-unit' ;;
    *) die "Unbekannte Option: $1" ;;
  esac
  shift
done

[[ -f "$CONFIG_FILE" ]] || die "INI-Datei fehlt: $CONFIG_FILE"
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd -P)/$(basename "$CONFIG_FILE")"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"

# Sicherer Minimal-INI-Parser. Kein source/eval.
declare -A CFG=()
declare -a SECTIONS=()
declare -A SECTION_SEEN=()

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_ini() {
  local section='' line key value lineno=0 stripped index
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((lineno+=1))
    line="${line%$'\r'}"
    [[ "$line" != *$'\t'* ]] || die "$CONFIG_FILE:$lineno: Tabs sind nicht erlaubt"
    stripped="$(trim "$line")"
    [[ -z "$stripped" || "$stripped" == \#* || "$stripped" == \;* ]] && continue

    if [[ "$stripped" =~ ^\[([A-Za-z0-9_.:-]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      if [[ -z "${SECTION_SEEN[$section]+x}" ]]; then
        SECTIONS+=("$section")
        SECTION_SEEN["$section"]=1
      fi
      continue
    fi

    [[ -n "$section" ]] || die "$CONFIG_FILE:$lineno: Schluessel ausserhalb einer Section"
    [[ "$stripped" == *=* ]] || die "$CONFIG_FILE:$lineno: Erwartet wird key = value"
    key="$(trim "${stripped%%=*}")"
    value="$(trim "${stripped#*=}")"
    [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$CONFIG_FILE:$lineno: Ungueltiger Schluessel: $key"
    [[ "$value" =~ ^\"(.*)\"$ ]] && value="${BASH_REMATCH[1]}"
    [[ "$value" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
    index="$section.$key"
    [[ -z "${CFG[$index]+x}" ]] || die "$CONFIG_FILE:$lineno: Doppelter Schluessel: [$section] $key"
    CFG["$index"]="$value"
  done < "$CONFIG_FILE"
}

cfg_raw() {
  local section="$1" key="$2" default="${3-}"
  if [[ -n "${CFG[$section.$key]+x}" ]]; then printf '%s' "${CFG[$section.$key]}"; else printf '%s' "$default"; fi
}

bool_value() {
  case "${1,,}" in
    1|yes|true|on) printf '1' ;;
    0|no|false|off|'') printf '0' ;;
    *) die "Ungueltiger Bool-Wert: $1" ;;
  esac
}

validate_mode() {
  [[ "$1" =~ ^0?[0-7]{3,4}$ ]] || die "Ungueltiger Modus: $1"
}

validate_abs_path() {
  local p="$1" label="$2"
  [[ "$p" == /* && "$p" != / ]] || die "$label muss absolut sein und darf nicht / sein: $p"
  [[ "$p" != *$'\n'* && "$p" != *$'\r'* ]] || die "$label enthaelt Steuerzeichen"
  [[ "/$p/" != *'/../'* && "/$p/" != *'/./'* ]] || die "$label enthaelt . oder ..: $p"
}

is_within() {
  local child="$1" parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

parse_ini
APP_DIR="$(cfg_raw application app_dir '')"
[[ -n "$APP_DIR" ]] || die '[application] app_dir fehlt'
validate_abs_path "$APP_DIR" 'app_dir'
APP_DIR="${APP_DIR%/}"
PACKAGE_DIR="$CONFIG_DIR"
SERVICE_ID="$(cfg_raw application service_id "$(basename "$APP_DIR")")"
UNIT="$(cfg_raw service unit '')"
[[ "$UNIT" =~ ^[A-Za-z0-9_.@:-]+\.service$ ]] || die "Ungueltige oder fehlende Unit: $UNIT"

expand_value() {
  local v="$1"
  v="${v//\$\{APP_DIR\}/$APP_DIR}"
  v="${v//\$\{PACKAGE_DIR\}/$PACKAGE_DIR}"
  v="${v//\$\{CONFIG_DIR\}/$CONFIG_DIR}"
  v="${v//\$\{UNIT\}/$UNIT}"
  v="${v//\$\{SERVICE_ID\}/$SERVICE_ID}"
  [[ ! "$v" =~ \$\{[A-Za-z_][A-Za-z0-9_]*\} ]] || die "Unbekannter Platzhalter in: $1"
  printf '%s' "$v"
}

cfg() { expand_value "$(cfg_raw "$1" "$2" "${3-}")"; }

SYSTEMD_DIR="$(cfg service systemd_dir '/etc/systemd/system')"
validate_abs_path "$SYSTEMD_DIR" 'systemd_dir'
SYSTEMD_DIR="${SYSTEMD_DIR%/}"
UNIT_TEMPLATE="$(cfg service unit_template "service/$UNIT.example")"
[[ "$UNIT_TEMPLATE" == /* ]] || UNIT_TEMPLATE="$APP_DIR/$UNIT_TEMPLATE"
UNIT_INSTALL_PATH="$(cfg service unit_install_path "$SYSTEMD_DIR/$UNIT")"
APP_UNIT_LINK="$(cfg service app_symlink_path "service/$UNIT")"
[[ "$APP_UNIT_LINK" == /* ]] || APP_UNIT_LINK="$APP_DIR/$APP_UNIT_LINK"
CREATE_APP_LINK="$(bool_value "$(cfg service create_app_symlink 'true')")"
VERIFY_UNIT="$(bool_value "$(cfg service verify_unit 'true')")"
BACKUP_EXISTING="$(bool_value "$(cfg service backup_existing_unit 'true')")"
REQUIRE_TEMPLATE_INSIDE_APP="$(bool_value "$(cfg service require_template_inside_app 'true')")"
UNIT_MODE="$(cfg service unit_mode '0644')"
INI_ENABLE="$(bool_value "$(cfg service enable 'false')")"
INI_START="$(bool_value "$(cfg service start 'false')")"
INI_RESTART_IF_ACTIVE="$(bool_value "$(cfg service restart_if_active 'true')")"
validate_abs_path "$UNIT_TEMPLATE" 'unit_template'
validate_abs_path "$UNIT_INSTALL_PATH" 'unit_install_path'
validate_abs_path "$APP_UNIT_LINK" 'app_symlink_path'
validate_mode "$UNIT_MODE"
[[ "$(dirname "$UNIT_INSTALL_PATH")" == "$SYSTEMD_DIR" ]] || die 'unit_install_path muss direkt unter systemd_dir liegen'
[[ "$(basename "$UNIT_INSTALL_PATH")" == "$UNIT" ]] || die 'unit_install_path muss mit unit uebereinstimmen'
if ((REQUIRE_TEMPLATE_INSIDE_APP)) && ! is_within "$UNIT_TEMPLATE" "$APP_DIR"; then
  die "unit_template liegt nicht unter app_dir: $UNIT_TEMPLATE"
fi
[[ "$APP_UNIT_LINK" != "$UNIT_TEMPLATE" ]] || die 'app_symlink_path und unit_template duerfen nicht identisch sein'
[[ "$APP_UNIT_LINK" != "$UNIT_INSTALL_PATH" ]] || die 'app_symlink_path und unit_install_path duerfen nicht identisch sein'

require_user_group() {
  getent passwd "$1" >/dev/null || die "Benutzer fehlt: $1"
  getent group "$2" >/dev/null || die "Gruppe fehlt: $2"
}

check_no_symlink_components() {
  local target="$1" allow_final="${2:-0}" cur='/' part i=0 last
  IFS='/' read -r -a parts <<< "${target#/}"
  last=$((${#parts[@]} - 1))
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    cur="${cur%/}/$part"
    if [[ -L "$cur" ]]; then
      if ((allow_final)) && ((i == last)); then :; else die "Symlink im verwalteten Pfad verboten: $cur"; fi
    fi
    ((i+=1))
  done
}

apply_directory() {
  local section="$1" name="${section#directory:}" p owner group mode create required apply_existing allow_symlink
  p="$(cfg "$section" path '')"; [[ -n "$p" ]] || die "[$section] path fehlt"
  validate_abs_path "$p" "[$section] path"
  owner="$(cfg "$section" owner 'root')"; group="$(cfg "$section" group 'root')"; mode="$(cfg "$section" mode '0750')"
  create="$(bool_value "$(cfg "$section" create 'true')")"; required="$(bool_value "$(cfg "$section" required 'true')")"
  apply_existing="$(bool_value "$(cfg "$section" apply_existing 'true')")"; allow_symlink="$(bool_value "$(cfg "$section" allow_symlink 'false')")"
  validate_mode "$mode"; require_user_group "$owner" "$group"
  [[ ! -L "$p" || $allow_symlink -eq 1 ]] || die "[$section] Verzeichnis ist ein Symlink: $p"
  [[ ! -e "$p" || -d "$p" ]] || die "[$section] ist kein Verzeichnis: $p"
  if [[ ! -d "$p" ]]; then
    if ((create)); then run install -d -m "$mode" -o "$owner" -g "$group" "$p"; ok "Verzeichnis erstellt: $name -> $p ($owner:$group $mode)"
    elif ((required)); then die "[$section] erforderliches Verzeichnis fehlt: $p"
    else verb "Optionales Verzeichnis fehlt: $p"; fi
  elif ((apply_existing)); then
    ((allow_symlink)) || check_no_symlink_components "$p" 0
    run chown "$owner:$group" "$p"; run chmod "$mode" "$p"; ok "Verzeichnis geprueft: $name -> $p ($owner:$group $mode)"
  else ok "Verzeichnis vorhanden, Rechte unveraendert: $name -> $p"; fi
}

apply_file() {
  local section="$1" name="${section#file:}" p owner group mode required allow_symlink apply_existing create_if_missing template
  p="$(cfg "$section" path '')"; [[ -n "$p" ]] || die "[$section] path fehlt"
  validate_abs_path "$p" "[$section] path"
  owner="$(cfg "$section" owner 'root')"; group="$(cfg "$section" group 'root')"; mode="$(cfg "$section" mode '0640')"
  required="$(bool_value "$(cfg "$section" required 'true')")"; allow_symlink="$(bool_value "$(cfg "$section" allow_symlink 'false')")"
  apply_existing="$(bool_value "$(cfg "$section" apply_existing 'true')")"; create_if_missing="$(bool_value "$(cfg "$section" create_if_missing 'false')")"
  template="$(cfg "$section" template '')"
  validate_mode "$mode"; require_user_group "$owner" "$group"
  [[ ! -L "$p" || $allow_symlink -eq 1 ]] || die "[$section] Datei ist ein Symlink: $p"
  [[ ! -e "$p" || -f "$p" ]] || die "[$section] ist keine regulaere Datei: $p"
  if [[ ! -f "$p" ]]; then
    if ((create_if_missing)); then
      [[ -n "$template" ]] || die "[$section] template fehlt"
      [[ "$template" == /* ]] || template="$APP_DIR/$template"
      [[ -f "$template" && ! -L "$template" ]] || die "[$section] Template fehlt/ist unsicher: $template"
      run install -D -m "$mode" -o "$owner" -g "$group" "$template" "$p"; ok "Datei aus Template erstellt: $name -> $p"
    elif ((required)); then die "[$section] erforderliche Datei fehlt: $p"
    else verb "Optionale Datei fehlt: $p"; fi
  elif ((apply_existing)); then
    run chown "$owner:$group" "$p"; run chmod "$mode" "$p"; ok "Datei geprueft: $name -> $p ($owner:$group $mode)"
  else ok "Datei vorhanden, Rechte unveraendert: $name -> $p"; fi
}

run_hook() {
  local hook_name="$1" section="hook:$1" enabled p cwd required
  [[ -n "${SECTION_SEEN[$section]+x}" ]] || return 0
  enabled="$(bool_value "$(cfg "$section" enabled 'true')")"; ((enabled)) || return 0
  p="$(cfg "$section" path '')"; [[ -n "$p" ]] || die "[$section] path fehlt"
  [[ "$p" == /* ]] || p="$APP_DIR/$p"
  cwd="$(cfg "$section" cwd "$APP_DIR")"; [[ "$cwd" == /* ]] || cwd="$APP_DIR/$cwd"
  required="$(bool_value "$(cfg "$section" required 'true')")"
  if [[ ! -f "$p" || ! -x "$p" ]]; then ((required)) && die "[$section] Hook fehlt/nicht ausfuehrbar: $p"; warn "Optionaler Hook fehlt: $p"; return 0; fi
  is_within "$p" "$APP_DIR" || die "[$section] Hook muss unter app_dir liegen: $p"
  [[ -d "$cwd" ]] || die "[$section] cwd fehlt: $cwd"
  if ((DRY_RUN)); then printf '[DRY] (cd %q && %q)\n' "$cwd" "$p"; else
    (cd "$cwd"; export MMBB_APP_DIR="$APP_DIR" MMBB_UNIT="$UNIT" MMBB_SERVICE_ID="$SERVICE_ID" MMBB_INSTALL_CONFIG="$CONFIG_FILE"; "$p")
  fi
  ok "Hook ausgefuehrt: $hook_name"
}

validate_all() {
  [[ -d "$APP_DIR" ]] || die "app_dir fehlt: $APP_DIR"
  [[ -f "$UNIT_TEMPLATE" && ! -L "$UNIT_TEMPLATE" ]] || die "Unit-Template fehlt oder ist ein Symlink: $UNIT_TEMPLATE"
  command -v getent >/dev/null || die 'Befehl fehlt: getent'
  command -v install >/dev/null || die 'Befehl fehlt: install'
  command -v cmp >/dev/null || die 'Befehl fehlt: cmp'
  command -v mktemp >/dev/null || die 'Befehl fehlt: mktemp'
  command -v systemctl >/dev/null || die 'Befehl fehlt: systemctl'
  if ((VERIFY_UNIT)) && command -v systemd-analyze >/dev/null; then
    if ((DRY_RUN)); then
      printf '[DRY] systemd-analyze verify %q (ueber temporaere .service-Datei)\n' "$UNIT_TEMPLATE"
    else
      local verify_tmp
      verify_tmp="$(mktemp "/tmp/${UNIT}.verify.XXXXXX.service")"
      if ! install -m 0644 "$UNIT_TEMPLATE" "$verify_tmp"; then
        rm -f -- "$verify_tmp"
        die "Temporaere Unit-Pruefdatei konnte nicht erstellt werden"
      fi
      if ! systemd-analyze verify "$verify_tmp" >/dev/null; then
        rm -f -- "$verify_tmp"
        die "systemd-analyze verify fehlgeschlagen: $UNIT_TEMPLATE"
      fi
      rm -f -- "$verify_tmp"
    fi
    ok "Unit-Template geprueft: $UNIT_TEMPLATE"
  else ok "Unit-Template vorhanden: $UNIT_TEMPLATE"; fi
  local section p o g m
  for section in "${SECTIONS[@]}"; do
    case "$section" in
      directory:*) p="$(cfg "$section" path '')"; [[ -n "$p" ]] || die "[$section] path fehlt"; validate_abs_path "$p" "[$section] path"; o="$(cfg "$section" owner root)"; g="$(cfg "$section" group root)"; m="$(cfg "$section" mode 0750)"; require_user_group "$o" "$g"; validate_mode "$m" ;;
      file:*) p="$(cfg "$section" path '')"; [[ -n "$p" ]] || die "[$section] path fehlt"; validate_abs_path "$p" "[$section] path"; o="$(cfg "$section" owner root)"; g="$(cfg "$section" group root)"; m="$(cfg "$section" mode 0640)"; require_user_group "$o" "$g"; validate_mode "$m" ;;
      hook:*|analysis|application|service) : ;;
      *) die "Unbekannte INI-Section: [$section]" ;;
    esac
  done
  ok "INI geprueft: $CONFIG_FILE"
}

backup_path() {
  local p="$1" label="$2" backup
  [[ -e "$p" || -L "$p" ]] || return 0
  backup="${p}.pre-install.$(date +%Y%m%d_%H%M%S).$$"
  run mv "$p" "$backup"
  warn "$label gesichert: $backup"
}

install_unit_file() {
  run install -d -m 0755 -o root -g root "$SYSTEMD_DIR"
  if [[ -e "$UNIT_INSTALL_PATH" || -L "$UNIT_INSTALL_PATH" ]]; then
    if [[ -f "$UNIT_INSTALL_PATH" && ! -L "$UNIT_INSTALL_PATH" ]] && cmp -s "$UNIT_TEMPLATE" "$UNIT_INSTALL_PATH"; then
      run chown root:root "$UNIT_INSTALL_PATH"; run chmod "$UNIT_MODE" "$UNIT_INSTALL_PATH"
      ok "Installierte Unit ist aktuell: $UNIT_INSTALL_PATH"
    else
      if ((BACKUP_EXISTING)); then backup_path "$UNIT_INSTALL_PATH" 'Vorhandene Unit'; else run rm -f "$UNIT_INSTALL_PATH"; fi
      atomic_install_unit
    fi
  else
    atomic_install_unit
  fi

  if ((CREATE_APP_LINK)); then
    run install -d -m 0750 -o root -g root "$(dirname "$APP_UNIT_LINK")"
    if [[ -L "$APP_UNIT_LINK" ]]; then
      local current; current="$(readlink "$APP_UNIT_LINK")"
      if [[ "$current" == "$UNIT_INSTALL_PATH" ]]; then ok "App-Symlink ist korrekt: $APP_UNIT_LINK -> $UNIT_INSTALL_PATH"
      else run ln -sfn "$UNIT_INSTALL_PATH" "$APP_UNIT_LINK"; ok "App-Symlink aktualisiert: $APP_UNIT_LINK -> $UNIT_INSTALL_PATH"; fi
    elif [[ -e "$APP_UNIT_LINK" ]]; then
      backup_path "$APP_UNIT_LINK" 'Vorhandene App-Unit'
      run ln -s "$UNIT_INSTALL_PATH" "$APP_UNIT_LINK"
      ok "App-Symlink erstellt: $APP_UNIT_LINK -> $UNIT_INSTALL_PATH"
    else
      run ln -s "$UNIT_INSTALL_PATH" "$APP_UNIT_LINK"
      ok "App-Symlink erstellt: $APP_UNIT_LINK -> $UNIT_INSTALL_PATH"
    fi
  fi

  run systemctl daemon-reload
  if ((DRY_RUN == 0)); then
    local load_state; load_state="$(systemctl show "$UNIT" -p LoadState --value 2>/dev/null || true)"
    [[ "$load_state" == loaded ]] || die "$UNIT wurde nicht geladen (LoadState=$load_state)"
  fi
  ok 'systemd daemon-reload abgeschlossen'
}

atomic_install_unit() {
  local tmp
  if ((DRY_RUN)); then
    printf '[DRY] install unit %q -> %q\n' "$UNIT_TEMPLATE" "$UNIT_INSTALL_PATH"
    return 0
  fi
  tmp="$(mktemp "${SYSTEMD_DIR}/.${UNIT}.tmp.XXXXXX")"
  if ! install -m "$UNIT_MODE" -o root -g root "$UNIT_TEMPLATE" "$tmp"; then
    rm -f -- "$tmp"
    die "Unit-Template konnte nicht in temporaere Datei installiert werden"
  fi
  if ! mv -f "$tmp" "$UNIT_INSTALL_PATH"; then
    rm -f -- "$tmp"
    die "Atomare Unit-Installation fehlgeschlagen: $UNIT_INSTALL_PATH"
  fi
  ok "Unit installiert: $UNIT_INSTALL_PATH <- $UNIT_TEMPLATE"
}

remove_unit() {
  [[ $EUID -eq 0 ]] || die 'Als root ausfuehren'
  run systemctl disable --now "$UNIT" 2>/dev/null || true
  if [[ -L "$APP_UNIT_LINK" ]]; then
    [[ "$(readlink "$APP_UNIT_LINK")" == "$UNIT_INSTALL_PATH" ]] || die "App-Symlink zeigt auf fremdes Ziel: $APP_UNIT_LINK"
    run rm -f "$APP_UNIT_LINK"; ok "App-Symlink entfernt: $APP_UNIT_LINK"
  elif [[ -e "$APP_UNIT_LINK" ]]; then die "App-Link-Pfad ist keine verwaltete Symlink-Datei: $APP_UNIT_LINK"; fi
  if [[ -f "$UNIT_INSTALL_PATH" && ! -L "$UNIT_INSTALL_PATH" ]]; then
    backup_path "$UNIT_INSTALL_PATH" 'Installierte Unit'
  elif [[ -L "$UNIT_INSTALL_PATH" ]]; then
    backup_path "$UNIT_INSTALL_PATH" 'Installierter Unit-Symlink'
  elif [[ -e "$UNIT_INSTALL_PATH" ]]; then die "Unit-Pfad ist kein regulaerer/symlink Pfad: $UNIT_INSTALL_PATH"; fi
  run systemctl daemon-reload
  ok "Unit entfernt: $UNIT"
}

validate_all
if [[ "$ACTION" == check ]]; then
  ok 'Pruefung erfolgreich; keine Aenderungen durchgefuehrt'
  exit 0
fi
if [[ "$ACTION" == remove-unit ]]; then remove_unit; exit 0; fi
[[ $EUID -eq 0 ]] || die 'Fuer Installation/Rechte als root ausfuehren'

run_hook pre_apply
for section in "${SECTIONS[@]}"; do [[ "$section" == directory:* ]] && apply_directory "$section"; done
for section in "${SECTIONS[@]}"; do [[ "$section" == file:* ]] && apply_file "$section"; done
run_hook post_apply

WAS_ACTIVE=0
systemctl is-active --quiet "$UNIT" 2>/dev/null && WAS_ACTIVE=1 || true
install_unit_file

START_MODE="$CLI_START_MODE"
if [[ -z "$START_MODE" ]]; then
  if ((INI_RESTART_IF_ACTIVE && WAS_ACTIVE)); then START_MODE='restart'
  elif ((INI_ENABLE)); then START_MODE='enable'
  elif ((INI_START)); then START_MODE='start'
  else START_MODE='none'
  fi
fi

case "$START_MODE" in
  enable)
    run_hook pre_start
    run systemctl enable "$UNIT"
    if ((WAS_ACTIVE)); then run systemctl restart "$UNIT"; else run systemctl start "$UNIT"; fi
    run_hook post_start
    ;;
  restart)
    run_hook pre_start
    if ((WAS_ACTIVE)); then run systemctl restart "$UNIT"; else run systemctl start "$UNIT"; fi
    run_hook post_start
    ;;
  start)
    run_hook pre_start
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then run systemctl restart "$UNIT"; else run systemctl start "$UNIT"; fi
    run_hook post_start
    ;;
  none) : ;;
  *) die "Interner Fehler: unbekannter Startmodus: $START_MODE" ;;
esac

if [[ "$START_MODE" != none && $DRY_RUN -eq 0 ]]; then
  systemctl is-active --quiet "$UNIT" || {
    journalctl -u "$UNIT" -n 80 --no-pager >&2 || true
    die "$UNIT ist nicht aktiv"
  }
  ok "$UNIT ist aktiv"
fi
ok "Installation/Aktualisierung abgeschlossen: $UNIT"
