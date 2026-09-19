#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
boot=(root/'bin/forgejo-bootstrap-teko.sh').read_text()
gu=(root/'config-agent/lib/GitUpload.pm').read_text()
assert 'write:repository,write:organization,read:user' in boot
assert 'TOKEN_CAPABILITY_VERSION="3"' in boot
assert 'TOKEN_META_FILE="${TOKEN_FILE}.meta"' in boot
# Existing restricted service users must be migrated to a normal non-admin automation user.
assert '"restricted":false' in boot
assert 'normaler Non-Admin Automation-User' in boot
# Forgejo 15+ repository-scoped PATs must explicitly permit all repositories when supported.
assert 'TOKEN_REPO_ARGS=(--repo all)' in boot
# Bootstrap must exercise the exact create endpoint with the final service token.
# Cleanup must use the temporary bootstrap-admin token via api_call, not the service token.
assert 'Service-Token Repository-Create End-to-End pruefen' in boot
assert '"$API_BASE/orgs/$ORG/repos"' in boot
assert 'api_call DELETE "/repos/$ORG/$probe_repo"' in boot
assert 'Authorization: token $SERVICE_TOKEN' in boot
assert 'Repository-Erstellung: OK (Create 201; Cleanup via Bootstrap-Admin)' in boot
assert 'teko-capability-probe-' in boot
# Runtime create path verifies current-user org membership without relying on the visibility-sensitive
# user/org permission endpoint, then uses the canonical Forgejo create-org-repo endpoint.
assert "'/api/v1/user/orgs?limit=100'" in gu
assert "'/api/v1/orgs/' . url_escape($owner) . '/repos'" in gu
assert 'Capability-Probe' in gu
print('forgejo_repo_create_auth_test: PASS')
