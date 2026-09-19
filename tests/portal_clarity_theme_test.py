from pathlib import Path

root = Path(__file__).resolve().parents[1]
css = (root / "config-manager-standalone/public/assets/standalone.css").read_text(encoding="utf-8")
inc = (root / "config-manager-standalone/standalone/layout/includes/css.php").read_text(encoding="utf-8")

required = [
    "Portal clarity / contrast pass (3.20.3)",
    "--mmbb-bg: #e8ecf2",
    "--mmbb-border: #aeb8c8",
    ".mmbb-sidebar .nav-link.active",
    ".mmbb-content .table thead th",
    ".form-control::placeholder",
    ".btn-outline-secondary",
]
for marker in required:
    assert marker in css, marker
assert 'standalone.css?v=' in inc
print("portal_clarity_theme_test: PASS")
