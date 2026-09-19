from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
mod = (ROOT / 'config-agent/lib/GitUpload.pm').read_text()
simp = (ROOT / 'config-agent/_simplify_git_config.py').read_text()

assert 'enabled api_base_url base_url token_file' in mod
assert "$git_upload_cfg->{api_base_url} // $git_upload_cfg->{base_url}" in mod
assert "git_upload.api_base_url und git_upload.base_url widersprechen sich" in mod
assert "gu.get('api_base_url') or gu.get('base_url')" in simp
print('PASS git_upload.api_base_url runtime compatibility')
