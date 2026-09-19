#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
js = (ROOT / 'config-manager-standalone/public/assets/mmbb-feedback.js').read_text()
css = (ROOT / 'config-manager-standalone/public/assets/standalone.css').read_text()
js_inc = (ROOT / 'config-manager-standalone/standalone/layout/includes/js.php').read_text()
css_inc = (ROOT / 'config-manager-standalone/standalone/layout/includes/css.php').read_text()

required_js = [
    'window.mmbbBusyStart',
    'window.mmbbBusyStop',
    'window.fetch = function',
    'window.XMLHttpRequest.prototype.send',
    "document.addEventListener('submit'",
    "document.addEventListener('click'",
    "window.addEventListener('pageshow'",
]
for token in required_js:
    assert token in js, token
for token in ['.mmbb-busy-indicator', '.mmbb-busy-spinner', '@keyframes mmbb-busy-spin']:
    assert token in css, token
assert 'mmbb-feedback.js?v=3.2.1' in js_inc
assert 'standalone.css?v=3.21.0' in css_inc
print('global_busy_indicator_test: OK')
