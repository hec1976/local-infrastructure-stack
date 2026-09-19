#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
pm=(root/'config-agent/lib/GitUpload.pm').read_text(encoding='utf-8')
repo=(root/'config-manager-standalone/Repository/ConfigManagerRepository.php').read_text(encoding='utf-8')
for needle in [
    'sub _gu_validate_config_shape',
    'Unbekanntes git_upload-Feld',
    'sub _gu_bool_value',
    'muss boolean sein',
    'sub _gu_uint_strict',
    "get '/git_deploy/repositories'",
    "get '/git_deploy/repositories/:owner/:repository/branches'",
    "get '/git_deploy/repositories/:owner/:repository/scan'",
    'sub _gu_safe_relative_symlink',
    'Symlink verlaesst Repository',
    'sub _gu_create_repository',
    "post '/git_upload/repositories/create'",
    'Repository existiert bereits',
    'repository_create=>true()',
]:
    assert needle in pm, needle
assert '_gu_repositories($force, 0)' in pm
assert '_gu_require_ready(); _gu_repositories($force, 1)' in pm
# New agents use read-only deploy routes; upload routes remain a 404-only legacy fallback.
assert "'/git_deploy/repositories'" in repo
assert "'/git_upload/repositories'" in repo
assert 'getErrorCode() !== 404' in repo
print('git_upload_hardening_test: PASS')

portal=(root/'config-manager-standalone/public/git_upload.php').read_text(encoding='utf-8')
js=(root/'config-manager-standalone/public/assets/js/git_upload.js').read_text(encoding='utf-8')
for needle in ['create_repository', 'gitUploadCreateRepo', 'Repository erstellen und auswählen']:
    assert needle in portal or needle in js, needle

assert 'Neues Repository' in portal
assert 'git_upload.js?v=3.0.22' in portal
assert portal.count('id="gitUploadCreateRepoToggle"') == 1

assert "state.branches.length === 0" in js
assert "state.repository.default_branch || 'main'" in js
