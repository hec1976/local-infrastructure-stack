#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
F="$ROOT/teko-forgejo-local/setup_forgejo_teko.sh"
grep -q 'podman image exists "$FORGEJO_IMAGE"' "$F"
grep -q 'FORGEJO_PULL_RETRIES="${FORGEJO_PULL_RETRIES:-5}"' "$F"
grep -q 'TEKO_FORGEJO_FORCE_PULL="${TEKO_FORGEJO_FORCE_PULL:-0}"' "$F"
grep -q 'Registry-Pull fehlgeschlagen; vorhandenes lokales Forgejo Image wird verwendet' "$F"
echo '[PASS] Forgejo Registry resilience: local-image reuse + retry/backoff + fallback'
