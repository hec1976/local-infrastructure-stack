from pathlib import Path
root=Path(__file__).resolve().parents[1]
s=(root/'bin/forgejo-bootstrap-teko.sh').read_text()
conf=(root/'teko-stack.conf').read_text()
master=(root/'setup_teko_local.sh').read_text()
forge=(root/'teko-forgejo-local/setup_forgejo_teko.sh').read_text()
globalj=(root/'config-agent/example/global.json.example').read_text()
checks={
 'org default':'FORGEJO_ORG:-teko' in conf,
 'repo default':'FORGEJO_REPO:-config-deploy' in conf,
 'team default':'FORGEJO_TEAM:-teko-deploy' in conf,
 'service user default':'FORGEJO_SERVICE_USER:-svc-teko-deploy' in conf,
 'service user create':'admin user create' in s and '"restricted":false' in s,
 'org api':'/orgs/$ORG' in s,
 'repo api':'/orgs/$ORG/repos' in s,
 'team api':'/orgs/$ORG/teams' in s,
 'team member':'/teams/$TEAM_ID/members/$SERVICE_USER' in s,
 'team repo':'/teams/$TEAM_ID/repos/$ORG/$REPO' in s,
 'scoped token':'write:repository,write:organization,read:user' in s,
 'root-only token':'chmod 0600' in s and '/opt/service/env/forgejo-api.token' in s,
 'scaffold':'configs/postfix/.gitkeep' in s and 'profiles/.gitkeep' in s and 'manifests/README.md' in s,
 'installer calls bootstrap':'forgejo-bootstrap-teko.sh' in forge,
 'master recognizes auto token':'Service-Token wurde vom TEKO Forgejo-Bootstrap' in master,
 'upload owner restricted':'"allowed_owners": [' in globalj and '"teko"' in globalj,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'), '-', k)
if failed: raise SystemExit('failed: '+', '.join(failed))
