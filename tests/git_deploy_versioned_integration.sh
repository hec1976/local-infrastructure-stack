#!/bin/bash
set -euo pipefail

fail(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }

command -v git >/dev/null || fail "git fehlt"
command -v tar >/dev/null || fail "tar fehlt"

T="$(mktemp -d /tmp/teko-git-deploy-int.XXXXXX)"
trap 'rm -rf "$T"' EXIT

SRC="$T/src"
ORIGIN="$T/origin.git"
CACHE="$T/cache.git"
RELEASES="$T/releases"
TARGET="$T/current"
mkdir -p "$SRC" "$RELEASES"

git -C "$SRC" init -q
git -C "$SRC" config user.email tester@teko.local
git -C "$SRC" config user.name 'TEKO Test'
git -C "$SRC" checkout -q -b main

mkdir -p "$SRC/bin" "$SRC/conf"
printf '#!/bin/sh\necho v1\n' > "$SRC/bin/job.sh"
printf 'mode=v1\n' > "$SRC/conf/app.conf"
chmod 755 "$SRC/bin/job.sh"
git -C "$SRC" add .
git -C "$SRC" commit -q -m 'release v1'
C1="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" tag -a v1.0.0 -m 'v1.0.0'

printf '#!/bin/sh\necho v2\n' > "$SRC/bin/job.sh"
printf '#!/bin/sh\necho new-script\n' > "$SRC/bin/new_job.sh"
chmod 755 "$SRC/bin/new_job.sh"
git -C "$SRC" add .
git -C "$SRC" commit -q -m 'release v2 with new script'
C2="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" tag v1.1.0

git -C "$SRC" checkout -q -b forbidden
printf '#!/bin/sh\necho forbidden\n' > "$SRC/bin/evil.sh"
git -C "$SRC" add .
git -C "$SRC" commit -q -m 'not approved branch'
BAD="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" checkout -q main

git clone -q --bare "$SRC" "$ORIGIN"
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main

git init -q --bare "$CACHE"
git --git-dir="$CACHE" fetch -q --force --no-tags "$ORIGIN" refs/heads/main:refs/config-manager/test-main
HEAD="$(git --git-dir="$CACHE" rev-parse 'refs/config-manager/test-main^{commit}')"
[[ "$HEAD" == "$C2" ]] || fail "Branch-Head nicht C2"
ok "allowed_ref Branch-Head korrekt"

git --git-dir="$CACHE" merge-base --is-ancestor "$C1" refs/config-manager/test-main
ok "älterer freigegebener Commit ist Branch-Ancestor"

if git --git-dir="$CACHE" cat-file -e "$BAD^{commit}" 2>/dev/null; then
  if git --git-dir="$CACHE" merge-base --is-ancestor "$BAD" refs/config-manager/test-main 2>/dev/null; then
    fail "Fremd-Commit wurde als Ancestor akzeptiert"
  fi
fi
ok "Fremd-Commit ausserhalb allowed_ref wird nicht freigegeben"

# Tag-Metadaten wie im Agenten: annotated Tag muss über ^{} auf Commit zeigen.
TAGLIST="$T/tags.txt"
git ls-remote --tags "$ORIGIN" > "$TAGLIST"
grep -q "refs/tags/v1.0.0\^{}" "$TAGLIST" || fail "annotated Tag peel fehlt"
grep -q "refs/tags/v1.1.0$" "$TAGLIST" || fail "lightweight Tag fehlt"
TAG1="$(awk '$2=="refs/tags/v1.0.0^{}"{print $1}' "$TAGLIST")"
TAG2="$(awk '$2=="refs/tags/v1.1.0"{print $1}' "$TAGLIST")"
[[ "$TAG1" == "$C1" ]] || fail "v1.0.0 zeigt nicht auf C1"
[[ "$TAG2" == "$C2" ]] || fail "v1.1.0 zeigt nicht auf C2"
ok "annotated und lightweight Tags werden korrekt Commit-Versionen zugeordnet"

# Exact Tag Ref wie im Agenten separat fetchen und prüfen.
git --git-dir="$CACHE" fetch -q --force --no-tags "$ORIGIN" refs/tags/v1.0.0:refs/config-manager/test-tag
EXACT="$(git --git-dir="$CACHE" rev-parse 'refs/config-manager/test-tag^{commit}')"
[[ "$EXACT" == "$C1" ]] || fail "Exact-Tag-Auflösung falsch"
SHOW_EXACT="$(git --git-dir="$CACHE" show -s --format='%H' 'refs/config-manager/test-tag^{commit}')"
[[ "$SHOW_EXACT" == "$C1" ]] || fail "Exact-Tag-Metadaten wurden nicht vom Commit gelesen"
ok "exact Tag-Profil löst auf exakten Commit auf"

make_release(){
  local commit="$1" dest="$2"
  mkdir -p "$dest"
  git --git-dir="$CACHE" archive --format=tar "$commit" | tar -xf - -C "$dest"
  printf '%s\n' "$commit" > "$dest/.config-agent-commit"
}

R1="$RELEASES/${C1}-v1"
R2="$RELEASES/${C2}-v2"
make_release "$C1" "$R1"
[[ -x "$R1/bin/job.sh" ]] || fail "v1 job.sh fehlt"
[[ ! -e "$R1/bin/new_job.sh" ]] || fail "new_job.sh darf in v1 nicht existieren"
ln -s "$R1" "$T/.current.new"
mv -T "$T/.current.new" "$TARGET"
[[ "$(cat "$TARGET/.config-agent-commit")" == "$C1" ]] || fail "Erstdeploy falsch"
ok "Erstdeploy auf Commit v1"

make_release "$C2" "$R2"
[[ -x "$R2/bin/new_job.sh" ]] || fail "neues Skript wurde nicht aus Git-Release extrahiert"
ln -s "$R2" "$T/.current.new"
mv -T "$T/.current.new" "$TARGET"
[[ "$(cat "$TARGET/.config-agent-commit")" == "$C2" ]] || fail "Update falsch"
[[ "$("$TARGET/bin/job.sh")" == "v2" ]] || fail "v2 Skriptinhalt falsch"
[[ "$("$TARGET/bin/new_job.sh")" == "new-script" ]] || fail "neues Skript nicht ausführbar"
ok "Update verteilt geändertes und neues Skript atomar"

# Manueller Rollback auf bekannte vorherige Release-Version.
ln -s "$R1" "$T/.current.new"
mv -T "$T/.current.new" "$TARGET"
[[ "$(cat "$TARGET/.config-agent-commit")" == "$C1" ]] || fail "Rollback falsch"
[[ "$("$TARGET/bin/job.sh")" == "v1" ]] || fail "Rollback-Inhalt falsch"
[[ ! -e "$TARGET/bin/new_job.sh" ]] || fail "Rollback hat v2-Datei behalten"
ok "Rollback auf vorherigen Commit funktioniert"

# Alter Release bleibt für Wiederherstellung erhalten.
[[ -d "$R2" && -f "$R2/.config-agent-commit" ]] || fail "v2 Release fehlt nach Rollback"
ok "Release-Historie bleibt für erneutes Deployment erhalten"

echo "=== RESULT: PASS ==="
