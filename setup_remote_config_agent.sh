#!/bin/bash
# TEKO Remote Config-Agent provisioning for openSUSE Leap.
# Required:
#   CONFIG_MANAGER_IP=192.0.2.10
# Optional:
#   CONFIG_AGENT_BIND_IP=<auto-detected>
#   CONFIG_AGENT_FQDN=<hostname -f>
#   CONFIG_AGENT_PORT=5008
#   CONFIG_AGENT_SOURCE=./config-agent
#
# Security:
# - Agent listens only on the selected network IP.
# - API ACL allows only manager /32 plus local loopback.
# - firewalld, if active, gets a source-specific rich rule only.
# - TLS cert SAN contains FQDN + bind IP + loopback.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MANAGER_IP="${CONFIG_MANAGER_IP:-}"
PORT="${CONFIG_AGENT_PORT:-5008}"
SOURCE="${CONFIG_AGENT_SOURCE:-$ROOT/config-agent}"
MANAGER_FQDN="${CONFIG_MANAGER_FQDN:-config-manager.local}"
FORGEJO_FQDN="${FORGEJO_FQDN:-git.local}"
GRAFANA_FQDN="${GRAFANA_FQDN:-grafana.local}"
FORGEJO_TOKEN_SOURCE="${CONFIG_AGENT_FORGEJO_TOKEN_FILE:-}"

if [[ $EUID -ne 0 ]]; then echo "Bitte als root/sudo ausführen." >&2; exit 1; fi
if [[ -z "$MANAGER_IP" ]]; then echo "CONFIG_MANAGER_IP ist zwingend erforderlich." >&2; exit 1; fi
python3 - "$MANAGER_IP" <<'PY'
import ipaddress,sys
ipaddress.ip_address(sys.argv[1])
PY

BIND_IP="${CONFIG_AGENT_BIND_IP:-$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)}"
detect_local_fqdn() {
  local h=""
  if command -v hostname >/dev/null 2>&1; then
    h="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  fi
  if [[ -z "$h" ]] && command -v hostnamectl >/dev/null 2>&1; then
    h="$(hostnamectl --static 2>/dev/null || true)"
  fi
  if [[ -z "$h" && -r /etc/hostname ]]; then
    IFS= read -r h < /etc/hostname || true
  fi
  if [[ -z "$h" ]]; then
    h="$(uname -n 2>/dev/null || true)"
  fi
  printf '%s\n' "$h"
}
FQDN="${CONFIG_AGENT_FQDN:-$(detect_local_fqdn)}"
if [[ -z "$BIND_IP" ]]; then echo "Keine globale IPv4-Adresse erkannt; CONFIG_AGENT_BIND_IP setzen." >&2; exit 1; fi
python3 - "$BIND_IP" <<'PY'
import ipaddress,sys
ipaddress.ip_address(sys.argv[1])
PY


# Trust fuer die Control-/Package-Plane: Enrollment laeuft bereits ueber den
# gepinnten SSH-Kanal. Das im Bundle enthaltene Config-Manager-Zertifikat wird
# deshalb als lokale Trust-Anchor installiert. Damit funktionieren das interne
# HTTPS Baseline-RPM-Repository und weitere Manager-Endpunkte ohne TLS-Bypass.
if [[ -s "$ROOT/config-manager-ca.crt" ]]; then
  install -d -o root -g root -m 0755 /etc/pki/trust/anchors
  # Generischer kanonischer Name. Legacy-Datei wird fuer bestehende Systeme
  # entfernt, damit nicht zwei unterschiedliche Manager-Zertifikate parallel
  # im Trust Store liegen.
  install -o root -g root -m 0644 "$ROOT/config-manager-ca.crt" /etc/pki/trust/anchors/infrastructure-config-manager.crt
  rm -f /etc/pki/trust/anchors/teko-config-manager.crt
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates >/dev/null
  elif command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract >/dev/null
  fi
  # Fail closed: der Trust-Anchor muss nach der Reparatur wirklich vorhanden
  # und als X.509 lesbar sein.
  test -s /etc/pki/trust/anchors/infrastructure-config-manager.crt
  openssl x509 -in /etc/pki/trust/anchors/infrastructure-config-manager.crt -noout >/dev/null
  echo "Config-Manager Trust-Anchor aktualisiert."
else
  # Fail closed: ein Repair ohne Trust-Anchor meldete frueher Erfolg, obwohl der
  # Client danach kein internes HTTPS-Repository verifizieren konnte.
  echo "FEHLER: Repair/Enrollment-Bundle enthaelt keinen Config-Manager Trust-Anchor." >&2
  echo "        Auf dem Management-Host setup_config_manager.sh erneut ausfuehren." >&2
  exit 1
fi
# Control-Plane-Namensaufloesung fuer Lab/Standalone-Betrieb:
# Nicht nur "irgendwie aufloesbar", sondern exakt auf die konfigurierte
# Manager-IP pruefen. Ein alter/falscher /etc/hosts-Eintrag darf Git, RPM-Repo
# oder Observability nicht auf den falschen Host schicken. Bei korrektem DNS
# wird /etc/hosts nicht angefasst.
ensure_manager_names(){
  local names=("$MANAGER_FQDN" "$FORGEJO_FQDN" "$GRAFANA_FQDN") name resolved need=0
  for name in "${names[@]}"; do
    [[ -n "$name" ]] || continue
    resolved="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    grep -qw -- "$MANAGER_IP" <<<"$resolved" || need=1
  done
  [[ "$need" == "1" ]] || return 0
  python3 - /etc/hosts "$MANAGER_IP" "${names[@]}" <<'PYHOSTS'
import sys
path,ip,*names=sys.argv[1:]
names={n for n in names if n}
lines=[]
with open(path,encoding='utf-8',errors='replace') as f:
    src=f.readlines()
for raw in src:
    body,sep,comment=raw.rstrip('\n').partition('#')
    parts=body.split()
    if parts and not parts[0].startswith('#'):
        addr=parts[0]; aliases=[x for x in parts[1:] if x not in names]
        if aliases:
            newline='\t'.join([addr]+aliases)
            if sep: newline += ' #'+comment
            lines.append(newline+'\n')
        elif sep and comment.strip():
            lines.append('#'+comment+'\n')
    else:
        lines.append(raw if raw.endswith('\n') else raw+'\n')
lines.append(ip+'\t'+' '.join(sorted(names))+' # managed by config-agent enrollment\n')
tmp=path+'.config-agent.tmp'
with open(tmp,'w',encoding='utf-8') as f: f.writelines(lines)
import os
os.chmod(tmp,0o644); os.replace(tmp,path)
PYHOSTS
}
ensure_manager_names

# Git-Deploy/Upload sollen auf allen Agenten gleich vorbereitet sein. Der
# Service-Token wird beim Enrollment separat ueber SSH uebertragen und nie in
# das oeffentliche Bootstrap-Bundle eingebettet.
if [[ -n "$FORGEJO_TOKEN_SOURCE" && -s "$FORGEJO_TOKEN_SOURCE" ]]; then
  install -d -o root -g root -m 0700 /opt/service/env
  install -o root -g root -m 0600 "$FORGEJO_TOKEN_SOURCE" /opt/service/env/forgejo-api.token
fi

# Reuse hardened base installer first.
# Bei einem normalen Repair/Update bleiben vorhandene Agent-Einstellungen erhalten.
# Enrollment bzw. explizites Force setzt dagegen das Remote-Profil bewusst neu.
APP="/opt/service/config-agent"
HAD_REMOTE_CONFIG=0
[[ -f "$APP/managed_configs.json" ]] && HAD_REMOTE_CONFIG=1
REMOTE_PROFILE_RESET="${CONFIG_AGENT_REMOTE_PROFILE_RESET:-0}"
[[ "${TEKO_FORCE:-0}" == "1" ]] && REMOTE_PROFILE_RESET=1

CONFIG_AGENT_REMOTE_MODE=1 CONFIG_MANAGER_IP="$MANAGER_IP" CONFIG_AGENT_BIND_IP="$BIND_IP" CONFIG_AGENT_FQDN="$FQDN" CONFIG_AGENT_PORT="$PORT" \
CONFIG_AGENT_HOST_ID="${CONFIG_AGENT_HOST_ID:-}" CONFIG_AGENT_LABELS_JSON="${CONFIG_AGENT_LABELS_JSON:-{}}" CONFIG_AGENT_GROUPS_JSON="${CONFIG_AGENT_GROUPS_JSON:-[]}" \
"$ROOT/setup_config_agent.sh" "$SOURCE"

APP="/opt/service/config-agent"
SSL="/opt/service/ssl"
ENV="/opt/service/env"
mkdir -p "$SSL"

# Remote-Agent-Profil:
# - Erstes Enrollment: nur Config-Agent Core verwalten.
# - Normales Repair/Update: vorhandene Remote-Registry unveraendert lassen.
# - Force/Profile-Reset: Registry bewusst auf den Remote-Default zuruecksetzen.
#
# Damit erbt ein Remote-Agent niemals automatisch Apache/Grafana/Postfix oder
# andere Manager-Host-Konfigurationen. Weitere Configs werden spaeter bewusst
# ueber die Config-Manager-GUI auf genau diesem Agenten hinzugefuegt.
if [[ "$HAD_REMOTE_CONFIG" == "0" || "$REMOTE_PROFILE_RESET" == "1" ]]; then
  python3 - "$APP/managed_configs.json" <<'PYREG'
import json, os, sys
path=sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg=json.load(f)
entry=cfg.get("config-agent-global")
if not isinstance(entry, dict):
    raise SystemExit("Remote-Profil kann config-agent-global nicht finden")
e=dict(entry)
e["required"]=True
out={"config-agent-global": e}
tmp=path+".tmp"
with open(tmp,"w",encoding="utf-8") as f:
    json.dump(out,f,indent=2,ensure_ascii=False); f.write("\n")
os.replace(tmp,path)
PYREG
  chmod 0640 "$APP/managed_configs.json"
  echo "Remote-Profil gesetzt: nur config-agent-global"
else
  echo "Remote-Profil beibehalten: vorhandene managed_configs.json wird nicht ueberschrieben."
fi

# TLS-Identitaet:
# - normales Repair/Update: vorhandenes Zertifikat und Private Key behalten.
#   Dadurch bleibt die auf dem Manager gepinnte Agent-CA gueltig.
# - Erstinstallation/Force: Zertifikat bewusst neu erzeugen; der Manager-Repair
#   synchronisiert das neue Zertifikat anschliessend ueber den gepinnten SSH-Kanal.
if [[ ! -s "$SSL/agent.local.crt" || ! -s "$SSL/agent.local.key" || "${TEKO_FORCE:-0}" == "1" ]]; then
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
    -keyout "$SSL/agent.local.key.new" \
    -out "$SSL/agent.local.crt.new" \
    -subj "/CN=${FQDN}" \
    -addext "subjectAltName=DNS:${FQDN},IP:${BIND_IP},IP:127.0.0.1"
  chmod 600 "$SSL/agent.local.key.new"
  chmod 644 "$SSL/agent.local.crt.new"
  mv -f "$SSL/agent.local.key.new" "$SSL/agent.local.key"
  mv -f "$SSL/agent.local.crt.new" "$SSL/agent.local.crt"
  echo "Remote TLS-Zertifikat neu erzeugt."
else
  echo "Remote TLS-Zertifikat beibehalten."
fi

python3 - "$APP/global.json" "$BIND_IP" "$PORT" "$MANAGER_IP" <<'PY'
import json,os,sys
path,bind,port,manager=sys.argv[1:]
with open(path,encoding="utf-8") as f: cfg=json.load(f)
cfg["listen"]=f"{bind}:{port}"
cfg["allowed_ips"]=[f"{manager}/32","127.0.0.1/32"]
tmp=path+".tmp"
with open(tmp,"w",encoding="utf-8") as f:
    json.dump(cfg,f,indent=2,ensure_ascii=False); f.write("\n")
os.replace(tmp,path)
PY
chmod 0640 "$APP/global.json"

# Limit network exposure to the manager when firewalld is active.
if systemctl is-active --quiet firewalld 2>/dev/null; then
  RULE="rule family=ipv4 source address=${MANAGER_IP}/32 port port=${PORT} protocol=tcp accept"
  firewall-cmd --permanent --query-rich-rule="$RULE" >/dev/null 2>&1 || \
    firewall-cmd --permanent --add-rich-rule="$RULE"
  firewall-cmd --reload
fi

systemctl restart config-agent.service
sleep 1
systemctl is-active --quiet config-agent.service

REG="/root/teko-agent-registration"
mkdir -p "$REG"
chmod 700 "$REG"
cp "$SSL/agent.local.crt" "$REG/agent-ca.crt"
chmod 600 "$REG/agent-ca.crt"
TOKEN="$(sed -n 's/^CONFIG_AGENT_API_TOKEN=//p' "$ENV/config-agent.env" | tail -n1)"
printf '%s\n' "$TOKEN" > "$REG/api-token"
chmod 600 "$REG/api-token"

cat > "$REG/server-registry-entry.json" <<EOF
{
  "name": "${FQDN}",
  "url": "https://${BIND_IP}:${PORT}",
  "groups": ["linux", "canary"],
  "labels": {"env": "prod"},
  "token_file": "/opt/service/config-manager/tokens/${FQDN}.token",
  "tls": {
    "verify": true,
    "verify_host": true,
    "ca_file": "/opt/service/config-manager/ca/${FQDN}.crt"
  }
}
EOF
chmod 600 "$REG/server-registry-entry.json"

cat <<EOF

Remote Config-Agent ist aktiv:
  URL:        https://${BIND_IP}:${PORT}
  FQDN:       ${FQDN}
  ACL:        ${MANAGER_IP}/32 + loopback
  Registrierungspaket:
              ${REG}/server-registry-entry.json
              ${REG}/agent-ca.crt
              ${REG}/api-token

Auf dem Manager:
  1. Zertifikat -> /opt/service/config-manager/ca/${FQDN}.crt
  2. Token      -> /opt/service/config-manager/tokens/${FQDN}.token
  3. JSON-Eintrag in /opt/service/config-manager/servers.json aufnehmen
  4. Rechte: CA root:www 0640, Token root:www 0640
EOF
