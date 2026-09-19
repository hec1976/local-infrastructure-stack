#!/usr/bin/env python3
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'config-manager-standalone/public/modsecurity.php'
s=p.read_text()
css=(Path(__file__).resolve().parents[1]/'config-manager-standalone/public/assets/css/modsecurity.css').read_text()
checks={
 'events api': "($_GET['api']??'')==='events'" in s,
 'loki query': '/loki/api/v1/query_range' in s and 'TEKO_LOKI_QUERY_URL' in s,
 'label fallback': 'service_name="modsecurity"' in s and 'job="modsecurity"' in s,
 'events tab': 'data-bs-target="#waf-events"' in s,
 'event table': 'id="eventsBody"' in s,
 'tune action': 'function tuneEvent(e)' in s,
 'tuned detection': 'function eventIsTuned(e)' in s,
 'visual css': '3.3.0 Security Events / Loki workflow' in css,
}
for k,v in checks.items():
 print(('PASS' if v else 'FAIL')+' - '+k)
 if not v: raise SystemExit(1)
print('modsecurity_security_events_test: OK')
