#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
ui=(root/'config-manager-standalone/public/modsecurity.php').read_text(encoding='utf-8')
css=(root/'config-manager-standalone/public/assets/css/modsecurity.css').read_text(encoding='utf-8')
checks={
 'server side generator':'function ms_generate_exclusion' in ui,
 'generator endpoint':"$action==='generate_exclusion'" in ui,
 'one click activation':"$action==='activate_exclusion'" in ui and 'id="activateExclusion"' in ui,
 'automatic strategy':"$strategy=$targetOk?'target':'endpoint'" in ui,
 'target allowlist':'REQUEST_FILENAME|REQUEST_URI|REQUEST_BASENAME' in ui,
 'host and uri validation':'Host fehlt oder ist ungültig.' in ui and 'URI fehlt oder ist ungültig.' in ui,
 'custom id collision check':'ms_custom_next_id' in ui and '1001000' in ui and '1009999' in ui,
 'security events first':'id="eventsTab" class="nav-link active"' in ui,
 'expert separated':'data-bs-target="#waf-expert"' in ui,
 'compact runtime':'id="runtimeToggle"' in ui and '.ms-statusbar' in css,
 'auto layout':'.ms-auto-grid' in css and 'Automatischer Rule Builder' in ui,
}
for k,v in checks.items():
 print(('PASS' if v else 'FAIL'),'-',k)
 if not v: raise SystemExit(1)
print('modsecurity_auto_rule_builder_test: OK')
