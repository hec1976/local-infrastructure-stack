#!/usr/bin/env python3
"""Regression: freshly created empty Forgejo repositories have no branch JSON body."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
pm=(root/'config-agent/lib/GitUpload.pm').read_text(encoding='utf-8')
assert "my ($method, $path, $body, $opts) = @_;" in pm
assert "$raw !~ /\\S/ || $raw =~ /^\\s*null\\s*$/i" in pm
assert "{empty_json=>[]}" in pm
assert "Forgejo API lieferte kein gueltiges JSON ($method $path, HTTP $code)" in pm
assert "Forgejo Branch-Antwort ist kein Array" in pm
assert "stage=>'git_upload_init'" in pm and "'init', '-b', $branch" in pm
js=(root/'config-manager-standalone/public/assets/js/git_upload.js').read_text(encoding='utf-8')
assert "state.repository && state.branches.length === 0" in js
assert "state.repository.default_branch || 'main'" in js
print('git_upload_empty_repo_branches_test: PASS')
