from pathlib import Path
p=Path(__file__).resolve().parents[1]/"config-manager-standalone/public/modsecurity.php"
s=p.read_text(encoding="utf-8")
checks={
 "meta helper":"function ms_is_meta_rule",
 "980170 protected":"'980170'",
 "root correlation":"root_event",
 "summary hidden from main":"const actionable=EVENTS.filter(e=>!e.meta_rule);",
 "summary not direct":"darf nicht direkt ausgenommen werden",
 "loading feedback":"Rule wird gebaut",
 "neutral fp marker":"# CM-FP:",
}
for name,needle in checks.items():
    assert needle in s, f"missing {name}: {needle}"
print("modsecurity_meta_rule_correlation_test: OK")
