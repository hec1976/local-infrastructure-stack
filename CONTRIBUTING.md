# Contributing

## Vor einer Aenderung

1. Ausgangsstand aktualisieren.
2. eigenen Branch erstellen.
3. Aenderung auf eine fachliche Funktion begrenzen.
4. Tests ergaenzen oder aktualisieren.
5. keine generierten Reports oder Secrets einchecken.

## Technische Regeln

- Shell: `set -euo pipefail` fuer Installations-/kritische Scripts, wo passend.
- JSON: gueltiges JSON, UTF-8, keine Kommentare.
- Secrets: nur Platzhalter in `*.example`.
- Pfade: keine neuen privilegierten Root-Freigaben ohne Begruendung.
- Actions: feste erlaubte Aktionen statt freier Shellstrings.
- Runtime-Daten: nicht im Source-Tree speichern.
- Dokumentation: aktuellen Sollstand beschreiben, keine parallelen historischen
  Kopien erzeugen.

## Vor Commit

```bash
./tools/repo-check.sh
git diff --check
```

## Commit-Nachrichten

Praefixe sind empfohlen:

```text
feat:
fix:
refactor:
hardening:
docs:
test:
```
