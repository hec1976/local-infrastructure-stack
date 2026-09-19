from pathlib import Path
root=Path(__file__).resolve().parents[1]
idx=(root/'config-manager-standalone/public/index.php').read_text()
assert "tekoConfigManagerServiceLog" in idx
assert "width=1440,height=880" in idx
assert "window.open('', '_blank'" not in idx
assert "Dieses Fenster wird für weitere Log-Aufrufe wiederverwendet." in idx
print('ui_log_single_window_test: PASS')
