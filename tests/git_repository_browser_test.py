from pathlib import Path
root=Path(__file__).resolve().parents[1]
agent=(root/'config-agent/lib/GitUpload.pm').read_text()
page=(root/'config-manager-standalone/public/git_repository.php').read_text()
js=(root/'config-manager-standalone/public/assets/js/git_repository.js').read_text()
nav=(root/'config-manager-standalone/config/module_navigation.json').read_text()
for needle in ["/git_deploy/repositories/:owner/:repository/tree","/git_deploy/repositories/:owner/:repository/file","/git_deploy/repositories/:owner/:repository/commits","/git_deploy/repositories/:owner/:repository/compare","/git_upload/repositories/:owner/:repository/file","MIME::Base64","eq 'PUT'"]:
    assert needle in agent, needle
for needle in ["api==='tree'","api==='file'","api==='commits'","api==='compare'","api==='save'","Git Repository Browser"]:
    assert needle in page, needle
for needle in ['loadTree','loadFile','loadCommits','loadDiff','saveFile','Speichern & Commit']:
    assert needle in js or needle in page, needle
assert 'git_repository' in nav
print('git_repository_browser_test: PASS')
