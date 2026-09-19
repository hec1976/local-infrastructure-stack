#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
js=(root/'config-manager-standalone/public/assets/mmbb-feedback.js').read_text()
inc=(root/'config-manager-standalone/standalone/layout/includes/js.php').read_text()
css=(root/'config-manager-standalone/public/assets/standalone.css').read_text()
assert 'window.mmbbNotify' in js
assert 'window.alert = function' in js
assert 'confirm()/prompt()' in js
assert 'mmbb-feedback.js?v=' in inc
assert '.mmbb-feedback-toast' in css
print('portal_feedback_test: PASS')
