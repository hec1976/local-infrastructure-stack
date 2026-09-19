#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/teko-common.sh"

[[ $EUID -eq 0 || "${TEKO_TEST_MODE:-0}" == "1" ]] || { echo "Bitte als root/sudo ausfuehren." >&2; exit 1; }

APACHE_ETC_DIR="${TEKO_APACHE_ETC_DIR:-/etc/apache2}"
LISTEN_CONF="${TEKO_APACHE_LISTEN_CONF:-$APACHE_ETC_DIR/listen.conf}"
SERVERNAME_CONF="${TEKO_APACHE_SERVERNAME_CONF:-$APACHE_ETC_DIR/conf.d/teko-servername.conf}"
SKIP_SERVICE="${TEKO_SKIP_APACHE_SERVICE:-0}"

if [[ "$SKIP_SERVICE" != "1" ]]; then
  a2enmod ssl || true
  a2enmod proxy || true
  a2enmod proxy_http || true
  a2enmod headers || true
  a2enmod rewrite || true
  a2enmod auth_basic || true
  a2enmod authn_file || true
fi

[[ -f "$LISTEN_CONF" ]] || { echo "$LISTEN_CONF fehlt." >&2; exit 1; }

cp -a "$LISTEN_CONF" "${LISTEN_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

# Auf dem TEKO-openSUSE-System funktioniert Listen 443 innerhalb <IfDefine SSL>
# nicht, wenn Apache nicht mit -D SSL gestartet wird. Deshalb wird 443 bewusst
# UNBEDINGT aktiviert. Ein vorhandenes Listen 443 innerhalb <IfDefine SSL> wird
# auskommentiert, damit bei spaeter aktivem SSL-Define kein doppelter Listener
# entsteht.
TMP="$(mktemp "${LISTEN_CONF}.tmp.XXXXXX")"
awk '
BEGIN { in_ssl_define=0; unconditional_443=0 }
{
  line=$0
  if (line ~ /^[[:space:]]*<IfDefine[[:space:]]+SSL[[:space:]]*>/) in_ssl_define=1

  if (in_ssl_define && line ~ /^[[:space:]]*Listen[[:space:]]+443([[:space:]]|$)/) {
    print "        # Listen 443 (TEKO: unconditional listener below)"
    next
  }

  if (!in_ssl_define && line ~ /^[[:space:]]*Listen[[:space:]]+443([[:space:]]|$)/) {
    if (unconditional_443 == 0) {
      print "Listen 443"
      unconditional_443=1
    }
    next
  }

  print line

  if (line ~ /^[[:space:]]*<\/IfDefine[[:space:]]*>/ && in_ssl_define) in_ssl_define=0
}
END {
  if (unconditional_443 == 0) {
    print ""
    print "# TEKO local stack: HTTPS listener"
    print "Listen 443"
  }
}
' "$LISTEN_CONF" > "$TMP"

chown --reference="$LISTEN_CONF" "$TMP"
chmod --reference="$LISTEN_CONF" "$TMP"
mv -f "$TMP" "$LISTEN_CONF"

mkdir -p "$(dirname "$SERVERNAME_CONF")"
printf 'ServerName %s\n' "$SERVER_FQDN" > "$SERVERNAME_CONF"
chmod 0644 "$SERVERNAME_CONF"

if [[ "$SKIP_SERVICE" == "1" ]]; then
  echo "Apache Sandbox-Modus: Service-Steuerung uebersprungen."
  exit 0
fi

systemctl enable apache2

# openSUSE/SLES: a2enmod updates /etc/sysconfig/apache2, but the service's
# pre-start configtest may still evaluate existing TEKO proxy vhosts before
# the freshly enabled proxy modules are available. Temporarily park only the
# TEKO-owned proxy vhosts, start Apache once to synchronize the SUSE module
# state, then restore and validate them. Foreign/admin vhosts are untouched.
teko_sync_vhosts=()
for teko_vhost in /etc/apache2/vhosts.d/forgejo-teko.conf /etc/apache2/vhosts.d/grafana-teko.conf; do
  if [[ -f "$teko_vhost" ]]; then
    teko_tmp="${teko_vhost}.teko-module-sync-disabled"
    mv -f "$teko_vhost" "$teko_tmp"
    teko_sync_vhosts+=("$teko_tmp:$teko_vhost")
  fi
done
restore_teko_sync_vhosts() {
  local pair src dst
  for pair in "${teko_sync_vhosts[@]:-}"; do
    [[ -n "$pair" ]] || continue
    src="${pair%%:*}"; dst="${pair#*:}"
    [[ -f "$src" ]] && mv -f "$src" "$dst" || true
  done
}
trap restore_teko_sync_vhosts EXIT

if ! systemctl restart apache2; then
  restore_teko_sync_vhosts
  echo "Apache Modul-Synchronisation fehlgeschlagen:" >&2
  systemctl status apache2 --no-pager -l || true
  journalctl -u apache2 --no-pager -n 80 || true
  exit 1
fi

# SUSE-native *effective* module verification. start_apache2 reads
# /etc/sysconfig/apache2 exactly like apache2.service does. Direct httpd2 does not.
apache_modules_active() {
  if [[ -x /usr/sbin/start_apache2 ]]; then
    /usr/sbin/start_apache2 -M 2>&1 || true
  else
    a2enmod -l 2>&1 || true
  fi
}

if ! apache_modules_active | grep -Eq 'proxy_module|(^|[[:space:]])proxy([[:space:]]|$)'; then
  restore_teko_sync_vhosts
  echo "FEHLER: Apache-Modul proxy ist nach SUSE-Modulsynchronisation nicht geladen." >&2
  apache_modules_active >&2
  exit 1
fi
if ! apache_modules_active | grep -Eq 'proxy_http_module|(^|[[:space:]])proxy_http([[:space:]]|$)'; then
  restore_teko_sync_vhosts
  echo "FEHLER: Apache-Modul proxy_http ist nach SUSE-Modulsynchronisation nicht geladen." >&2
  apache_modules_active >&2
  exit 1
fi

restore_teko_sync_vhosts
trap - EXIT

# SUSE-native configtest. start_apache2 imports APACHE_MODULES and other
# /etc/sysconfig/apache2 settings. Calling httpd2 directly would ignore them.
apache_configtest() {
  if [[ -x /usr/sbin/start_apache2 ]]; then
    /usr/sbin/start_apache2 -t
  elif [[ -x /usr/sbin/apachectl ]]; then
    /usr/sbin/apachectl configtest
  else
    echo "FEHLER: Kein SUSE-Apache Configtest-Frontend gefunden (start_apache2/apachectl)." >&2
    return 127
  fi
}

# Now validate/reload with the TEKO vhosts back in place.
apache_configtest
systemctl reload apache2

if ! systemctl is-active --quiet apache2; then
  echo "Apache ist nicht aktiv:" >&2
  systemctl status apache2 --no-pager || true
  journalctl -u apache2 --no-pager -n 80 || true
  exit 1
fi

echo "Apache: active"
if ss -lnt | grep -qE '(^|[[:space:]])[^ ]*:443[[:space:]]'; then
  echo "HTTPS Listener :443: OK"
else
  echo "FEHLER: Apache lauscht nicht auf 443." >&2
  ss -lntp || true
  exit 1
fi
