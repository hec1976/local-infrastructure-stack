from pathlib import Path
root=Path(__file__).resolve().parents[1]
page=(root/'config-manager-standalone/public/git_repository.php').read_text()
js=(root/'config-manager-standalone/public/assets/js/git_repository.js').read_text()
css=(root/'config-manager-standalone/public/assets/css/git_repository.css').read_text()
for needle in ['grHistoryToggle','grHistoryCard','grHistoryClose','grAce','Historie']:
    assert needle in page, needle
for needle in ['ace.edit','setHistory','guessMode','setReadOnly','Zeile ${p.row+1}, Spalte ${p.column+1}']:
    assert needle in js, needle
assert 'gr-history-open' in css
assert 'grid-template-columns:minmax(260px,26%) minmax(560px,1fr)' in css
assert 'gr-history-card d-none' in page
print('git_repository_editor_ux_test: PASS')
