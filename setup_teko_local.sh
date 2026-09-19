#!/bin/bash
#
# Local Infrastructure Stack - single-server master setup
#
# Reihenfolge:
#   1. Hostname / lokale Namen
#   2. Forgejo + Podman + Apache HTTPS
#   3. Config-Agent
#   4. Config-Manager
#   5. Internes Baseline Paket-Repository
#   6. Grafana + Loki + Audit REST Importer
#   7. Postfix + Monit + Managed-Config-Katalog
#   8. optional Forgejo API token
#   9. Gesamt-Healthcheck
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$ROOT/teko-stack.conf"

FORCE=0
SHOW_SECRETS=1
NAME_MODE="auto"
usage() {
    cat <<'EOF'
Verwendung:
  sudo ./setup_teko_local.sh [--force] [--configure-names|--default-names] [--show-secrets|--hide-secrets]

Optionen:
  --force  Verwaltete Komponenten und Konfigurationen erneut deployen.
           Persistente Daten/Secrets (Forgejo-Repositories, Loki/Grafana-Daten,
           Audit-DB, Benutzer, Tokens und private TLS-Schluessel) bleiben erhalten.
  --configure-names  Hostnamen/FQDNs interaktiv konfigurieren und persistent speichern.
  --default-names    Paketdefaults fuer Hostnamen/FQDNs verwenden und gespeichertes Profil entfernen.
  --show-secrets  Abschlussuebersicht inklusive gespeicherter Passwoerter/Tokens.
                  Dies ist der Default bei der interaktiven Installation.
  --hide-secrets  Passwoerter/Tokens in der Abschlussuebersicht nicht anzeigen.
  -h, --help  Diese Hilfe anzeigen.
EOF
}

while (($#)); do
    case "$1" in
        --force) FORCE=1 ;;
        --configure-names) NAME_MODE="configure" ;;
        --default-names) NAME_MODE="defaults" ;;
        --show-secrets) SHOW_SECRETS=1 ;;
        --hide-secrets) SHOW_SECRETS=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unbekannter Parameter: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

export TEKO_FORCE="$FORCE"

[[ $EUID -eq 0 ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Paket-Repository-Hygiene vor dem ersten globalen zypper refresh
# ---------------------------------------------------------------------------
# Ein abgebrochener/alter Lauf kann die Repository-ID infrastructure-baseline
# noch auf die spaetere HTTPS-Publishing-URL zeigen lassen. Zu diesem Zeitpunkt
# sind Apache/Config-Manager und das Repository aber ggf. noch gar nicht bereit.
# Ein anschliessendes "zypper refresh" in Forgejo/Agent/Manager wuerde dann
# das gesamte Bootstrap stoppen, obwohl dieses Repository fuer die Bootstrap-
# Pakete noch gar nicht benoetigt wird.
#
# Auf dem Management-Server gilt deshalb:
#   - ist ein lokales repomd.xml bereits vorhanden -> Repo auf file:// binden
#   - sonst einen stale Eintrag entfernen; er wird nach dem Build sauber neu
#     angelegt. Remote-Clients sind davon nicht betroffen.
prepare_baseline_repo_for_bootstrap() {
    command -v zypper >/dev/null 2>&1 || return 0
    local alias="infrastructure-baseline"
    local local_dir="${BASELINE_REPO_DIR:-/srv/www/baseline-repo}"
    local local_url="file://${local_dir%/}/"
    local repomd="${local_dir%/}/repodata/repomd.xml"

    if zypper --non-interactive lr -u 2>/dev/null | grep -Eq "(^|[[:space:]|])${alias}([[:space:]|]|$)"; then
        echo
        echo ">>> Vorhandenes Baseline-Repository vor Bootstrap pruefen"
        if [[ -s "$repomd" ]]; then
            echo "Lokales Repository ist vorhanden; Repository-ID wird auf $local_url gebunden."
            zypper --non-interactive removerepo "$alias" >/dev/null 2>&1 || true
            zypper --non-interactive addrepo -G --check --refresh "$local_url" "$alias" >/dev/null
        else
            echo "Staler Repository-Eintrag wird vor dem Bootstrap entfernt."
            echo "Er wird nach dem Repository-Build erneut eingerichtet."
            zypper --non-interactive removerepo "$alias" >/dev/null 2>&1 || true
        fi
    fi
}

prepare_baseline_repo_for_bootstrap

# Hostnamen/FQDNs: Defaultwerte bleiben unveraendert, koennen aber beim Setup
# ohne manuelle Dateibearbeitung angepasst werden.
if [[ "$NAME_MODE" == "defaults" ]]; then
    rm -f /etc/local-infrastructure-stack.conf
    unset SERVER_SHORTNAME SERVER_FQDN FORGEJO_FQDN CONFIG_MANAGER_FQDN GRAFANA_FQDN CONFIG_AGENT_PORT CONFIG_AGENT_URL
    source "$ROOT/teko-stack.conf"
elif [[ "$NAME_MODE" == "configure" ]]; then
    /bin/bash "$ROOT/bin/stack-name-config.sh" --configure
    source /etc/local-infrastructure-stack.conf
    CONFIG_AGENT_URL="https://127.0.0.1:${CONFIG_AGENT_PORT}"
    export SERVER_SHORTNAME SERVER_FQDN FORGEJO_FQDN CONFIG_MANAGER_FQDN GRAFANA_FQDN CONFIG_AGENT_PORT CONFIG_AGENT_URL
elif [[ -t 0 && -t 1 ]]; then
    if [[ -r /etc/local-infrastructure-stack.conf ]]; then
        printf 'Gespeicherte Hostnamen/FQDNs verwenden? [J/n] '
        read -r _keep_names
        if [[ "${_keep_names:-j}" =~ ^[Nn]$ ]]; then
            /bin/bash "$ROOT/bin/stack-name-config.sh" --configure
            source /etc/local-infrastructure-stack.conf
        fi
    else
        printf 'Standard-Hostnamen verwenden (teko.local, git.local, config-manager.local, grafana.local)? [J/n] '
        read -r _default_names
        if [[ "${_default_names:-j}" =~ ^[Nn]$ ]]; then
            /bin/bash "$ROOT/bin/stack-name-config.sh" --configure
            source /etc/local-infrastructure-stack.conf
        fi
    fi
    CONFIG_AGENT_URL="https://127.0.0.1:${CONFIG_AGENT_PORT}"
    export SERVER_SHORTNAME SERVER_FQDN FORGEJO_FQDN CONFIG_MANAGER_FQDN GRAFANA_FQDN CONFIG_AGENT_PORT CONFIG_AGENT_URL
fi

echo "============================================================"
echo " Local Infrastructure Stack"
echo "============================================================"
echo "IP             : $SERVER_IP"
echo "Server         : $SERVER_SHORTNAME / $SERVER_FQDN"
echo "Forgejo        : https://$FORGEJO_FQDN/"
echo "Config Manager : https://$CONFIG_MANAGER_FQDN/"
echo "Config Agent   : https://127.0.0.1:$CONFIG_AGENT_PORT"
echo "Grafana        : https://$GRAFANA_FQDN/"
if [[ "$FORCE" == "1" ]]; then
    echo "Modus          : FORCE (verwaltete Komponenten werden neu deployt)"
else
    echo "Modus          : normal"
fi
echo "============================================================"

/bin/bash "$ROOT/bin/teko-hosts.sh"

echo
echo ">>> Forgejo installieren"
/bin/bash "$ROOT/teko-forgejo-local/setup_forgejo_teko.sh"

echo
echo ">>> Config-Agent installieren"
/bin/bash "$ROOT/setup_config_agent.sh" "$ROOT/config-agent"

echo
echo ">>> Config-Manager installieren"
/bin/bash "$ROOT/setup_config_manager.sh" "$ROOT/config-manager-standalone" "/srv/www/config-manager-standalone"

echo
echo ">>> Zentrales Deploy-Profil fuer Observability Client bereitstellen"
/bin/bash "$ROOT/bin/bootstrap-observability-deploy-profile.sh"

echo
echo ">>> Baseline Paket-Repository vorbereiten"
if ! /bin/bash "$ROOT/setup_baseline_repository.sh"; then
    echo >&2
    echo "FEHLER: Baseline Paket-Repository konnte nicht vorbereitet werden." >&2
    echo "Das Setup stoppt kontrolliert. Die genaue Ursache steht direkt oberhalb." >&2
    echo "Offline: monit-/alloy-RPMs unter baseline-repository/packages/ ablegen." >&2
    exit 1
fi

echo
echo ">>> Authentifizierung Manager / Agent / Forgejo konsolidieren und live pruefen"
chmod 0755 "$ROOT/bin/teko-sync-auth.sh" 2>/dev/null || true
/bin/bash "$ROOT/bin/teko-sync-auth.sh"

echo
echo ">>> Agent Enrollment Manager installieren"
/bin/bash "$ROOT/setup_agent_enrollment_manager.sh"

echo
echo ">>> Observability (Grafana + Loki) installieren"
/bin/bash "$ROOT/setup_observability.sh"

echo
echo ">>> Postfix + Monit installieren und Config-Manager-Verwaltung vereinheitlichen"
/bin/bash "$ROOT/setup_postfix_monit.sh"

if [[ -n "${FORGEJO_API_TOKEN:-}" ]]; then
    echo
    echo ">>> Forgejo API-Token explizit ueberschreiben"
    /bin/bash "$ROOT/bin/set-forgejo-token.sh" "$FORGEJO_API_TOKEN"
elif [[ -s /opt/service/env/forgejo-api.token ]]; then
    echo
    echo ">>> Forgejo Service-Token wurde vom TEKO Forgejo-Bootstrap bereitgestellt."
else
    echo
    echo "WARNUNG: Forgejo Service-Token fehlt; Git Deploy/Repository Upload bleibt deaktiviert." >&2
fi

echo
echo ">>> Finale Authentifizierungs-Synchronisierung nach allen Komponenten"
chmod 0755 "$ROOT/bin/teko-sync-auth.sh" 2>/dev/null || true
/bin/bash "$ROOT/bin/teko-sync-auth.sh"

echo
echo ">>> Gesamtpruefung"
/bin/bash "$ROOT/bin/teko-health.sh"

echo
echo ">>> Zielsystem End-to-End Test inkl. Git-Deploy-GUI-Backend"
/bin/bash "$ROOT/bin/teko-postinstall-test.sh"

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
if [[ "$SHOW_SECRETS" == "1" ]]; then
    /bin/bash "$ROOT/bin/teko-access-summary.sh" --show-secrets
else
    /bin/bash "$ROOT/bin/teko-access-summary.sh"
fi
