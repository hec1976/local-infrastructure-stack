#!/usr/bin/env python3
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'observability'/'system-loki-importer.py'
spec=importlib.util.spec_from_file_location('sysloki', p)
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# All common Postfix children must classify as postfix.
for ident in ['postfix/smtpd','postfix/smtp','postfix/qmgr','postfix/cleanup','postfix/pickup','postfix/postscreen','postfix/tlsmgr','postfix/apprelay']:
    job, comp=m.classify({'SYSLOG_IDENTIFIER':ident})
    assert job=='postfix', ident
# Low-cardinality event mapping + queue id stays a field.
event,status,qid=m.postfix_metadata('ABC123DEF: to=<a@b>, relay=x, status=sent (250 ok)','postfix/smtp')
assert (event,status,qid)==('delivery','sent','ABC123DEF')
event,status,qid=m.postfix_metadata('NOQUEUE: reject: RCPT from x: 554 rejected','postfix/smtpd')
assert event=='reject'
assert qid=='NOQUEUE'
assert m.classify({'SYSLOG_IDENTIFIER':'monit'})[0]=='monit'
print('PASS')
