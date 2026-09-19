#!/bin/bash
# Regressionstest 3.18.20: kompakte UI trennt Zonen-Zuordnung und Firewall-Freigaben.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
UI="$ROOT/config-manager-standalone/public/firewall.php"
fail(){ echo "FAIL: $1" >&2; exit 1; }

grep -q '>Zone bearbeiten<' "$UI" || fail "zentrale Zonenauswahl fehlt"
grep -q 'zoneNicPick' "$UI" || fail "Interface-Auswahl fehlt"
grep -q 'zoneSourceIp' "$UI" || fail "Netz-Zuordnung fehlt"
grep -q 'zoneSourceAdd' "$UI" || fail "Netz kann nicht zugewiesen werden"
grep -q '>Freigabe hinzufügen<' "$UI" || fail "Freigabe-Editor fehlt"
# Quelle/Netz darf nicht mehr als normale Freigabe erscheinen.
if grep -q 'data-kind="source"' "$UI"; then fail "Quelle/Netz wird noch als Freigaberegel angeboten"; fi
# public darf nicht mehr kuenstlich in die Zonenliste injiziert werden.
if grep -q "filter(Boolean),'public'" "$UI"; then fail "public wird weiterhin kuenstlich ergaenzt"; fi
grep -q 'unbenutzte Systemzonen sind ausgeblendet' "$UI" || fail "Systemzonen-Filter ist nicht erklaert"
grep -q 'Eigene Zone löschen' "$UI" || fail "Loeschaktion fuer eigene Zonen fehlt"
grep -q 'Systemzonen werden nicht gelöscht' "$UI" || fail "Systemzonen-Verhalten ist nicht erklaert"
php -l "$UI" >/dev/null || fail "PHP-Syntaxfehler"
python3 - "$UI" <<'PY'
import sys,re,subprocess,tempfile,pathlib
s=pathlib.Path(sys.argv[1]).read_text()
js=s.split('<script>',1)[1].split('</script>',1)[0].replace('<?=json_encode($csrf)?>','"TEST"')
f=tempfile.NamedTemporaryFile('w',suffix='.js',delete=False)
f.write(js); f.close()
r=subprocess.run(['node','--check',f.name],capture_output=True,text=True)
if r.returncode:
    print(r.stderr,file=sys.stderr); raise SystemExit(1)
PY
echo PASS
