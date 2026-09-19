#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

fail=0
ok()   { printf 'OK: %s\n' "$*"; }
bad()  { printf 'ERROR: %s\n' "$*" >&2; fail=1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# Repository dirt that must never be committed.
if find . -type d \( -name .pytest_cache -o -name __pycache__ \) -print -quit | grep -q .; then
    bad "Cache-Verzeichnisse gefunden"
else
    ok "keine Cache-Verzeichnisse"
fi

if find . -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '*.swp' -o -name '*.swo' -o -name '*~' -o -name '*.tmp' -o -name '.tmp.*' -o -name '*.orig' \) -print -quit | grep -q .; then
    bad "generierte/editor/temporaere Artefakte gefunden"
else
    ok "keine Bytecode-/Editor-/Temp-Artefakte"
fi

if find . -maxdepth 1 -type f \( -name 'VALIDATION*.json' -o -name '*_TEST_REPORT*.md' -o -name 'SANDBOX_TEST_REPORT*.md' -o -name 'DEEP_TEST_REPORT*.md' \) -print -quit | grep -q .; then
    bad "historische Validation-/Testreport-Dateien im Root gefunden"
else
    ok "keine historische Root-History"
fi

if find config-manager-standalone/config -maxdepth 1 -type f \
    \( -name 'git_deploy_[0-9_]*.example.json' -o -name 'global_[0-9_]*.example.json' -o -name 'managed_configs_[0-9_]*.example.json' \) \
    -print -quit | grep -q .; then
    bad "versionierte Parallelbeispiele gefunden"
else
    ok "nur kanonische Config-Beispiele"
fi

# Do not allow real private keys or runtime environment/token files.
secret_hits="$(find . -type f \
    \( -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' -o -name '*.token' -o -name '*.env' \) \
    ! -name '*.example' ! -name '*.env.example' ! -name '*.token.example' -print || true)"
if [[ -n "$secret_hits" ]]; then
    printf '%s\n' "$secret_hits" >&2
    bad "moegliche produktive Secret-Dateien gefunden"
else
    ok "keine produktiven Secret-Dateien"
fi

# JSON validation.
if command -v python3 >/dev/null 2>&1; then
    if ! python3 - <<'PY'
import json
from pathlib import Path
bad=[]
for p in Path('.').rglob('*.json'):
    if any(part in {'.git'} for part in p.parts):
        continue
    try:
        with p.open('r', encoding='utf-8') as f:
            json.load(f)
    except Exception as e:
        bad.append((str(p), str(e)))
if bad:
    for p,e in bad:
        print(f'{p}: {e}')
    raise SystemExit(1)
PY
    then
        bad "ungueltiges JSON gefunden"
    else
        ok "JSON Syntax"
    fi
else
    warn "python3 fehlt; JSON-Pruefung uebersprungen"
fi

# Shell syntax.
sh_bad=0
while IFS= read -r -d '' f; do
    if ! bash -n "$f"; then sh_bad=1; fi
done < <(find . -type f -name '*.sh' -print0)
if [[ $sh_bad -ne 0 ]]; then bad "Shell-Syntax"; else ok "Shell-Syntax"; fi

# Python syntax without creating pyc files.
if command -v python3 >/dev/null 2>&1; then
    if ! python3 - <<'PY'
import ast
from pathlib import Path
bad=[]
for p in Path('.').rglob('*.py'):
    try:
        ast.parse(p.read_text(encoding='utf-8'), filename=str(p))
    except Exception as e:
        bad.append((str(p), str(e)))
if bad:
    for p,e in bad:
        print(f'{p}: {e}')
    raise SystemExit(1)
PY
    then
        bad "Python-Syntax"
    else
        ok "Python-Syntax"
    fi
fi

# PHP lint if available.
PHP_BIN="$(command -v php8 || command -v php || true)"
if [[ -n "$PHP_BIN" ]]; then
    php_bad=0
    while IFS= read -r -d '' f; do
        if ! "$PHP_BIN" -l "$f" >/dev/null; then php_bad=1; fi
    done < <(find config-manager-standalone tests -type f -name '*.php' -print0)
    if [[ $php_bad -ne 0 ]]; then bad "PHP-Syntax"; else ok "PHP-Syntax"; fi
else
    warn "PHP CLI fehlt; PHP-Lint uebersprungen"
fi

# Git whitespace check when inside a git work tree.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git diff --check -- .; then ok "Git whitespace check"; else bad "Git whitespace check"; fi
fi

if [[ $fail -ne 0 ]]; then
    echo "Repository-Check: FAILED" >&2
    exit 1
fi

echo "Repository-Check: OK"
