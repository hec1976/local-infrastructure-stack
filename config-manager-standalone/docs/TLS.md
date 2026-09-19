# Config Manager TLS und Token

Die Remote-Anbindung wird zentral in `config/config.php` gepflegt.

## Globale Werte

~~~php
return [
    'api_token' => secret_env('CONFIG_MANAGER_APITOKEN'),

    'tls' => [
        'verify'      => cfg('CONFIG_MANAGER_TLS_VERIFY'),
        'verify_host' => cfg('CONFIG_MANAGER_TLS_VERIFY_HOST'),
        'ca_file'     => cfg('CONFIG_MANAGER_TLS_CA_FILE'),
    ],

    'http' => [
        'connect_timeout' => cfg('CONFIG_MANAGER_HTTP_CONNECT_TIMEOUT'),
        'timeout'         => cfg('CONFIG_MANAGER_HTTP_TIMEOUT'),
    ],

    'servers' => [
        [
            'name' => cfg('CONFIG_MANAGER_SERVERS_1_NAME'),
            'url'  => cfg('CONFIG_MANAGER_SERVERS_1_URL'),
        ],
        [
            'name' => cfg('CONFIG_MANAGER_SERVERS_2_NAME'),
            'url'  => cfg('CONFIG_MANAGER_SERVERS_2_URL'),
        ],
    ],
];
~~~

## Beispielwerte

~~~text
CONFIG_MANAGER_APITOKEN=<globaler-agent-token>

CONFIG_MANAGER_TLS_VERIFY=1
CONFIG_MANAGER_TLS_VERIFY_HOST=0
CONFIG_MANAGER_TLS_CA_FILE=/etc/ssl/mmbb/config-manager-internal-ca.pem

CONFIG_MANAGER_HTTP_CONNECT_TIMEOUT=10
CONFIG_MANAGER_HTTP_TIMEOUT=20

CONFIG_MANAGER_SERVERS_1_NAME=mail01-a
CONFIG_MANAGER_SERVERS_1_URL=https://192.168.121.10:5010
CONFIG_MANAGER_SERVERS_2_NAME=mail02-a
CONFIG_MANAGER_SERVERS_2_URL=https://192.168.121.11:5010
~~~

`CONFIG_MANAGER_SERVERS_1_NAME` darf keine Leerzeichen enthalten. Also `mail01-a`, nicht `mail 01-a`.

## Selbstsignierte Zertifikate

Saubere Variante: interne Root-CA oder Server-CA als PEM auf dem Webserver ablegen und über `CONFIG_MANAGER_TLS_CA_FILE` referenzieren.

`CONFIG_MANAGER_TLS_VERIFY_HOST=0` ist für Lab-Setups sinnvoll, wenn per IP verbunden wird und das Zertifikat keinen passenden SAN-Eintrag für diese IP hat.

`CONFIG_MANAGER_TLS_VERIFY=0` sollte nur temporaer im Lab verwendet werden.

## Timeouts

Alle Remote-Requests nutzen nur `CONFIG_MANAGER_HTTP_CONNECT_TIMEOUT` und `CONFIG_MANAGER_HTTP_TIMEOUT`.

Es gibt bewusst keine separaten Status-Timeouts mehr. Sonst wird die Admin-Konfiguration wieder unnoetig breit.

## TEKO Local / Self-Signed Default

Im lokalen Single-Server-Setup spricht der Config Manager ueber `https://127.0.0.1:5008` mit einem selbstsignierten Config-Agent-Zertifikat. Der Installer setzt deshalb standardmaessig:

```text
CONFIG_MANAGER_TLS_VERIFY=false
CONFIG_MANAGER_TLS_VERIFY_HOST=false
CONFIG_MANAGER_TLS_CA_FILE=
```

Die Verbindung bleibt TLS-verschluesselt; die Zertifikats-/Hostname-Verifikation ist fuer diesen lokalen Lab-Pfad deaktiviert. Der API-Token bleibt erforderlich. Remote-Agenten koennen weiterhin pro Server mit `verify=true`, `verify_host=true` und eigener `ca_file` streng verifiziert werden.

Fuer eine lokale interne CA kann das Setup explizit mit `CONFIG_MANAGER_TLS_VERIFY=true CONFIG_MANAGER_TLS_VERIFY_HOST=true CONFIG_MANAGER_TLS_CA_FILE=/pfad/ca.pem` gestartet werden.
