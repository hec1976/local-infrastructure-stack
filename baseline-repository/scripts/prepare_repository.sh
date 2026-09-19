#!/bin/bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STACK_ROOT="$(cd "$ROOT/.." && pwd -P)"
TARGET="${BASELINE_REPO_DIR:-/srv/www/baseline-repo}"
FETCH=0
[[ "${1:-}" == "--fetch" ]] && FETCH=1
[[ $EUID -eq 0 ]] || { echo "FEHLER: Bitte als root/sudo ausfuehren." >&2; exit 1; }
command -v zypper >/dev/null 2>&1 || { echo "FEHLER: zypper fehlt; Repository-Builder ist fuer SLES/openSUSE vorgesehen." >&2; exit 1; }

on_err() {
    local rc=$? line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}
    echo >&2
    echo "FEHLER: Baseline-Repository konnte nicht vorbereitet werden." >&2
    echo "  Zeile   : $line" >&2
    echo "  Kommando: $cmd" >&2
    echo "  Exitcode: $rc" >&2
    echo "Das Hauptsetup wird damit nicht mehr kommentarlos beendet." >&2
    exit "$rc"
}
trap on_err ERR

step(){ printf '\n>>> %s\n' "$*"; }

# Build-Werkzeuge nur auf dem Repository-Builder, nie auf den Clients.
step "RPM-Buildwerkzeuge pruefen/installieren"
zypper --non-interactive install rpm-build systemd-rpm-macros createrepo_c >/dev/null

WORK="$(mktemp -d /tmp/infrastructure-baseline-repo.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/rpmbuild"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$WORK/repo"
cp "$STACK_ROOT/monit-exporter/bin/monit-prometheus-exporter-linux-amd64" "$WORK/rpmbuild/SOURCES/"
cp "$ROOT/SOURCES/monit-prometheus-exporter.service" "$WORK/rpmbuild/SOURCES/"
cp "$ROOT/SOURCES/alloy-baseline.conf" "$WORK/rpmbuild/SOURCES/"
cp "$ROOT/SOURCES/configure-observability-client.sh" "$WORK/rpmbuild/SOURCES/"
cp "$ROOT/SPECS/"*.spec "$WORK/rpmbuild/SPECS/"

step "Eigene Baseline-RPMs bauen"
rpmbuild --define "_topdir $WORK/rpmbuild" -bb "$WORK/rpmbuild/SPECS/monit-prometheus-exporter.spec"
rpmbuild --define "_topdir $WORK/rpmbuild" -bb "$WORK/rpmbuild/SPECS/client-baseline.spec"
find "$WORK/rpmbuild/RPMS" -type f -name '*.rpm' -exec cp -a {} "$WORK/repo/" \;

# Vorab freigegebene/offline RPMs haben Vorrang.
find "$ROOT/packages" -maxdepth 1 -type f -name '*.rpm' -exec cp -a {} "$WORK/repo/" \;

have_pkg(){ local n="$1"; find "$WORK/repo" -maxdepth 1 -type f -name "${n}-*.rpm" -print -quit | grep -q .; }

copy_downloaded_pkg_from_zypp_cache() {
    local pkg="$1" candidate="" newest_mtime=0 mtime=0 rpm_name=""
    local cache_root="/var/cache/zypp/packages"
    [[ -d "$cache_root" ]] || return 1

    # `zypper download` legt Pakete je nach zypper/libzypp-Version im
    # zypp-Paketcache ab und nicht zwingend im aktuellen Arbeitsverzeichnis.
    # Deshalb wird nach dem Download das passende RPM anhand der RPM-Metadaten
    # aus dem Cache uebernommen. Der Dateiname allein ist nicht massgeblich
    # (z.B. alloy-...amd64.rpm bei RPM-Arch x86_64).
    while IFS= read -r -d '' f; do
        rpm_name="$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null || true)"
        [[ "$rpm_name" == "$pkg" ]] || continue
        mtime="$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
        if (( mtime >= newest_mtime )); then
            newest_mtime=$mtime
            candidate="$f"
        fi
    done < <(find "$cache_root" -type f -name "${pkg}-*.rpm" -print0 2>/dev/null)

    [[ -n "$candidate" ]] || return 1
    cp -a "$candidate" "$WORK/repo/"
    echo "RPM aus zypp-Cache uebernommen: $candidate"
}

download_pkg() {
    local pkg="$1"
    step "Vendor-RPM laden: $pkg"

    # zypper download schreibt auf SLES/openSUSE typischerweise in den
    # libzypp-Paketcache (/var/cache/zypp/packages/...). Manche Versionen
    # schreiben dagegen in das aktuelle Verzeichnis. Beide Varianten werden
    # unterstuetzt.
    if ! ( cd "$WORK/repo" && zypper --non-interactive download "$pkg" ); then
        echo "FEHLER: RPM '$pkg' konnte nicht mit zypper download geladen werden." >&2
        echo "Alternative: RPM manuell nach $ROOT/packages/ legen und Setup erneut starten." >&2
        return 1
    fi

    if ! have_pkg "$pkg"; then
        copy_downloaded_pkg_from_zypp_cache "$pkg" || {
            echo "FEHLER: zypper meldete Erfolg, aber das RPM '$pkg' wurde weder im Arbeitsverzeichnis noch im zypp-Cache gefunden." >&2
            echo "Gesucht wurde auch unter /var/cache/zypp/packages/." >&2
            return 1
        }
    fi

    have_pkg "$pkg" || {
        echo "FEHLER: RPM '$pkg' konnte nach dem Download nicht in das interne Repository uebernommen werden." >&2
        return 1
    }
}

if (( FETCH )); then
    if ! have_pkg monit; then
        download_pkg monit
    fi
    if ! have_pkg alloy; then
        step "Grafana Repository fuer den Repository-Builder vorbereiten"
        if ! zypper lr -u | grep -q 'rpm\.grafana\.com'; then
            rpm --import https://rpm.grafana.com/gpg.key
            zypper --non-interactive addrepo --check --refresh https://rpm.grafana.com grafana
        fi
        zypper --non-interactive refresh grafana
        download_pkg alloy
    fi
fi

missing=()
for p in monit alloy monit-prometheus-exporter client-baseline; do
    have_pkg "$p" || missing+=("$p")
done
if (( ${#missing[@]} )); then
    echo "FEHLER: Baseline-Repository ist nicht vollstaendig. Fehlend: ${missing[*]}" >&2
    echo "Vendor-RPMs nach $ROOT/packages/ legen oder setup_baseline_repository.sh mit BASELINE_REPO_FETCH=1 ausfuehren." >&2
    exit 1
fi

step "Repository-Metadaten erzeugen"
createrepo_c "$WORK/repo"
install -d -o root -g root -m 0755 "$TARGET"
rm -rf "$TARGET"/*
cp -a "$WORK/repo"/. "$TARGET"/
(
  cd "$TARGET"
  find . -maxdepth 1 -type f -name '*.rpm' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
python3 - "$TARGET" <<'PY_MANIFEST'
import hashlib,json,pathlib,subprocess,sys,datetime
root=pathlib.Path(sys.argv[1])
items=[]
for rpm in sorted(root.glob('*.rpm')):
    q=subprocess.check_output(['rpm','-qp','--qf','%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}',str(rpm)], universal_newlines=True).strip().split('|')
    h=hashlib.sha256(rpm.read_bytes()).hexdigest()
    items.append({'file':rpm.name,'name':q[0],'version':q[1],'release':q[2],'arch':q[3],'sha256':h})
data={'schema_version':1,'name':'infrastructure-baseline','generated_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'meta_package':'client-baseline','ready':True,'packages':items}
(root/'BASELINE_REPOSITORY.json').write_text(json.dumps(data,indent=2)+'\n')
PY_MANIFEST
chmod -R a+rX "$TARGET"

# Verbindliche Build-Pruefung: die RPM-Metadaten muessen lokal vorhanden sein.
[[ -s "$TARGET/repodata/repomd.xml" ]] || { echo "FEHLER: repodata/repomd.xml fehlt nach createrepo_c." >&2; exit 1; }

# Remote-Clients verwenden HTTPS. Das Publishing wird deshalb separat getestet.
# Ein Publishing-/Trust-Problem blockiert die lokale Master-Installation nicht,
# wird aber klar gemeldet.
if command -v curl >/dev/null 2>&1 && [[ -n "${BASELINE_REPO_URL:-}" ]]; then
  repo_probe="${BASELINE_REPO_URL%/}/repodata/repomd.xml"
  curl_args=(--fail --silent --show-error --max-time 8)
  if [[ -r /etc/apache2/ssl/config-manager.crt ]]; then
    curl_args+=(--cacert /etc/apache2/ssl/config-manager.crt)
  fi
  if ! curl "${curl_args[@]}" "$repo_probe" >/dev/null 2>&1; then
    echo "WARNUNG: Repository ist lokal gueltig, aber ueber HTTPS noch nicht erreichbar:" >&2
    echo "  $repo_probe" >&2
    echo "Remote-Clients koennen erst nach erfolgreichem Publishing/Trust darauf zugreifen." >&2
  else
    echo "HTTPS-Publishing geprueft: $repo_probe"
  fi
fi

step "Baseline Repository fertig"
echo "Pfad: $TARGET"
echo "Pakete:"
rpm -qp --qf '  %{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' "$TARGET"/*.rpm | sort
echo "Baseline Repository bereit: $TARGET"
