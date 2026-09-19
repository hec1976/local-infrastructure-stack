#!/usr/bin/env python3
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[1]
portal = root / "config-manager-standalone"
public = portal / "public"

# Runtime-facing frontend sources must not reference remote JS/CSS/font assets.
patterns = [
    re.compile(r'<(?:script|link)\b[^>]*(?:src|href)=["\']https?://', re.I),
    re.compile(r'@import\s+(?:url\()?["\']?https?://', re.I),
    re.compile(r'url\(["\']?https?://', re.I),
    re.compile(r'ace\.config\.set\([^)]*https?://', re.I),
]
hits = []
for p in portal.rglob("*"):
    if not p.is_file() or p.suffix.lower() not in {".php",".js",".css",".html"}:
        continue
    text = p.read_text(encoding="utf-8", errors="ignore")
    for pat in patterns:
        for m in pat.finditer(text):
            hits.append((p.relative_to(root), m.group(0)[:200]))

if hits:
    for p, h in hits:
        print(f"REMOTE FRONTEND REF: {p}: {h}", file=sys.stderr)
    raise SystemExit(1)

required = [
    public/"assets/vendor/jquery/jquery.min.js",
    public/"assets/vendor/bootstrap/bootstrap.min.css",
    public/"assets/vendor/bootstrap/bootstrap.bundle.min.js",
    public/"assets/vendor/bootstrap-icons/bootstrap-icons.min.css",
    public/"assets/vendor/inter/inter-local.css",
    public/"assets/vendor/datatables/jquery.dataTables.min.js",
    public/"assets/vendor/datatables/dataTables.bootstrap5.min.css",
    public/"assets/vendor/ace-offline/codemirror.js",
    public/"assets/vendor/ace-offline/ace-local-adapter.js",
]
missing = [str(p.relative_to(root)) for p in required if not p.is_file() or p.stat().st_size == 0]
if missing:
    raise SystemExit("Missing local vendor files: " + ", ".join(missing))

print("offline_frontend_test: PASS")
