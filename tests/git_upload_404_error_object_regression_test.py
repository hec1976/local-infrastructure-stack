#!/usr/bin/env python3
"""Regression test for GitUploadError object handling around Forgejo 404s."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
pm = (root / 'config-agent/lib/GitUpload.pm').read_text(encoding='utf-8')

# _gu_fail throws a blessed object, therefore all regex decisions on caught
# errors must first extract the object's message with _gu_error_message().
assert "my $err_msg = _gu_error_message($err);" in pm
assert "$err_msg !~ /Forgejo API HTTP 404|nicht gefunden|Not Found/i" in pm
assert "my $e_msg = _gu_error_message($e);" in pm
assert "$e_msg =~ /Forgejo API HTTP 404/i" in pm

# Guard against reintroducing the original bug.
assert "$err && $err !~ /Forgejo API HTTP 404" not in pm
assert "if ($e =~ /Forgejo API HTTP 404/i)" not in pm

print('git_upload_404_error_object_regression_test: PASS')
