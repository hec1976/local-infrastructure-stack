from pathlib import Path
r=Path(__file__).resolve().parents[1]
post=(r/'setup_postfix_monit.sh').read_text()
exp=(r/'baseline-repository/SOURCES/monit-prometheus-exporter.service').read_text()
pb=(r/'config-agent/lib/PlatformBaseline.pm').read_text()
secret='/var/lib/service/config-agent/secrets/monit-status.env'
assert 'MONIT_SECRET_DIR="/var/lib/service/config-agent/secrets"' in post
assert 'MONIT_SECRET_FILE="$MONIT_SECRET_DIR/monit-status.env"' in post
assert 'MONIT_USER=${MONIT_HTTP_USER}' in post
assert 'MONIT_PASSWORD=${MONIT_HTTP_PASSWORD}' in post
assert 'MONIT_BASELINE="$MONIT_DIR/cm-baseline.monitrc"' in post
assert 'allow ${MONIT_HTTP_USER}:"${MONIT_HTTP_PASSWORD}"' in post
assert 'cat > "$MONIT_BASELINE"' in post
assert f'EnvironmentFile=-{secret}' in exp
assert 'ExecStart=/usr/bin/monit-prometheus-exporter' in exp
assert 'EnvironmentFile=-/var/lib/service/config-agent/secrets/monit-status.env' in exp
assert "package=>'monit-prometheus-exporter'" in pb
assert "unit=>'monit-prometheus-exporter.service'" in pb
print('monit exporter shared credentials 3.15.2: OK')
