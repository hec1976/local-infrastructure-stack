from pathlib import Path
root=Path(__file__).resolve().parents[1]
tm=(root/'bin/teko-agent-token-manager.py').read_text()
remote=(root/'setup_remote_config_agent.sh').read_text()
checks={
 'canonical CA root': "CA_ROOT='/opt/service/config-manager/ca/'" in tm,
 'SSH cert reader': 'READ_CERT_SCRIPT' in tm and '/opt/service/ssl/agent.local.crt' in tm,
 'atomic CA writer': 'def write_ca(' in tm and "prefix='.agent-ca.'" in tm,
 'registry TLS update': 'def update_registry_tls(' in tm and "'verify_host':True" in tm,
 'sync token and CA': 'tok,srv,ca_path=sync_remote_identity(req,srv)' in tm,
 'repair token and CA': 'Token/TLS-Identitaet konnte nicht synchronisiert werden' in tm,
 'normal repair preserves cert': 'Remote TLS-Zertifikat beibehalten.' in remote,
 'force may regenerate cert': '"${TEKO_FORCE:-0}" == "1"' in remote,
}
for k,v in checks.items():
    if not v: raise SystemExit('FAIL: '+k)
print('agent_tls_identity_sync_test: PASS')
