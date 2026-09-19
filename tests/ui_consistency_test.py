#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CM = ROOT / 'config-manager-standalone'
PUBLIC = CM / 'public'

css_include = (CM / 'standalone/layout/includes/css.php').read_text(encoding='utf-8')
assert 'assets/standalone.css?v=3.21.0' in css_include, 'global standalone.css is not loaded'

shared_pages = [
    'index.php', 'configs_editor.php', 'configdiff.php', 'git_config_editor.php',
    'git_deploy_overview.php', 'git_deploy.php', 'git_upload.php', 'desired_state.php',
    'agent_enrollment.php', 'package_management.php', 'modsecurity.php', 'auditlog.php'
]
for name in shared_pages:
    text = (PUBLIC / name).read_text(encoding='utf-8')
    assert 'module_header.php' in text, f'{name}: shared module header missing'
    assert 'navigation.php' in text, f'{name}: shared navigation missing'
    assert 'sidebar.php' in text, f'{name}: shared sidebar missing'

for name in ['agent_enrollment.php', 'desired_state.php', 'package_management.php', 'modsecurity.php']:
    text = (PUBLIC / name).read_text(encoding='utf-8')
    assert 'container-fluid mmbb-main' not in text, f'{name}: divergent fluid wrapper remains'

for name, duplicate in {
    'agent_enrollment.php': '<h2 class="mb-1">Agent Enrollment</h2>',
    'desired_state.php': '<h2 class="ds-title mb-1">Fleet / Desired State</h2>',
    'package_management.php': '<h2 class="mb-1">Package Management</h2>',
    'modsecurity.php': '<h2 class="mb-1">ModSecurity / OWASP CRS</h2>',
}.items():
    assert duplicate not in (PUBLIC / name).read_text(encoding='utf-8'), f'{name}: duplicate page title'

style = (PUBLIC / 'assets/standalone.css').read_text(encoding='utf-8')
for marker in ['TEKO portal-wide uniformity (3.20.1)', 'mmbb-page-toolbar', '.pm-grid', '.ms-grid', '.ae-grid']:
    assert marker in style, f'shared style marker missing: {marker}'

login = (PUBLIC / 'login.php').read_text(encoding='utf-8')
assert 'assets/standalone.css?v=3.20.3' in login, 'login does not use shared TEKO style'

print('ui_consistency_test: OK')
