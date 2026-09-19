#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=(root/"config-manager-standalone/public/desired_state.php").read_text()
for needle in [
    "Gesamt Server","Compliant","Drift","Fehler / Offline","Policies",
    "Server suchen","Alle Gruppen","Alle Labels","Nur Abweichungen",
    "Baseline Details","Aktuelle Compliance-Verteilung","data-detail",
    "data-enforce","server_idx","server_url","checked_at",
    "Check only","Drift beheben"
]:
    assert needle in p, needle
assert "Server ist kein gueltiges Ziel dieser Policy." in p
assert "array_key_exists($serverIdx, $targets)" in p
assert "fetch(url,{cache:'no-store'" in p
assert "http://" not in p.split("<!DOCTYPE html>",1)[1]
assert "https://" not in p.split("<!DOCTYPE html>",1)[1]
print("fleet_dashboard_gui_test: OK")
