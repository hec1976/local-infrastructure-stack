from pathlib import Path
r=Path(__file__).resolve().parents[1]
boot=(r/'bin/bootstrap-observability-deploy-profile.sh').read_text()
obs=(r/'setup_observability.sh').read_text()
audit=(r/'config-manager-standalone/public/api/audit_export.php').read_text()
assert 'CONFIG_MANAGER_RUNTIME_USER="${CONFIG_MANAGER_RUNTIME_USER:-wwwrun}"' in boot
assert 'CONFIG_MANAGER_RUNTIME_GROUP="${CONFIG_MANAGER_RUNTIME_GROUP:-www}"' in boot
assert 'install -d -o "$CONFIG_MANAGER_RUNTIME_USER" -g "$CONFIG_MANAGER_RUNTIME_GROUP" -m 0770 "$DATA_DIR"' in boot
assert 'chown "$CONFIG_MANAGER_RUNTIME_USER:$CONFIG_MANAGER_RUNTIME_GROUP" "$FILE"' in boot
assert 'chown wwwrun:www "$(dirname "$CM_ENV")" "$CM_ENV"' in obs
assert 'chmod 0770 "$(dirname "$CM_ENV")"' in obs
# Missing credentials must be rejected before configuration state is disclosed.
pos_auth=audit.index("audit_export_fail(401, 'Unauthorized')")
pos_cfg=audit.index("audit_export_fail(503, 'Audit export is not configured')")
assert pos_auth < pos_cfg
print('runtime ownership 3.17.1: PASS')
