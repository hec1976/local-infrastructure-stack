from pathlib import Path
r=Path(__file__).resolve().parents[1]
pb=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
ui=(r/'config-manager-standalone/public/client_baseline.php').read_text()
go=(r/'monit-exporter/cmd/monit-prometheus-exporter/main.go').read_text()
assert "/baseline/install-job" in pb and "/baseline/job/:id" in pb
assert "progress_percent" in pb and "_pb_run_install_job" in pb
assert "monit-prometheus-exporter-linux-amd64" not in pb
assert "client-baseline" in pb
assert "monit-prometheus-exporter" in pb
assert "127.0.0.1:9108/metrics" in pb
assert 'prometheus.scrape "monit"' in pb
assert "/var/lib/service/config-agent/secrets/monit-status.env" in pb
assert "/etc/systemd/system/monit-prometheus-exporter.service" not in pb
assert "MONIT_USER" in go and "MONIT_PASSWORD" in go
assert "pollPackageJob" not in ui and "installPackages" not in ui
assert "observability-client" in ui
assert "saveAlloy" not in ui
print('OK baseline 3.15.1 async Alloy + Monit exporter')
