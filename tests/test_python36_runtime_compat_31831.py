from pathlib import Path
import py_compile

ROOT = Path(__file__).resolve().parents[1]

def test_no_universal_newlines_in_tempfile_calls():
    bad=[]
    needle = "universal_" + "newlines="
    for p in ROOT.rglob("*.py"):
        if p == Path(__file__):
            continue
        text=p.read_text(errors="replace")
        for n,line in enumerate(text.splitlines(),1):
            if "tempfile.mkstemp" in line and needle in line:
                bad.append(f"{p}:{n}:{line}")
    assert not bad, "\n".join(bad)

def test_runtime_scripts_compile():
    for rel in [
        "bin/teko-observability-auth-sync.py",
        "bin/teko-server-registry-write.py",
        "bin/teko-agent-enrollment-worker.py",
        "bin/teko-agent-token-manager.py",
    ]:
        py_compile.compile(str(ROOT / rel), doraise=True)
