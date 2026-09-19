#!/usr/bin/env bash
# Generic Service Analyzer
# Version: 1.3.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="$SCRIPT_DIR/service-install.ini"
DO_RESTART=0
JOURNAL_LINES=50

usage() {
  cat <<'USAGE'
Usage:
  ./_analyze.sh [--restart] [--config FILE] [--journal-lines N]

Prueft:
  - INI und Unit-Template
  - regulaere Unit-Datei unter /etc/systemd/system
  - Rueckwaerts-Symlink im Anwendungsverzeichnis
  - Abweichung Template <-> installierte Unit
  - erwartete Besitzer, Gruppen und Modi aus der INI
  - systemd Load/Active/Enabled
  - optionale Syntax-, JSON-, Kommando- und Dateipruefungen aus [analysis]
USAGE
}

ok(){ printf '[OK] %s\n' "$*"; }
info(){ printf '[i ] %s\n' "$*"; }
warn(){ printf '[!!] %s\n' "$*" >&2; }
err(){ printf '[ERR] %s\n' "$*" >&2; ERRORS=$((ERRORS+1)); }
die(){ printf '[ERR] %s\n' "$*" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --config) shift; (($#)) || die '--config benoetigt eine Datei'; CONFIG_FILE="$1" ;;
    --restart) DO_RESTART=1 ;;
    --journal-lines) shift; (($#)) || die '--journal-lines benoetigt eine Zahl'; JOURNAL_LINES="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unbekannte Option: $1" ;;
  esac
  shift
done
[[ "$JOURNAL_LINES" =~ ^[0-9]+$ ]] || die 'journal-lines muss numerisch sein'
[[ -f "$CONFIG_FILE" ]] || die "INI-Datei fehlt: $CONFIG_FILE"
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd -P)/$(basename "$CONFIG_FILE")"

# Zuerst dieselbe strikte Validierung wie bei der Installation.
"$SCRIPT_DIR/_install.sh" --config "$CONFIG_FILE" --check

# Minimaler sicherer INI-Reader, kein source/eval.
declare -A CFG=()
declare -a SECTIONS=()
declare -A SEEN=()
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
section=''; lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno+1)); line="${line%$'\r'}"; stripped="$(trim "$line")"
  [[ -z "$stripped" || "$stripped" == \#* || "$stripped" == \;* ]] && continue
  if [[ "$stripped" =~ ^\[([A-Za-z0-9_.:-]+)\]$ ]]; then
    section="${BASH_REMATCH[1]}"; [[ -n "${SEEN[$section]+x}" ]] || { SECTIONS+=("$section"); SEEN[$section]=1; }; continue
  fi
  [[ "$stripped" == *=* ]] || die "$CONFIG_FILE:$lineno: ungueltige Zeile"
  key="$(trim "${stripped%%=*}")"; value="$(trim "${stripped#*=}")"
  [[ "$value" =~ ^\"(.*)\"$ ]] && value="${BASH_REMATCH[1]}"
  [[ "$value" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
  CFG["$section.$key"]="$value"
done < "$CONFIG_FILE"
raw(){ local k="$1.$2" d="${3-}"; [[ -n "${CFG[$k]+x}" ]] && printf '%s' "${CFG[$k]}" || printf '%s' "$d"; }
APP_DIR="$(raw application app_dir)"; UNIT="$(raw service unit)"; SERVICE_ID="$(raw application service_id "$(basename "$APP_DIR")")"
expand(){ local v="$1"; v="${v//\$\{APP_DIR\}/$APP_DIR}"; v="${v//\$\{PACKAGE_DIR\}/$SCRIPT_DIR}"; v="${v//\$\{CONFIG_DIR\}/$(dirname "$CONFIG_FILE")}"; v="${v//\$\{UNIT\}/$UNIT}"; v="${v//\$\{SERVICE_ID\}/$SERVICE_ID}"; printf '%s' "$v"; }
cfg(){ expand "$(raw "$1" "$2" "${3-}")"; }
bool(){ case "${1,,}" in 1|yes|true|on) return 0;; *) return 1;; esac; }

SYSTEMD_DIR="$(cfg service systemd_dir /etc/systemd/system)"
UNIT_TEMPLATE="$(cfg service unit_template "service/$UNIT.example")"; [[ "$UNIT_TEMPLATE" == /* ]] || UNIT_TEMPLATE="$APP_DIR/$UNIT_TEMPLATE"
UNIT_INSTALL="$(cfg service unit_install_path "$SYSTEMD_DIR/$UNIT")"
APP_LINK="$(cfg service app_symlink_path "service/$UNIT")"; [[ "$APP_LINK" == /* ]] || APP_LINK="$APP_DIR/$APP_LINK"
ERRORS=0

echo '--- Unit-Dateien ---'
[[ -f "$UNIT_TEMPLATE" && ! -L "$UNIT_TEMPLATE" ]] && ok "Template: $UNIT_TEMPLATE" || err "Template fehlt/ist Symlink: $UNIT_TEMPLATE"
[[ -f "$UNIT_INSTALL" && ! -L "$UNIT_INSTALL" ]] && ok "Installierte Unit ist regulaer: $UNIT_INSTALL" || err "Installierte Unit fehlt oder ist Symlink: $UNIT_INSTALL"
if [[ -L "$APP_LINK" ]]; then
  target="$(readlink "$APP_LINK")"
  [[ "$target" == "$UNIT_INSTALL" ]] && ok "App-Symlink: $APP_LINK -> $target" || err "App-Symlink zeigt auf $target statt $UNIT_INSTALL"
else
  err "App-Symlink fehlt: $APP_LINK"
fi
if [[ -f "$UNIT_TEMPLATE" && -f "$UNIT_INSTALL" ]]; then
  if cmp -s "$UNIT_TEMPLATE" "$UNIT_INSTALL"; then ok 'Template und installierte Unit sind identisch'; else warn 'Template und installierte Unit unterscheiden sich: _install.sh ausfuehren'; ERRORS=$((ERRORS+1)); fi
fi
VERIFY_UNIT="$(cfg service verify_unit true)"
if bool "$VERIFY_UNIT" && command -v systemd-analyze >/dev/null && [[ -f "$UNIT_INSTALL" ]]; then
  systemd-analyze verify "$UNIT_INSTALL" >/dev/null && ok 'systemd-analyze verify erfolgreich' || err 'systemd-analyze verify fehlgeschlagen'
else
  info 'systemd-analyze verify ist deaktiviert oder nicht verfuegbar'
fi

echo '--- Rechte aus service-install.ini ---'
for s in "${SECTIONS[@]}"; do
  case "$s" in
    directory:*|file:*)
      p="$(cfg "$s" path '')"; owner="$(cfg "$s" owner root)"; group="$(cfg "$s" group root)"
      [[ "$s" == directory:* ]] && mode="$(cfg "$s" mode 0750)" || mode="$(cfg "$s" mode 0640)"
      mode="${mode#0}"
      if [[ ! -e "$p" && ! -L "$p" ]]; then err "Fehlt: $p"; continue; fi
      actual="$(stat -c '%U:%G %a' "$p" 2>/dev/null || true)"
      expected="$owner:$group $mode"
      [[ "$actual" == "$expected" ]] && ok "$p ($actual)" || { warn "$p: IST $actual, SOLL $expected"; ERRORS=$((ERRORS+1)); }
      ;;
  esac
done

echo '--- systemd ---'
if ((DO_RESTART)); then
  [[ $EUID -eq 0 ]] || die '--restart muss als root ausgefuehrt werden'
  systemctl daemon-reload
  systemctl restart "$UNIT"
fi
if systemctl show "$UNIT" -p FragmentPath -p LoadState -p ActiveState -p SubState -p UnitFileState --no-pager 2>/dev/null; then :; else err "systemctl show fehlgeschlagen: $UNIT"; fi
EXPECT_ENABLE="$(cfg service enable false)"
EXPECT_START="$(cfg service start false)"
if systemctl is-active --quiet "$UNIT"; then
  ok "$UNIT ist aktiv"
elif bool "$EXPECT_START" || bool "$EXPECT_ENABLE"; then
  err "$UNIT ist nicht aktiv, obwohl Start erwartet wird"
else
  warn "$UNIT ist nicht aktiv"
fi
if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
  ok "$UNIT ist aktiviert"
elif bool "$EXPECT_ENABLE"; then
  err "$UNIT ist nicht aktiviert, obwohl Enable erwartet wird"
else
  warn "$UNIT ist nicht aktiviert"
fi

ANALYSIS_TYPE="$(cfg analysis type none)"
ENTRY="$(cfg analysis entry '')"
JSON_FILES="$(cfg analysis json_files '')"
REQUIRED_COMMANDS="$(cfg analysis required_commands '')"
REQUIRED_FILES="$(cfg analysis required_files '')"
LOG_FILE="$(cfg analysis log_file '')"

echo '--- Anwendungspruefung ---'
case "${ANALYSIS_TYPE,,}" in
  none|'') info 'Keine Syntaxpruefung konfiguriert' ;;
  perl) [[ -f "$ENTRY" ]] && /usr/bin/perl -c "$ENTRY" && ok "Perl-Syntax: $ENTRY" || err "Perl-Syntax fehlgeschlagen: $ENTRY" ;;
  php) [[ -f "$ENTRY" ]] && /usr/bin/php -l "$ENTRY" && ok "PHP-Syntax: $ENTRY" || err "PHP-Syntax fehlgeschlagen: $ENTRY" ;;
  python) [[ -f "$ENTRY" ]] && /usr/bin/python3 -m py_compile "$ENTRY" && ok "Python-Syntax: $ENTRY" || err "Python-Syntax fehlgeschlagen: $ENTRY" ;;
  shell) [[ -f "$ENTRY" ]] && /bin/bash -n "$ENTRY" && ok "Shell-Syntax: $ENTRY" || err "Shell-Syntax fehlgeschlagen: $ENTRY" ;;
  *) err "Unbekannter analysis.type: $ANALYSIS_TYPE" ;;
esac
IFS=',' read -r -a json_array <<< "$JSON_FILES"
for f in "${json_array[@]}"; do
  f="$(trim "$f")"; [[ -n "$f" ]] || continue; f="$(expand "$f")"
  if [[ -f "$f" ]] && /usr/bin/perl -MJSON::PP -0777 -e 'decode_json(<>);' < "$f"; then ok "JSON: $f"; else err "JSON ungueltig/fehlt: $f"; fi
done
IFS=',' read -r -a command_array <<< "$REQUIRED_COMMANDS"
for cmd in "${command_array[@]}"; do
  cmd="$(trim "$cmd")"; [[ -n "$cmd" ]] || continue; cmd="$(expand "$cmd")"
  if [[ "$cmd" == /* ]]; then
    resolved="$(readlink -f -- "$cmd" 2>/dev/null || true)"
    if [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]]; then
      owner_uid="$(stat -Lc '%u' -- "$resolved" 2>/dev/null || true)"
      mode_oct="$(stat -Lc '%a' -- "$resolved" 2>/dev/null || true)"
      cmd_parent="$(dirname -- "$cmd")"
      parent_uid="$(stat -Lc '%u' -- "$cmd_parent" 2>/dev/null || true)"
      parent_mode="$(stat -Lc '%a' -- "$cmd_parent" 2>/dev/null || true)"
      trusted_path=0
      case "$cmd" in /usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*|/bin/*|/sbin/*) trusted_path=1 ;; esac
      trusted_target=0
      case "$resolved" in /usr/*|/bin/*|/sbin/*) trusted_target=1 ;; esac
      if [[ "$trusted_path" == "1" && "$trusted_target" == "1" && "$owner_uid" == "0" && "$parent_uid" == "0" && "$mode_oct" =~ ^[0-7]+$ && "$parent_mode" =~ ^[0-7]+$ ]] \
         && (( (8#$mode_oct & 0022) == 0 )) && (( (8#$parent_mode & 0022) == 0 )); then
        if [[ "$resolved" == "$cmd" ]]; then
          ok "Kommando: $cmd"
        else
          ok "Kommando: $cmd -> $resolved (sicher aufgeloester Symlink)"
        fi
      else
        err "Kommando-Pfad/Ziel ist nicht vertrauenswuerdig (Systempfad, root-owned und nicht group/world-writable erforderlich): $cmd -> $resolved"
      fi
    else
      err "Kommando fehlt oder Ziel ist nicht ausfuehrbar: $cmd"
    fi
  else
    resolved="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      target="$(readlink -f -- "$resolved" 2>/dev/null || true)"
      [[ -n "$target" && -f "$target" && -x "$target" ]] && ok "Kommando: $cmd -> $target" || err "Kommando-Ziel ungueltig: $cmd -> ${target:-?}"
    else
      err "Kommando fehlt: $cmd"
    fi
  fi
done
IFS=',' read -r -a required_file_array <<< "$REQUIRED_FILES"
for f in "${required_file_array[@]}"; do
  f="$(trim "$f")"; [[ -n "$f" ]] || continue; f="$(expand "$f")"
  [[ -f "$f" && -r "$f" && ! -L "$f" ]] && ok "Erforderliche Datei: $f" || err "Erforderliche Datei fehlt, ist nicht lesbar oder ist ein Symlink: $f"
done

echo "--- Journal ($JOURNAL_LINES Zeilen) ---"
journalctl -u "$UNIT" -n "$JOURNAL_LINES" --no-pager 2>/dev/null || true
if [[ -n "$LOG_FILE" ]]; then
  LOG_FILE="$(expand "$LOG_FILE")"
  echo "--- Logdatei: $LOG_FILE ---"
  [[ -f "$LOG_FILE" ]] && tail -n "$JOURNAL_LINES" "$LOG_FILE" || warn 'Logdatei nicht vorhanden/lesbar'
fi

if ((ERRORS)); then
  printf '[ERR] Analyse abgeschlossen: %d Abweichung(en)\n' "$ERRORS" >&2
  exit 1
fi
ok 'Analyse ohne Abweichungen abgeschlossen'
