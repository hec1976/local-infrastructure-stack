#!/usr/bin/env python3
from pathlib import Path
s=(Path(__file__).resolve().parents[1]/"baseline-repository/scripts/prepare_repository.sh").read_text()
manifest=s.split("<<'PY_MANIFEST'",1)[1].split("PY_MANIFEST",1)[0]
assert "text=True" not in manifest
assert "universal_newlines=True" in manifest
assert "subprocess.check_output" in manifest
print("baseline_3165_python36_manifest_test: PASS")
