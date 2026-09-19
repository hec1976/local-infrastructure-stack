#!/usr/bin/env python3
from pathlib import Path
import json,re
root=Path(__file__).resolve().parents[1]
pm=(root/'config-agent/lib/GitDeploy.pm').read_text(encoding='utf-8')
portal=(root/'config-manager-standalone/public/git_deploy.php').read_text(encoding='utf-8')
js=(root/'config-manager-standalone/public/assets/js/git_deploy.js').read_text(encoding='utf-8')
overview=(root/'config-manager-standalone/public/assets/js/git_deploy_overview.js').read_text(encoding='utf-8')

checks = {
  'stateful preview token': 'sub _create_preview_token',
  'one-use preview consume': 'unlink($file)',
  'preview TTL': 'expires_at',
  'active tree fingerprint': 'active_tree_sha256',
  'config generation binding': 'config_generation',
  'preflight SHA-256 integrity': 'sub _tree_integrity_fingerprint',
  'strict JSON booleans': 'sub _json_bool_or_throw',
  'unknown-key rejection': 'sub _known_keys_or_throw',
  'profile schema validation': 'schema_version',
  'signed commit policy': 'require_signed_commit',
  'safe symlink checks': 'Symlink verlaesst Release',
}
for label,needle in checks.items():
    assert needle in pm, f'{label}: {needle}'

# Preview token must be bound to deployment/commit/target/config and consumed.
verify_block=pm[pm.index('sub _verify_and_consume_preview_token'):pm.index('sub _compare_active_tree_to_commit')]
for needle in ['deployment','to_commit','target_path','config_digest','active_tree_sha256','expires_at','unlink($file)']:
    assert needle in verify_block, needle

# Portal only accepts an explicit per-server preview map.
assert "$diffPreviews = $payload['diff_previews'] ?? []" in portal
assert "$diffPreviews[(string)$idx]" in portal
assert "diff_previews: approvedDiff?.previews || {}" in js
assert "diff_previews: {[String(idx)]" in js
assert "repository_token_required" in overview
assert "Token erforderlich" in overview

# The canonical examples use real JSON booleans and supported schema.
for rel in ['config-agent/example/git_deploy.json.example','config-manager-standalone/config/git_deploy.example.json']:
    data=json.loads((root/rel).read_text())
    assert data.get('schema_version') in (1,2)
    assert isinstance(data.get('profiles'),dict)
print('git_deploy_hardening_test: PASS')
