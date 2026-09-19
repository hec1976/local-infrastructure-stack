#!/usr/bin/python3
import json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
v=json.loads((ROOT/'VERSIONS.json').read_text())
(ROOT/'VERSION_STACK').write_text(v['stack']+'\n')
(ROOT/'VERSION').write_text(v['stack']+'\n')
(ROOT/'config-manager-standalone/VERSION').write_text(v['config_manager']+'\n')
(ROOT/'config-agent/VERSION').write_text(v['config_agent']+'\n')
# Runtime agent version and unit descriptions are generated from the canonical source.
p=ROOT/'config-agent/lib/Core.pm'; s=p.read_text(); s=re.sub(r"\$VERSION = '[^']+';",f"$VERSION = '{v['config_agent']}';",s,count=1); p.write_text(s)
for rel in ['config-agent/service/config-agent.service','config-agent/service/config-agent.service.example']:
    p=ROOT/rel; s=p.read_text(); s=re.sub(r'^Description=Config Agent .*$',f"Description=Config Agent {v['config_agent']}",s,flags=re.M); p.write_text(s)
p=ROOT/'config-agent/config-agent.pl'; s=p.read_text(); s=re.sub(r'^# Version .*$',f"# Version {v['config_agent']}",s,flags=re.M); p.write_text(s)
# README current-state block only; historical changelog remains immutable.
p=ROOT/'README.md'; s=p.read_text()
s=re.sub(r'> Aktueller Stand: \*\*Local Infrastructure Stack[^*]*\*\*',f"> Aktueller Stand: **Local Infrastructure Stack {v['stack']}**",s,count=1)
s=re.sub(r'(?m)^Local Infrastructure Stack\s+\d+\.\d+\.\d+$',f"Local Infrastructure Stack       {v['stack']}",s,count=1)
s=re.sub(r'(?m)^Config Agent\s+\d+\.\d+\.\d+$',f"Config Agent                     {v['config_agent']}",s,count=1)
s=re.sub(r'(?m)^Config Manager Standalone\s+\d+\.\d+\.\d+$',f"Config Manager Standalone        {v['config_manager']}",s,count=1)
p.write_text(s)
print(json.dumps(v,indent=2))
