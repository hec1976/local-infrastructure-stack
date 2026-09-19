#!/usr/bin/env python3
from pathlib import Path
p = Path(__file__).resolve().parents[1] / "bin" / "forgejo-bootstrap-teko.sh"
s = p.read_text(encoding="utf-8")
checks = {
    "team endpoint": 'POST "/orgs/$ORG/teams"' in s,
    "explicit units_map": '"units_map": {' in s,
    "repo.code permission": '"repo.code": sys.argv[2]' in s,
    "no broad all-repo access": '"includes_all_repositories":False' in s,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(("PASS" if v else "FAIL")+": "+k)
raise SystemExit(1 if failed else 0)
