from pathlib import Path
root=Path(__file__).resolve().parents[1]
pm=(root/'config-agent/lib/ModSecurity.pm').read_text()
ui=(root/'config-manager-standalone/public/modsecurity.php').read_text()
checks={
 'late override path': "mode_override=>'/etc/apache2/conf.d/zz-teko-modsecurity-mode.conf'" in pm,
 'SUSE rcapache2 control': "_ms_run('/usr/sbin/rcapache2',$action)" in pm,
 'override rendered': "SecRuleEngine '.$cfg->{rule_engine}" in pm and '_ms_render_mode_override' in pm,
 'save writes override': '_ms_ensure_mode_override($profile,$cfg)' in pm,
 'runtime dependency scan': '_ms_engine_directives' in pm and 'dependencies=>\\@other' in pm,
 'info exposes runtime': 'runtime=>_ms_runtime_state($profile)' in pm,
 'UI effective mode': 'id="effectiveMode"' in ui,
 'UI dependency state': 'id="dependencyState"' in ui and 'id="dependencyPanel"' in ui,
 'UI renders runtime': 'function renderRuntime(i,c)' in ui,
}
for name,ok in checks.items():
 print(('PASS' if ok else 'FAIL'),'-',name)
 if not ok: raise SystemExit(1)
