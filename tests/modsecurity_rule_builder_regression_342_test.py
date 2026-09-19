from pathlib import Path
root=Path(__file__).resolve().parents[1]
ui=(root/'config-manager-standalone/public/modsecurity.php').read_text(encoding='utf-8')
checks={
 'real newline in generated rule':'implode("\\n",$lines)' in ui and 'implode("\\\\n",$lines)' not in ui,
 'real newline when appending':'($content!==\'\'?"\\n\\n":\'\')' in ui and '.$gen[\'rule\']."\\n"' in ui,
 'inline builder state':'id="builderState"' in ui,
 'inline generation error':'Rule konnte nicht erzeugt werden:' in ui and 'scopePreview' in ui,
 'auto build errors visible':'await buildExclusion(true);' in ui,
 'buttons explicit type':'id="buildExclusion" type="button"' in ui,
 'static warning not misleading':'Host und URI sind Pflicht.' not in ui,
}
for k,v in checks.items():
 print(('PASS' if v else 'FAIL'), '-', k)
 if not v: raise SystemExit(1)
print('modsecurity_rule_builder_regression_342_test: OK')
