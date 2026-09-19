from pathlib import Path
pm=Path('config-agent/lib/ModSecurity.pm').read_text()
ui=Path('config-manager-standalone/public/modsecurity.php').read_text()
checks={
 'tags_array':'tags=>\\@tags' in pm,
 'raw_rule':'raw=>$raw' in pm,
 'blocking_eval_summary':'Request Blocking Evaluation / Anomaly-Score-Auswertung' in pm,
 'rule_kind':'CRS intern' in pm,
 'details_button':'data-details=' in ui,
 'details_modal':'ruleDetailsModal' in ui,
 'original_rule':'Originale CRS-Regel' in ui,
 'summary_field':'r.summary' in ui,
}
for k,v in checks.items():
    if not v: raise SystemExit(f'FAIL {k}')
print('PASS ModSecurity rule details/enrichment')
