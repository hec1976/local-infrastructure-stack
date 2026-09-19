# Git-Workflow

## Ziel

Das Repository soll einen reproduzierbaren aktuellen Stand enthalten, nicht den
Muell vergangener Testlaeufe. Historie gehoert in Git-Commits und Tags, nicht in
Dateinamen wie `VALIDATION_v2.7.3.json` oder `FIX_v2.9.2.md`.

## Initiales Repository

```bash
git init -b main
git add .
git commit -m "Initial clean TEKO Local Stack baseline"
```

Forgejo:

```bash
git remote add origin https://git.local/teko/teko-local-stack.git
git push -u origin main
```

## Branch-Namen

Empfehlung:

```text
feature/<thema>
fix/<thema>
hardening/<thema>
refactor/<thema>
docs/<thema>
```

Beispiele:

```text
fix/services-configs-actions
hardening/git-deploy-path-guard
feature/agent-enrollment
```

## Commit-Regeln

Ein Commit soll eine nachvollziehbare technische Aenderung enthalten.

Gute Beispiele:

```text
fix: return service metadata from /configs
fix: allow configured legacy deploy roots
refactor: consolidate config examples
hardening: reject protected system paths
```

Nicht verwenden:

```text
update
new version
fix stuff
final final 2
```

## Tags

Releases koennen als Git-Tags markiert werden:

```bash
git tag -a v3.0.9 -m "TEKO Local Stack 3.0.9"
git push origin v3.0.9
```

Ein Release-Tag ersetzt separate historische JSON-/Markdown-Statusdateien im
Repository-Root.

## Vor jedem Push

```bash
./tools/repo-check.sh
```

Fuer groessere Aenderungen zusaetzlich:

```bash
./tests/sandbox_test.sh
```

Danach:

```bash
git status --short
git diff --check
git diff --cached
```

## Secrets

Niemals committen:

- echte API-Tokens
- Forgejo-Tokens
- Passwoerter
- private TLS-/SSH-Keys
- `config-manager.env`
- `users.json`
- Audit-DB

Nur `*.example`-Dateien mit klaren Platzhaltern gehoeren ins Repository.
