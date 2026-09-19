from pathlib import Path
p=Path(__file__).resolve().parents[1]/'config-manager-standalone/public/modsecurity.php'
s=p.read_text(encoding='utf-8')
checks={
 'pre-correlation enrichment': "$k=(string)$e['timestamp_ns'].'|'.(string)$e['rule_id']" in s and 'anonymous duplicates do not leak' in s,
 'summary rules hidden from main list': 'const actionable=EVENTS.filter(e=>!e.meta_rule);' in s,
 'summary count context': 'Summary-Zeilen ausgeblendet' in s,
 'only usable host uri rows': "const usable=actionable.filter(e=>String(e.host||'').trim()&&String(e.uri||'').trim());" in s,
 'stats use actionable': "$('evTopRule').textContent=topValue(usable,'rule_id')" in s,
 'status only open tuned': "text-bg-success\">getunt" in s and "text-bg-danger\">offen" in s,
 'active exception check': "CM-FP-STATUS" in s and 'targetScoped' in s,
 'correlation hint': 'ms-correlation-hint' in s,
}
failed=[k for k,v in checks.items() if not v]
if failed: raise SystemExit('FAILED: '+', '.join(failed))
print('modsecurity_actionable_events_351_test: OK')
