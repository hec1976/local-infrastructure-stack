#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
pb=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
ui=(r/'config-manager-standalone/public/client_baseline.php').read_text()
meta=(r/'baseline-repository/SPECS/client-baseline.spec').read_text()
exp=(r/'baseline-repository/SPECS/monit-prometheus-exporter.spec').read_text()
prep=(r/'baseline-repository/scripts/prepare_repository.sh').read_text()
assert "client-baseline" in pb and "_pb_ensure_baseline_repo" in pb
assert "_pb_install_monit_exporter" not in pb
assert "https://rpm.grafana.com" not in pb
assert "Repository + Baseline-Pakete installieren" not in ui
assert "observability-client" in ui
assert "Requires:       monit" in meta and "Requires:       alloy" in meta and "Requires:       monit-prometheus-exporter" in meta
assert "alloy.service.d/10-infrastructure-baseline.conf" in meta
assert "/usr/bin/monit-prometheus-exporter" in (r/'baseline-repository/SOURCES/monit-prometheus-exporter.service').read_text()
assert "createrepo_c" in prep and "rpmbuild" in prep
assert (r/'baseline-repository/install.sh').is_file()
assert (r/'setup_baseline_repository.sh').is_file()
print('baseline_3160_repository_test: PASS')
