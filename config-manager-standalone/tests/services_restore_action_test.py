from pathlib import Path

page = Path('public/index.php').read_text(encoding='utf-8')
css = Path('public/assets/css/index.css').read_text(encoding='utf-8')

assert 'class="btn btn-outline-warning btn-sm mmbb-btn mmbb-btn-warning restore-row-btn ms-1"' in page
assert '<i class="bi bi-clock-history"></i><span>Backups / Restore</span>' in page
assert 'data-bs-target="#backupModal<?= $cid_html ?>"' in page
assert "name=\"action\" value=\"restore_backup\"" in page
assert 'if (!empty($backups))' in page  # Modal-Inhalt unterscheidet Backups/Leerzustand weiter sauber.
assert '.table-actions .restore-row-btn' in css

# Regression: Der Restore-Einstieg darf nicht mehr selbst durch vorhandene Backups bedingt sein.
needle = '<!-- Restore / Backups: immer sichtbar'
start = page.index(needle)
end = page.index('</td>', start)
row_action = page[start:end]
assert '<?php if (!empty($backups)): ?>' not in row_action

print('services_restore_action_test: PASS')
