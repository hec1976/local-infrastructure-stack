#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT/teko-stack.conf"
[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }
if [[ -s "${BASELINE_REPO_DIR}/repodata/repomd.xml" && "${TEKO_FORCE:-0}" != "1" ]]; then
  echo "Baseline Repository bereits vorhanden und bleibt unveraendert: ${BASELINE_REPO_DIR}"
  echo "Fuer einen bewussten Neuaufbau: sudo TEKO_FORCE=1 ./setup_baseline_repository.sh"
  exit 0
fi
FETCH_MODE="${BASELINE_REPO_FETCH:-auto}"
args=()
if [[ "$FETCH_MODE" == "1" || "$FETCH_MODE" == "yes" ]]; then
  args+=(--fetch)
elif [[ "$FETCH_MODE" == "auto" ]]; then
  shopt -s nullglob
  mons=("$ROOT"/baseline-repository/packages/monit-*.rpm)
  alls=("$ROOT"/baseline-repository/packages/alloy-*.rpm)
  shopt -u nullglob
  if (( ${#mons[@]} == 0 || ${#alls[@]} == 0 )); then args+=(--fetch); fi
fi
"$ROOT/baseline-repository/scripts/prepare_repository.sh" "${args[@]}"

REPOMD="${BASELINE_REPO_DIR%/}/repodata/repomd.xml"
[[ -s "$REPOMD" ]] || { echo "FEHLER: Repository-Metadaten fehlen lokal: $REPOMD" >&2; exit 1; }
echo "[OK] Lokale Repository-Metadaten: $REPOMD"

# Publishing aktivieren/reloaden, bevor Remote-Clients den URL verwenden.
# setup_config_manager.sh legt Alias/Directory im Config-Manager-VHost an; hier
# wird dessen Runtime-Zustand fail-closed verifiziert.
if command -v apache2ctl >/dev/null 2>&1 && systemctl is-active --quiet apache2 2>/dev/null; then
  apache2ctl configtest >/dev/null || { echo "FEHLER: Apache-Konfiguration ungueltig; Repository kann nicht publiziert werden." >&2; exit 1; }
  systemctl reload apache2
fi

# Die Remote-Clients verwenden HTTPS. Deshalb bereits auf dem Management-Host
# pruefen, ob exakt dieselben Metadaten ueber den Apache-VHost publiziert sind.
if [[ "${BASELINE_REPO_URL:-}" == https://* ]] && command -v curl >/dev/null 2>&1; then
  META_URL="${BASELINE_REPO_URL%/}/repodata/repomd.xml"
  CURL_ARGS=(-fsS --connect-timeout 5 --max-time 15)
  if [[ -s /etc/apache2/ssl/config-manager.crt ]]; then
    CURL_ARGS+=(--cacert /etc/apache2/ssl/config-manager.crt)
  fi
  if curl "${CURL_ARGS[@]}" -o /dev/null "$META_URL"; then
    echo "[OK] HTTPS Repository-Publishing: $META_URL"
  else
    echo "FEHLER: Repository ist lokal gueltig, aber ueber HTTPS nicht erreichbar: $META_URL" >&2
    echo "        Pruefe Apache-VHost/Alias, Zertifikat und Namensaufloesung." >&2
    exit 1
  fi
fi

echo "Baseline Repository URL: ${BASELINE_REPO_URL}"
