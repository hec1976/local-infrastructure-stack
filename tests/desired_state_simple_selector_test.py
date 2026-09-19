from pathlib import Path
root=Path(__file__).resolve().parents[1]
page=(root/"config-manager-standalone/public/desired_state_editor.php").read_text()
checks={
    "modes": all(x in page for x in ["Alle Server","Nach Gruppen","Nach Labels","Erweitert"]),
    "group_chips": "groupChips" in page and "data-group" in page,
    "label_chips": "labelChips" in page and "data-label-key" in page,
    "default_or": "group_match:'any'" in page and "Mindestens eine Gruppe" in page,
    "live_preview": "Passende Server" in page and "previewTargets" in page,
    "legacy_advanced": "inferSelectorMode" in page and "advancedSelectorBox" in page,
}
for k,v in checks.items(): print(("PASS" if v else "FAIL"),k)
assert all(checks.values())
