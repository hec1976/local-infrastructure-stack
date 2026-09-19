from pathlib import Path
root=Path(__file__).resolve().parents[1]
ui=(root/'config-manager-standalone/public/modsecurity.php').read_text(encoding='utf-8')
css=(root/'config-manager-standalone/public/assets/css/modsecurity.css').read_text(encoding='utf-8')
checks={
 'assistant tab':'Ausnahmen & Custom Rules' in ui,
 'event paste':'id="eventPaste"' in ui,
 'parser':'function parseEventLine()' in ui,
 'builder':'function buildExclusion' in ui,
 'host required':"missing.push('Host')" in ui and "missing.push('URI')" in ui,
 'no global generator':'Globale CRS-Deaktivierungen werden nicht automatisch erzeugt.' in ui,
 'endpoint runtime exclusion':'ctl:ruleRemoveById=' in ui,
 'target option':'ctl:ruleRemoveTargetById=' in ui,
 'generated id range':'1001000' in ui and '1009999' in ui,
 'managed list':'id="managedExclusions"' in ui,
 'expert raw mode':'Expertenmodus / Raw Custom Rules' in ui,
 'visual css':'.ms-builder-grid' in css and '.ms-preview' in css and '.ms-workflow' in css,
}
for k,v in checks.items():
 print(('PASS' if v else 'FAIL'), '-', k)
 if not v: raise SystemExit(1)
print('modsecurity_false_positive_assistant_test: OK')
