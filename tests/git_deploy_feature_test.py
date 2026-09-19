#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
pm=(root/'config-agent/lib/GitDeploy.pm').read_text(encoding='utf-8')
js=(root/'config-manager-standalone/public/assets/js/git_deploy.js').read_text(encoding='utf-8')
php=(root/'config-manager-standalone/public/git_deploy.php').read_text(encoding='utf-8')
ctrl=(root/'config-manager-standalone/Controller/ConfigManagerController.php').read_text(encoding='utf-8')
repo=(root/'config-manager-standalone/Repository/ConfigManagerRepository.php').read_text(encoding='utf-8')

required_pm = [
    "'ls-remote', '--tags'",
    "source_kind=>'tag'",
    "source_kind=>'branch'",
    "merge-base', '--is-ancestor'",
    "Commit entspricht nicht exakt dem erlaubten Ref",
    "_atomic_symlink_switch($target, $new_release)",
    "_write_deploy_status($id, $status)",
    "sub _create_preview_token",
    "sub _verify_and_consume_preview_token",
    "sub _tree_integrity_fingerprint",
    "preflight_integrity",
    "repository_token_required",
]
for needle in required_pm:
    assert needle in pm, needle

# Browser: Preview muss pro Zielserver gespeichert werden; ein einzelnes
# globales Preview-Token ist nicht mehr zulaessig.
for needle in [
    "diff_previews: approvedDiff?.previews || {}",
    "for (const idx of indices)",
    "previews[String(idx)]",
    "diff_previews: {[String(idx)]",
    "loadRestoreReleases(restoreDeployToken)",
    "enrichResultsWithCommitStatus(data.results, deployment, deployToken)",
]:
    assert needle in js, needle
assert "diff_preview_token: approvedDiff?.token" not in js
assert "settingsServerSelect" not in js

# Request-Token fuer Status/History wird nie in einer URL transportiert.
assert "action: 'status'" in js
assert "X-Deploy-Token" in repo
assert "item.tags" in js
assert "item.commit_date" in js
assert "Aktueller freigegebener Ref-Stand" in php
assert "logChange('git_deploy'" in ctrl
assert "logChange('git_restore'" in ctrl
print('git_deploy_feature_test: PASS')
