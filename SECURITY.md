# Security

## Schwachstellen melden

Sicherheitsluecken, exponierte Zugangsdaten und moegliche Authentisierungs- oder
Autorisierungsfehler nicht als oeffentliches GitHub-Issue melden. Fuer ein auf
GitHub gehostetes Repository soll dafuer eine private Security Advisory
verwendet werden. Bei einem privaten internen Repository gilt der definierte
Security-/Incident-Kanal der betreibenden Organisation.

## Sicherheitsmodell

Local Infrastructure Stack verwaltet privilegierte Systemkonfiguration. Fehler in Pfad-,
Authentisierungs- oder Action-Pruefungen koennen deshalb hohe Auswirkungen
haben.

Zentrale Regeln:

1. API-Authentisierung des Config-Agent nicht deaktivieren.
2. `path_guard=enforce` beibehalten.
3. `allowed_roots` so klein wie fachlich moeglich halten.
4. `git_deploy.allowed_roots` separat pflegen.
5. keine produktiven Secrets in Git.
6. interne Listener nach Moeglichkeit auf Loopback binden.
7. fuer Remote-Zugriff TLS und Netzwerk-ACL einsetzen.
8. Service-Actions nur ueber die definierte Action-Whitelist erlauben.
9. keine freien Shell-Kommandos aus Webrequests ausfuehren.
10. vor Deployments Preflight-/Syntaxpruefungen verwenden.

## Harte Systempfade

Der Agent blockiert besonders kritische Systembereiche zusaetzlich zu den
allgemeinen Root-Freigaben. Eine breite `/etc`-Freigabe fuer Managed Configs ist
somit keine Erlaubnis, Sicherheitsdateien wie Passwort-, PAM-, SSH-, sudoers-
oder private TLS-Key-Pfade frei zu bearbeiten.

## Secrets

Produktive Dateien wie diese duerfen nicht eingecheckt werden:

```text
/opt/service/env/config-agent.env
/opt/service/env/forgejo-api.token
/opt/service/env/forgejo-admin.env
/opt/service/env/config-manager-admin.env
```

Im Repository sind nur Beispielwerte mit Platzhaltern erlaubt.

## TLS

Selbstsignierte Zertifikate sind fuer ein isoliertes Lab akzeptabel. In einer
produktiveren Umgebung soll eine interne CA verwendet und TLS-Verifikation
aktiviert werden.

## Sicherheitsrelevante Aenderungen

Vor Merge mindestens:

```bash
./tools/repo-check.sh
git diff --check
```

Bei Aenderungen an Config-Agent, Git Deploy, Package Management, ModSecurity,
Authentisierung oder Dateischreiblogik sind die passenden Regressionstests und
ein Zielsystemtest erforderlich.

## Audit-Metadaten

Der Standalone-Audit-Trail speichert bei Webaktionen die Quell-IP und den Request-Pfad.
Query-Strings werden bewusst nicht gespeichert, damit API-Tokens, Suchparameter oder andere
sensitive Werte nicht versehentlich in die Audit-Datenbank gelangen. Service-Status- und
Journal-Abfragen werden nicht als Mutation auditiert; schreibende Service-Aktionen dagegen schon.


## Fail2ban

Fail2ban wird als zusätzliche Schutzschicht für wiederholte Webangriffe eingesetzt. Die verwalteten Jails ersetzen weder serverseitige Autorisierung noch ModSecurity/OWASP CRS. Der ModSecurity-Jail reagiert nur auf disruptive `Access denied`-Ereignisse und nicht auf reine DetectionOnly-Warnungen. Allowlist-Netze müssen bewusst administrativ definiert werden. Bei Reverse-Proxy-/Load-Balancer-Betrieb muss die echte Client-IP ausschliesslich aus vertrauenswürdiger Proxy-Konfiguration stammen, bevor Fail2ban darauf basiert.
