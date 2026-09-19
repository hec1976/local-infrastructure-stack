from pathlib import Path

s = Path(__file__).resolve().parents[1].joinpath("setup_teko_local.sh").read_text()
assert "prepare_baseline_repo_for_bootstrap" in s
assert "repodata/repomd.xml" in s
assert "file://${local_dir%/}/" in s
assert 'removerepo "$alias"' in s
# Cleanup must run before Forgejo, whose setup performs the first global refresh.
assert s.index("prepare_baseline_repo_for_bootstrap") < s.index('echo ">>> Forgejo installieren"')
print("baseline_3167_bootstrap_repo_hygiene_test: PASS")
