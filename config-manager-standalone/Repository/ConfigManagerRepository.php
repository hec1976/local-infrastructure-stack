<?php
namespace ConfigManager\Repository;
use Exception;
use ConfigManager\Exceptions\RepositoryException;

class ConfigManagerRepository
{
    private $server;
    private ?string $serverVersion = null;

    public function __construct(array $server)
    {
        $this->server = $server;
    }


	private function originOf(string $url): string
	{
		$p = parse_url($url);
		$scheme = $p['scheme'] ?? 'http';
		$host   = $p['host']   ?? '';
		$port   = $p['port']   ?? ($scheme === 'https' ? 443 : 80);
		return strtolower($scheme . '://' . $host . ':' . $port);
	}


    private function boolValue($value, bool $default): bool
    {
        if (is_bool($value)) {
            return $value;
        }
        if ($value === null || $value === '') {
            return $default;
        }

        $normalized = strtolower(trim((string)$value));
        if (in_array($normalized, ['1', 'true', 'yes', 'y', 'on', 'enabled', 'enable'], true)) {
            return true;
        }
        if (in_array($normalized, ['0', 'false', 'no', 'n', 'off', 'disabled', 'disable'], true)) {
            return false;
        }

        return $default;
    }

    private function intValue($value, int $default, int $min, int $max): int
    {
        if ($value === null || $value === '') {
            return $default;
        }

        if (is_int($value)) {
            $intValue = $value;
        } else {
            $raw = trim((string)$value);
            if ($raw === '' || !preg_match('/^-?\d+$/', $raw)) {
                return $default;
            }
            $intValue = (int)$raw;
        }

        if ($intValue < $min || $intValue > $max) {
            return $default;
        }

        return $intValue;
    }

    private function tlsConfig(): array
    {
        $tls = is_array($this->server['tls'] ?? null) ? $this->server['tls'] : [];

        return [
            'verify' => $this->boolValue($tls['verify'] ?? true, true),
            'verify_host' => $this->boolValue($tls['verify_host'] ?? false, false),
            'ca_file' => trim((string)($tls['ca_file'] ?? '')),
        ];
    }

    private function httpConfig(): array
    {
        $http = is_array($this->server['http'] ?? null) ? $this->server['http'] : [];

        return [
            'connect_timeout' => $this->intValue($http['connect_timeout'] ?? 10, 10, 1, 300),
            'timeout' => $this->intValue($http['timeout'] ?? 20, 20, 1, 900),
        ];
    }

    private function gitDeployTimeout(): int
    {
        $cfg = is_array($this->server['git_deploy'] ?? null) ? $this->server['git_deploy'] : [];
        return $this->intValue($cfg['timeout'] ?? 300, 300, 30, 3600);
    }

    private function buildCurlErrorMessage(int $errno, string $error, string $url): string
    {
        $message = trim($error) !== '' ? trim($error) : ('cURL Fehler ' . $errno);
        $lower = strtolower($message);

        if (
            strpos($lower, 'certificate') !== false ||
            strpos($lower, 'ssl') !== false ||
            strpos($lower, 'tls') !== false ||
            strpos($lower, 'issuer') !== false ||
            strpos($lower, 'self signed') !== false
        ) {
            return 'TLS/cURL Fehler beim Config-Agent. ' .
                'Pruefe CONFIG_MANAGER_TLS_CA_FILE, CONFIG_MANAGER_TLS_VERIFY und CONFIG_MANAGER_TLS_VERIFY_HOST. ' .
                'URL: ' . $url . ' Fehler: ' . $message;
        }

        return 'cURL Fehler beim Config-Agent. URL: ' . $url . ' Fehler: ' . $message;
    }

    /**
     * Laedt den API-Token bei file-basierter Runtime erneut.
     * Damit ueberlebt ein langlebiger Apache/PHP-Request auch eine Token-Rotation,
     * ohne dass Git Deploy und Git Upload unterschiedliche Auth-Zustaende sehen.
     */
    private function reloadServerTokenFromFile(): bool
    {
        $path = trim((string)($this->server['token_file'] ?? ''));
        if ($path === '' || $path[0] !== '/' || str_contains($path, "\0")) {
            return false;
        }
        if (!is_file($path) || is_link($path) || !is_readable($path)) {
            return false;
        }
        $raw = file_get_contents($path);
        $token = is_string($raw) ? trim($raw) : '';
        if ($token === '' || hash_equals((string)($this->server['token'] ?? ''), $token)) {
            return false;
        }
        $this->server['token'] = $token;
        return true;
    }

    private function buildHttpErrorMessage(int $code, $json, string $raw, string $path): string
    {
        $apiError = '';
        if (is_array($json)) {
            $apiError = (string)($json['error'] ?? $json['message'] ?? '');
        }
        if ($apiError === '') {
            $apiError = trim(substr($raw, 0, 500));
        }

        if ($code === 403) {
            return 'Agent Zugriff verweigert (403). Der Config-Agent lehnt die Anfrage per allowed_ips ab. Pruefe global.json allowed_ips/trusted_proxies und die URL in config/config.php. Endpoint: ' . $path . ($apiError !== '' ? ' Antwort: ' . $apiError : '');
        }
        if ($code === 401) {
            return 'Agent Authentifizierung fehlgeschlagen (401). Pruefe CONFIG_MANAGER_API_TOKEN und CONFIG_AGENT_API_TOKEN. Endpoint: ' . $path . ($apiError !== '' ? ' Antwort: ' . $apiError : '');
        }
        if ($code === 404) {
            return 'Agent Endpoint nicht gefunden (404). Pruefe Config-Agent Version und Route. Endpoint: ' . $path . ($apiError !== '' ? ' Antwort: ' . $apiError : '');
        }
        if ($code >= 500) {
            return 'Agent Fehler (' . $code . '). Endpoint: ' . $path . ($apiError !== '' ? ' Antwort: ' . $apiError : '');
        }

        return 'Agent HTTP Fehler (' . $code . '). Endpoint: ' . $path . ($apiError !== '' ? ' Antwort: ' . $apiError : '');
    }


private function callApi(string $path, string $method = 'GET', $data = null, array $extraHeaders = [], ?int $timeoutOverride = null): array
{
    try {
        $baseUrl = $this->server['url'] ?? null;

	if (empty($baseUrl)) {
		throw new RepositoryException('API-Server-URL ist nicht konfiguriert');
	}

	$baseUrl = rtrim($baseUrl, '/');
	$url = $baseUrl . $path;


        $origin = $this->originOf($url);
        $method = strtoupper($method);

        // Basis-Header (ohne Connection/Accept-Encoding-Identity)
        $headers = [
            'X-API-Token: ' . ($this->server['token'] ?? ''),
            'Accept: application/json',
            'Expect:', // verhindert 100-continue
        ];

        // Content-Type nur bei POST, wenn nicht bereits gesetzt
        $hasCT = false;
        foreach ($extraHeaders as $h) {
            if (stripos($h, 'Content-Type:') === 0) { $hasCT = true; break; }
        }
        if ($method === 'POST' && !$hasCT) {
            $headers[] = 'Content-Type: application/json';
        }
        if (!empty($extraHeaders)) {
            $headers = array_merge($headers, $extraHeaders);
        }

        // *** Handle-Pool pro Origin (kein neues Klassen-Property nötig) ***
        static $pool = []; // key = origin, value = CurlHandle
        if (!isset($pool[$origin])) {
            $pool[$origin] = curl_init();
        }
        $ch = $pool[$origin];

        // Timeouts kommen global aus config/config.php.
        $http = $this->httpConfig();
        $connectTimeout = $http['connect_timeout'];
        $timeout        = $timeoutOverride !== null ? max(1, min(3600, $timeoutOverride)) : $http['timeout'];

        $tls = $this->tlsConfig();

        // Optionen setzen (kein curl_reset -> Reuse bleibt erhalten)
        $opts = [
            CURLOPT_URL            => $url,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER     => $headers,
            CURLOPT_CUSTOMREQUEST  => $method,
            // Agent-URLs duerfen nicht umleiten. Bei Custom-Headern koennte ein
            // Redirect sonst das X-API-Token an ein anderes Ziel weitergeben.
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => $connectTimeout,
            CURLOPT_TIMEOUT        => $timeout,

            // HTTP/2 + KeepAlive + automatische Dekompression
            CURLOPT_HTTP_VERSION   => CURL_HTTP_VERSION_2TLS,
            CURLOPT_TCP_KEEPALIVE  => 1,
            CURLOPT_ENCODING       => '', // gzip/deflate/br erlaubt

            CURLOPT_SSL_VERIFYPEER   => $tls['verify'],
            CURLOPT_SSL_VERIFYHOST   => $tls['verify_host'] ? 2 : 0,
            CURLOPT_SSL_VERIFYSTATUS => false,
        ];

        if ($tls['ca_file'] !== '') {
            $opts[CURLOPT_CAINFO] = $tls['ca_file'];
        }

        if ($method === 'POST') {
            if (is_array($data)) {
                $data = json_encode($data, JSON_UNESCAPED_UNICODE);
            }
            $opts[CURLOPT_POSTFIELDS] = ($data !== null) ? $data : '';
        } else {
            // sicherstellen, dass kein alter Body hängen bleibt
            $opts[CURLOPT_POSTFIELDS] = '';
        }

        curl_setopt_array($ch, $opts);
        $resp = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $errn = curl_errno($ch);
        $erre = curl_error($ch);

        // Einmaliger Auth-Retry bei file-basiertem Token. Der Runtime-Loader
        // liest token_file bereits beim Request-Start; falls der Agent exakt
        // waehrenddessen rotiert wurde, wird hier die aktuelle Datei erneut
        // geladen und der identische Request genau einmal wiederholt.
        if ((int)$code === 401 && $this->reloadServerTokenFromFile()) {
            $headers[0] = 'X-API-Token: ' . ($this->server['token'] ?? '');
            $opts[CURLOPT_HTTPHEADER] = $headers;
            $opts[CURLOPT_FRESH_CONNECT] = true;
            curl_setopt_array($ch, $opts);
            $resp = curl_exec($ch);
            $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $errn = curl_errno($ch);
            $erre = curl_error($ch);
        }

        // Einmaliger Retry bei typischen Keep-Alive-Fehlern
        if ($resp === false && ($errn === 56 || $errn === 52)) {
            @curl_close($ch);
            unset($pool[$origin]);
            $pool[$origin] = curl_init();
            $ch = $pool[$origin];
            curl_setopt_array($ch, $opts + [
                CURLOPT_FRESH_CONNECT => true,
                CURLOPT_FORBID_REUSE  => false,
            ]);
            $resp = curl_exec($ch);
            $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $errn = curl_errno($ch);
            $erre = curl_error($ch);
        }

        if ($resp === false) {
            throw new RepositoryException($this->buildCurlErrorMessage((int)$errn, (string)$erre, $url));
        }

        $json = json_decode($resp, true); // tolerant

        // Strikte Fehlerbehandlung nur fuer Metadaten und Roh-Configs.
        // Aktions-Endpunkte muessen den HTTP-Code als Nutzdaten zurueckgeben,
        // sonst bricht ein einzelner Service-Fehler die komplette Status-Uebersicht.
        $strictErrorPath = (bool)preg_match('#^/(?:configs(?:$|/)|config(?:$|/)|raw/(?:managed-configs|configs)(?:$|/))#', $path);

        if ($strictErrorPath && ($code < 200 || $code >= 300)) {
            throw new RepositoryException($this->buildHttpErrorMessage((int)$code, $json, (string)$resp, $path), (int)$code);
        }

        if ($strictErrorPath && is_array($json) && array_key_exists('ok', $json) && empty($json['ok'])) {
            $apiError = (string)($json['error'] ?? $json['message'] ?? 'Unbekannter Agent-Fehler');
            throw new RepositoryException('Agent meldet Fehler. Endpoint: ' . $path . ' Antwort: ' . $apiError, (int)$code);
        }

        return [
            'http_code' => $code,
            'data'      => $json,
            'raw'       => $resp,
        ];
    } catch (RepositoryException $e) {
        throw $e;
    } catch (\Throwable $e) {
        throw new RepositoryException('Unerwarteter Fehler beim API-Call', 0, $e);
    }
}


    /** Read-only Gesamtstatus des Config-Agenten. */
    public function getAgentOverview(): array
    {
        $result = $this->callApi('/', 'GET');
        return [
            'http_code' => (int)($result['http_code'] ?? 0),
            'response'  => is_array($result['data'] ?? null) ? $result['data'] : [],
        ];
    }

    /** Read-only Health-Check des Config-Agenten; HTTP 503 bleibt als Nutzstatus erhalten. */
    public function getAgentHealth(): array
    {
        $result = $this->callApi('/health', 'GET');
        return [
            'http_code' => (int)($result['http_code'] ?? 0),
            'response'  => is_array($result['data'] ?? null) ? $result['data'] : [],
        ];
    }

    public function fetchVersion(): string
    {
        if ($this->serverVersion !== null) {
            return $this->serverVersion;
        }

        try {
            $result = $this->callApi('/');
            $data = $result['data'] ?? null;
            if (is_array($data)) {
                $version = trim((string)($data['version'] ?? ''));
                $this->serverVersion = $version !== '' ? $version : '0.0.0';
                return $this->serverVersion;
            }

            $this->serverVersion = '0.0.0';
            return $this->serverVersion;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in fetchVersion()', 0, $e);
        }
    }

    public function getConfigs(): array
    {
        try {
            $result = $this->callApi('/configs');
            return $result['data']['configs'] ?? [];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new RepositoryException('Unerwarteter Fehler in getConfigs()', 0, $e);
        }
    }

    public function getConfigContent(string $name): string
    {
        try {
            $result = $this->callApi('/config/' . urlencode($name));
            return $result['raw'] ?? '';
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new RepositoryException('Unerwarteter Fehler in getConfigContent()', 0, $e);
        }
    }

    public function saveConfigContent(string $name, string $content): array
    {
        try {
            $result = $this->callApi('/config/' . urlencode($name), 'POST', $content);
            return ['http_code' => $result['http_code'], 'response' => $result['raw']];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new RepositoryException('Unerwarteter Fehler in saveConfigContent()', 0, $e);
        }
    }

    public function getBackups(array $ids, bool $useBatch = false): array
    {
        try {
            $ids = array_values(array_unique(array_filter(array_map('strval', $ids), static fn($id) => $id !== '')));
            if ($ids === []) {
                return [];
            }

            if ($useBatch) {
                $result = $this->callApi('/backups/batch', 'POST', ['ids' => $ids]);
                if (
                    isset($result['http_code']) && (int)$result['http_code'] === 200 &&
                    isset($result['data']['backups']) && is_array($result['data']['backups'])
                ) {
                    $batch = $result['data']['backups'];
                    $all = [];
                    foreach ($ids as $id) {
                        $all[$id] = (isset($batch[$id]) && is_array($batch[$id])) ? $batch[$id] : [];
                    }
                    return $all;
                }
                // Agent meldet keine nutzbare Batch-Antwort. Fallback bleibt bewusst leise.
            }

            return $this->getBackupsSequential($ids);
        } catch (RepositoryException $e) {
            if ($useBatch && in_array((int)$e->getCode(), [0, 400, 404, 405, 501], true)) {
                return $this->getBackupsSequential($ids);
            }
            throw $e;
        } catch (\Exception $e) {
            throw new RepositoryException('Unerwarteter Fehler in getBackups()', 0, $e);
        }
    }

    private function getBackupsSequential(array $ids): array
    {
        $all = [];
        foreach ($ids as $id) {
            $resp = $this->callApi('/backups/' . urlencode($id), 'GET');
            if (
                isset($resp['http_code']) && (int)$resp['http_code'] === 200 &&
                isset($resp['data']['backups']) && is_array($resp['data']['backups'])
            ) {
                $all[$id] = $resp['data']['backups'];
            } else {
                $all[$id] = [];
            }
        }
        return $all;
    }

    public function getSingleBackups(string $id): array
    {
        try {
            $result = $this->callApi('/backups/' . urlencode($id));
            return $result['data']['backups'] ?? [];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new RepositoryException('Unerwarteter Fehler in getSingleBackups()', 0, $e);
        }
    }


	public function getBackupContent(string $name, string $filename): string
	{
		try {
			$path = '/backupcontent/' . urlencode($name) . '/' . urlencode($filename);
			$result = $this->callApi($path, 'GET');
			// Rückgabe als JSON: { content: "<Dateiinhalt>" }
			if (
				isset($result['http_code']) && $result['http_code'] == 200 &&
				isset($result['data']['content'])
			) {
				return $result['data']['content'];
			} else {
				return '';
			}
		} catch (RepositoryException $e) {
			throw $e;
		} catch (\Exception $e) {
			throw new RepositoryException('Fehler beim Abrufen des Backup-Inhalts', 0, $e);
		}
	}



    public function callAction(string $name, string $cmd): array
    {
        try {
            $result = $this->callApi('/action/' . urlencode($name) . '/' . urlencode($cmd), 'POST');
            return ['http_code' => $result['http_code'], 'response' => $result['raw']];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new RepositoryException('Unerwarteter Fehler in callAction()', 0, $e);
        }
    }

    public function restoreBackup(string $name, string $filename): array
    {
        try {
            $result = $this->callApi('/restore/' . urlencode($name) . '/' . urlencode($filename), 'POST');
            return ['http_code' => $result['http_code'], 'response' => $result['raw']];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new RepositoryException('Unerwarteter Fehler in restoreBackup()', 0, $e);
        }
    }

    /**
     * Liest die Registry der verwalteten Konfigurationen.
     * Agent 2.x: /raw/managed-configs; Agent 1.x: Legacy-Fallback /raw/configs.
     */
    public function getRawConfigs(): array
    {
        try {
            try {
                $result = $this->callApi('/raw/managed-configs');
            } catch (RepositoryException $e) {
                if ((int)$e->getCode() !== 404) {
                    throw $e;
                }
                $result = $this->callApi('/raw/configs');
            }

            $json = $result['raw'] ?? $result;
            if (is_string($json)) {
                $data = json_decode($json, true);
                if (json_last_error() !== JSON_ERROR_NONE) {
                    throw new RepositoryException('managed_configs.json konnte nicht dekodiert werden: ' . json_last_error_msg());
                }
                return $data;
            }
            return is_array($json) ? $json : [];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getRawConfigs()', 0, $e);
        }
    }

    /**
     * Schreibt managed_configs.json atomar; ältere Agenten verwenden weiterhin
     * den kompatiblen Legacy-Endpunkt /raw/configs.
     */
    public function saveRawConfigs(string $json): array
    {
        try {
            try {
                $result = $this->callApi('/raw/managed-configs', 'POST', $json, ['Content-Type: application/json']);
            } catch (RepositoryException $e) {
                if ((int)$e->getCode() !== 404) {
                    throw $e;
                }
                $result = $this->callApi('/raw/configs', 'POST', $json, ['Content-Type: application/json']);
            }
            return $result['data'] ?? $result;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in saveRawConfigs()', 0, $e);
        }
    }



    /** Listet Backups der Registry-Datei managed_configs.json. */
    public function getManagedConfigsBackups(): array
    {
        try {
            $path = '/raw/managed-configs/backups';
            $headers = [];
            if ($deployToken !== '') {
                $headers[] = 'X-Deploy-Token: ' . $deployToken;
            }
            $result = $this->callApi($path, 'GET', null, $headers, $this->gitDeployTimeout());
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return is_array($data['backups'] ?? null) ? array_values($data['backups']) : [];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getManagedConfigsBackups()', 0, $e);
        }
    }

    /** Liest ein Backup der Registry-Datei fuer die Portal-Vorschau. */
    public function getManagedConfigsBackup(string $filename): array
    {
        try {
            if (!preg_match('/^managed_configs\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
                throw new RepositoryException('Ungültiger Managed-Configs-Backupname', 400);
            }
            $path = '/raw/managed-configs/backup/' . rawurlencode($filename);
            $result = $this->callApi($path, 'GET');
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getManagedConfigsBackup()', 0, $e);
        }
    }

    /** Stellt ein Backup der Registry-Datei wieder her. */
    public function restoreManagedConfigs(string $filename): array
    {
        try {
            if (!preg_match('/^managed_configs\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
                throw new RepositoryException('Ungültiger Managed-Configs-Backupname', 400);
            }
            $path = '/raw/managed-configs/restore/' . rawurlencode($filename);
            $result = $this->callApi($path, 'POST');
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in restoreManagedConfigs()', 0, $e);
        }
    }

    /**
     * Liefert die auf dem Agent konfigurierten Git-Deploy-Profile.
     */
    /** Read-only Monit status normalized by the Config-Agent from its local XML endpoint. */
    public function getMonitStatus(): array
    {
        $result = $this->callApi('/monit/status', 'GET');
        $code = (int)($result['http_code'] ?? 0);
        $data = $result['data'] ?? null;
        if ($code < 200 || $code >= 300 || !is_array($data) || empty($data['ok'])) {
            throw new RepositoryException(
                $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), '/monit/status'),
                $code
            );
        }
        return $data;
    }

    public function getGitDeployments(): array
    {
        try {
            $result = $this->callApi('/git_deployments', 'GET');
            $code = (int)($result['http_code'] ?? 0);
            $data = $result['data'] ?? null;

            if ($code < 200 || $code >= 300 || !is_array($data)) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), '/git_deployments'),
                    $code
                );
            }

            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getGitDeployments()', 0, $e);
        }
    }

    /**
     * Liest den letzten persistenten Status eines Deployment-Profils.
     * Ein HTTP 404 wird als normale Nutzantwort weitergereicht.
     */
    public function getGitDeployStatus(string $deployment, string $deployToken = ''): array
    {
        try {
            if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $deployment)) {
                throw new RepositoryException('Ungültige Deployment-ID', 400);
            }

            $path = '/git_deploy/status/' . rawurlencode($deployment);
            if ($deployToken !== '' && (strlen($deployToken) > 4096 || preg_match('/[\x00-\x20\x7f]/', $deployToken))) {
                throw new RepositoryException('Deploy-Token enthält ungültige Zeichen', 400);
            }
            $headers = $deployToken !== '' ? ['X-Deploy-Token: ' . $deployToken] : [];
            $result = $this->callApi($path, 'GET', null, $headers, $this->gitDeployTimeout());

            return [
                'http_code' => (int)($result['http_code'] ?? 0),
                'response' => is_array($result['data'] ?? null)
                    ? $result['data']
                    : ['ok' => false, 'error' => trim((string)($result['raw'] ?? 'Ungültige Agent-Antwort'))],
            ];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getGitDeployStatus()', 0, $e);
        }
    }

    /** Liefert aktive und archivierte Commits fuer einen manuellen Restore. */
    public function getGitDeployReleases(string $deployment, string $deployToken = ''): array
    {
        try {
            if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $deployment)) {
                throw new RepositoryException('Ungültige Deployment-ID', 400);
            }
            $path = '/git_deploy/releases/' . rawurlencode($deployment);
            if ($deployToken !== '' && (strlen($deployToken) > 4096 || preg_match('/[\x00-\x20\x7f]/', $deployToken))) {
                throw new RepositoryException('Deploy-Token enthält ungültige Zeichen', 400);
            }
            $headers = $deployToken !== '' ? ['X-Deploy-Token: ' . $deployToken] : [];
            $result = $this->callApi($path, 'GET', null, $headers, $this->gitDeployTimeout());
            $code = (int)($result['http_code'] ?? 0);
            $data = $result['data'] ?? null;
            if ($code < 200 || $code >= 300 || !is_array($data)) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getGitDeployReleases()', 0, $e);
        }
    }

    /** Liefert eine sichere Diff-Vorschau zwischen aktivem und gewaehltem Commit. */
    public function compareGitDeploy(string $deployment, string $commitSha, string $deployToken = ''): array
    {
        try {
            if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $deployment)) {
                throw new RepositoryException('Ungültige Deployment-ID', 400);
            }
            $commitSha = strtolower(trim($commitSha));
            if ($commitSha === '') $commitSha = 'auto';
            if ($commitSha !== 'auto' && !preg_match('/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/', $commitSha)) {
                throw new RepositoryException('Commit muss auto oder eine vollständige SHA sein', 400);
            }
            if ($deployToken !== '' && (strlen($deployToken) > 4096 || preg_match('/[\x00-\x20\x7f]/', $deployToken))) {
                throw new RepositoryException('Deploy-Token enthält ungültige Zeichen', 400);
            }
            $payload = ['commit_sha' => $commitSha];
            if ($deployToken !== '') $payload['deploy_token'] = $deployToken;
            $path = '/git_deploy/compare/' . rawurlencode($deployment);
            $result = $this->callApi($path, 'POST', $payload, [], $this->gitDeployTimeout());
            $code = (int)($result['http_code'] ?? 0);
            $data = $result['data'] ?? null;
            if ($code < 200 || $code >= 300 || !is_array($data)) {
                throw new RepositoryException($this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path), $code);
            }
            return $data;
        } catch (RepositoryException $e) { throw $e; }
        catch (\Throwable $e) { throw new RepositoryException('Unerwarteter Fehler in compareGitDeploy()', 0, $e); }
    }

    /**
     * Startet einen profilgebundenen Git-Pull-Deploy.
     * Ein Deploy-Token wird nur im optionalen Request-Token-Modus an den Agent gegeben.
     * Im Standardmodus verwendet der Agent seine lokal geschuetzte Token-Datei.
     */
    public function deployGit(
        string $deployment,
        string $commitSha,
        string $deployToken,
        string $requestedBy = '',
        string $diffPreviewToken = '',
        int $diffFilesChanged = 0,
        string $deploymentDirection = 'change'
    ): array {
        try {
            if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $deployment)) {
                throw new RepositoryException('Ungültige Deployment-ID', 400);
            }
            $commitSha = strtolower(trim($commitSha));
            if ($commitSha === '') {
                $commitSha = 'auto';
            }
            if ($commitSha !== 'auto' && !preg_match('/^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$/', $commitSha)) {
                throw new RepositoryException('Commit muss auto oder eine vollständige SHA sein', 400);
            }
            if ($deployToken !== '' && (strlen($deployToken) > 4096 || preg_match('/[\x00-\x20\x7f]/', $deployToken))) {
                throw new RepositoryException('Deploy-Token enthält ungültige Zeichen', 400);
            }

            $requestedBy = preg_replace('/[\x00-\x1f\x7f]/', '?', $requestedBy) ?? '';
            $requestedBy = substr($requestedBy, 0, 128);

            $payload = [
                'deployment' => $deployment,
                'commit_sha' => $commitSha,
            ];
            if ($deployToken !== '') {
                $payload['deploy_token'] = $deployToken;
            }
            if ($requestedBy !== '') {
                $payload['requested_by'] = $requestedBy;
            }
            if ($diffPreviewToken !== '') {
                if (!preg_match('/^[0-9a-f]{64}$/', $diffPreviewToken)) {
                    throw new RepositoryException('Ungültiges Diff-Preview-Token', 400);
                }
                $payload['diff_previewed'] = true;
                $payload['diff_preview_token'] = $diffPreviewToken;
                $payload['diff_files_changed'] = max(0, $diffFilesChanged);
                $deploymentDirection = strtolower(trim($deploymentDirection));
                if (!in_array($deploymentDirection, ['initial', 'upgrade', 'downgrade', 'same', 'change'], true)) {
                    $deploymentDirection = 'change';
                }
                $payload['deployment_direction'] = $deploymentDirection;
            }

            $headers = [];
            if ($requestedBy !== '') {
                $headers[] = 'X-Deploy-Actor: ' . $requestedBy;
            }

            $result = $this->callApi('/git_deploy', 'POST', $payload, $headers, $this->gitDeployTimeout());
            $response = is_array($result['data'] ?? null)
                ? $result['data']
                : ['ok' => false, 'error' => trim((string)($result['raw'] ?? 'Ungültige Agent-Antwort'))];

            return [
                'http_code' => (int)($result['http_code'] ?? 0),
                'response' => $response,
            ];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in deployGit()', 0, $e);
        }
    }

    /** Liest die separate git_deploy.json des Agents. */
    public function getGitDeployConfig(): array
    {
        try {
            $path = '/git_deploy/config';
            $result = $this->callApi($path, 'GET');
            $code = (int)($result['http_code'] ?? 0);
            $data = $result['data'] ?? null;
            if ($code < 200 || $code >= 300 || !is_array($data)) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getGitDeployConfig()', 0, $e);
        }
    }

    /** Validiert git_deploy.json ohne zu speichern. */
    public function validateGitDeployConfig(string $content): array
    {
        try {
            $path = '/git_deploy/config/validate';
            $result = $this->callApi($path, 'POST', ['content' => $content], [], $this->gitDeployTimeout());
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in validateGitDeployConfig()', 0, $e);
        }
    }

    /** Speichert die separate git_deploy.json atomar über den Agent. */
    public function saveGitDeployConfig(string $content, string $expectedSha256 = ''): array
    {
        try {
            $path = '/git_deploy/config';
            $payload = ['content' => $content];
            if ($expectedSha256 !== '') {
                if (!preg_match('/^[0-9a-fA-F]{64}$/', $expectedSha256)) {
                    throw new RepositoryException('Ungültiger expected_sha256', 400);
                }
                $payload['expected_sha256'] = strtolower($expectedSha256);
            }
            $result = $this->callApi($path, 'POST', $payload, [], $this->gitDeployTimeout());
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in saveGitDeployConfig()', 0, $e);
        }
    }

    /** Listet Backups der separaten git_deploy.json. */
    public function getGitDeployConfigBackups(): array
    {
        try {
            $path = '/git_deploy/config/backups';
            $result = $this->callApi($path, 'GET');
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return is_array($data['backups'] ?? null) ? array_values($data['backups']) : [];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getGitDeployConfigBackups()', 0, $e);
        }
    }

    /** Liest ein Backup der separaten git_deploy.json fuer die Vorschau. */
    public function getGitDeployConfigBackup(string $filename): array
    {
        try {
            if (!preg_match('/^git_deploy\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
                throw new RepositoryException('Ungültiger Git-Deploy-Backupname', 400);
            }
            $path = '/git_deploy/config/backup/' . rawurlencode($filename);
            $result = $this->callApi($path, 'GET');
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getGitDeployConfigBackup()', 0, $e);
        }
    }

    /** Stellt ein Backup der separaten git_deploy.json wieder her. */
    public function restoreGitDeployConfig(string $filename): array
    {
        try {
            if (!preg_match('/^git_deploy\.json\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
                throw new RepositoryException('Ungültiger Git-Deploy-Backupname', 400);
            }
            $path = '/git_deploy/config/restore/' . rawurlencode($filename);
            $result = $this->callApi($path, 'POST', [], [], $this->gitDeployTimeout());
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in restoreGitDeployConfig()', 0, $e);
        }
    }



    /** Liest den allgemeinen Git-Deploy-Block aus global.json. */
    public function getGitDeploySettings(): array
    {
        return $this->gitConfigCall('/git_deploy/settings', 'GET');
    }

    /** Validiert den allgemeinen Git-Deploy-Block ohne zu speichern. */
    public function validateGitDeploySettings(string $content): array
    {
        return $this->gitConfigCall('/git_deploy/settings/validate', 'POST', ['content' => $content]);
    }

    /** Speichert global.json -> git_deploy atomar über den Agent. */
    public function saveGitDeploySettings(string $content): array
    {
        return $this->gitConfigCall('/git_deploy/settings', 'POST', ['content' => $content]);
    }

    /** Listet Backups des allgemeinen Git-Deploy-Blocks. */
    public function getGitDeploySettingsBackups(): array
    {
        $data = $this->gitConfigCall('/git_deploy/settings/backups', 'GET');
        return is_array($data['backups'] ?? null) ? array_values($data['backups']) : [];
    }

    /** Stellt ein Backup des allgemeinen Git-Deploy-Blocks wieder her. */
    public function restoreGitDeploySettings(string $filename): array
    {
        if (!preg_match('/^git_deploy\.settings\.bak\.\d{8}_\d{6}_\d{3}$/', $filename)) {
            throw new RepositoryException('Ungültiger Git-Settings-Backupname', 400);
        }
        return $this->gitConfigCall('/git_deploy/settings/restore/' . rawurlencode($filename), 'POST', []);
    }

    /** Gemeinsamer geschützter Aufruf für die Git-Konfigurationseditoren. */
    private function gitConfigCall(string $path, string $method, mixed $payload = null): array
    {
        try {
            $result = $this->callApi($path, $method, $payload, [], $this->gitDeployTimeout());
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler bei Git-Konfigurationsaufruf', 0, $e);
        }
    }


    private function gitUploadTimeout(): int
    {
        $cfg = is_array($this->server['git_upload'] ?? null) ? $this->server['git_upload'] : [];
        return $this->intValue($cfg['timeout'] ?? $this->gitDeployTimeout(), 600, 30, 3600);
    }

    /** Gemeinsamer JSON-Aufruf fuer den Forgejo Repository Upload. */
    private function gitUploadCall(string $path, string $method = 'GET', mixed $payload = null, array $headers = []): array
    {
        try {
            $result = $this->callApi($path, $method, $payload, $headers, $this->gitUploadTimeout());
            $code = (int)($result['http_code'] ?? 0);
            $data = is_array($result['data'] ?? null) ? $result['data'] : [];
            if ($code < 200 || $code >= 300 || empty($data['ok'])) {
                throw new RepositoryException(
                    $this->buildHttpErrorMessage($code, $data, (string)($result['raw'] ?? ''), $path),
                    $code
                );
            }
            return $data;
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler beim Git Repository Upload', 0, $e);
        }
    }

    /** Multipart-Upload an den Config Agent, ohne dessen API-Token im Browser offenzulegen. */
    private function callMultipartApi(string $path, array $fields, array $files, array $extraHeaders = [], bool $trustedLocalFiles = false): array
    {
        $baseUrl = rtrim((string)($this->server['url'] ?? ''), '/');
        if ($baseUrl === '') {
            throw new RepositoryException('API-Server-URL ist nicht konfiguriert');
        }
        $url = $baseUrl . $path;
        $post = [];
        foreach ($fields as $key => $value) {
            $post[(string)$key] = is_scalar($value) ? (string)$value : json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        }
        foreach ($files as $idx => $file) {
            $tmp = (string)($file['tmp_name'] ?? '');
            $name = (string)($file['name'] ?? ('upload-' . $idx));
            $type = (string)($file['type'] ?? 'application/octet-stream');
            $validTmp = $trustedLocalFiles
                ? ($tmp !== '' && is_file($tmp) && !is_link($tmp) && is_readable($tmp))
                : ($tmp !== '' && is_uploaded_file($tmp));
            if (!$validTmp) {
                throw new RepositoryException('Temporäre Upload-Datei fehlt oder ist ungültig: ' . $name, 400);
            }
            $post['files_' . $idx] = new \CURLFile($tmp, $type !== '' ? $type : 'application/octet-stream', $name);
        }

        // Multipart-/Stage-Uploads koennen deutlich groesser sein als normale JSON-Requests.
        // Deshalb den file-basierten Runtime-Token VOR dem Request aktualisieren,
        // damit eine vorherige Agent-Token-Rotation nicht erst nach dem kompletten
        // Upload als 401 sichtbar wird. Ein einmaliger 401-Retry weiter unten deckt
        // zusaetzlich eine Rotation waehrend des Requests ab.
        $this->reloadServerTokenFromFile();
        $headers = array_merge([
            'X-API-Token: ' . ($this->server['token'] ?? ''),
            'Accept: application/json',
            'Expect:',
        ], $extraHeaders);
        $http = $this->httpConfig();
        $tls = $this->tlsConfig();
        $ch = curl_init($url);
        $opts = [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CUSTOMREQUEST => 'POST',
            CURLOPT_POSTFIELDS => $post,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => $http['connect_timeout'],
            CURLOPT_TIMEOUT => $this->gitUploadTimeout(),
            CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
            CURLOPT_TCP_KEEPALIVE => 1,
            CURLOPT_SSL_VERIFYPEER => $tls['verify'],
            CURLOPT_SSL_VERIFYHOST => $tls['verify_host'] ? 2 : 0,
            CURLOPT_SSL_VERIFYSTATUS => false,
        ];
        if ($tls['ca_file'] !== '') {
            $opts[CURLOPT_CAINFO] = $tls['ca_file'];
        }
        curl_setopt_array($ch, $opts);
        $raw = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $errno = curl_errno($ch);
        $error = curl_error($ch);

        // Gleiche Auth-Semantik wie callApi(): Falls der Agent-Token exakt
        // zwischen Request-Aufbau und Verarbeitung rotiert wurde, den aktuellen
        // file-basierten Token laden und denselben Stage-Request genau einmal
        // mit einer frischen Verbindung wiederholen.
        if ($code === 401 && $this->reloadServerTokenFromFile()) {
            $headers[0] = 'X-API-Token: ' . ($this->server['token'] ?? '');
            $opts[CURLOPT_HTTPHEADER] = $headers;
            $opts[CURLOPT_FRESH_CONNECT] = true;
            curl_setopt_array($ch, $opts);
            $raw = curl_exec($ch);
            $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $errno = curl_errno($ch);
            $error = curl_error($ch);
        }
        curl_close($ch);
        if ($raw === false) {
            throw new RepositoryException($this->buildCurlErrorMessage($errno, $error, $url));
        }
        $data = json_decode((string)$raw, true);
        $data = is_array($data) ? $data : [];
        if ($code < 200 || $code >= 300 || empty($data['ok'])) {
            throw new RepositoryException($this->buildHttpErrorMessage($code, $data, (string)$raw, $path), $code);
        }
        return $data;
    }

    public function getGitUploadInfo(): array
    {
        return $this->gitUploadCall('/git_upload/info');
    }

    /**
     * Read-only Repository-Browser fuer den Deployment-Assistenten.
     *
     * Config Agent >= 2.5.2 stellt die unabhaengigen /git_deploy-Routen bereit.
     * Bei einem aelteren Agenten wird nur auf HTTP 404 kontrolliert auf die
     * bereits vorhandenen /git_upload-Routen zurueckgefallen. Andere Fehler
     * (Auth, Forgejo, TLS, Konfiguration) werden unveraendert weitergegeben.
     */
    private function gitRepositoryBrowserCall(string $deployPath, string $legacyPath): array
    {
        try {
            return $this->gitUploadCall($deployPath);
        } catch (RepositoryException $e) {
            if ((int)$e->getErrorCode() !== 404) {
                throw $e;
            }
            return $this->gitUploadCall($legacyPath);
        }
    }

    public function createGitUploadRepository(array $payload, string $actor): array
    {
        return $this->gitUploadCall('/git_upload/repositories/create', 'POST', $payload, [
            'X-Deploy-Actor: ' . substr(preg_replace('/[\x00-\x1f\x7f]/', '?', $actor) ?? 'portal-user', 0, 128),
        ]);
    }

    public function getGitUploadRepositories(bool $refresh = false): array
    {
        $suffix = $refresh ? '?refresh=1' : '';
        $data = $this->gitRepositoryBrowserCall(
            '/git_deploy/repositories' . $suffix,
            '/git_upload/repositories' . $suffix
        );
        return is_array($data['repositories'] ?? null) ? array_values($data['repositories']) : [];
    }

    public function getGitUploadBranches(string $owner, string $repository): array
    {
        if (!preg_match('/^[A-Za-z0-9_.-]{1,128}$/', $owner) || !preg_match('/^[A-Za-z0-9_.-]{1,128}$/', $repository)) {
            throw new RepositoryException('Ungültiger Repository-Name', 400);
        }
        $suffix = '/' . rawurlencode($owner) . '/' . rawurlencode($repository) . '/branches';
        return $this->gitRepositoryBrowserCall('/git_deploy/repositories' . $suffix, '/git_upload/repositories' . $suffix);
    }

    public function scanGitRepository(string $owner, string $repository, string $branch): array
    {
        if (!preg_match('/^[A-Za-z0-9_.-]{1,128}$/', $owner) || !preg_match('/^[A-Za-z0-9_.-]{1,128}$/', $repository)) {
            throw new RepositoryException('Ungültiger Repository-Name', 400);
        }
        if (!preg_match('#^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$#', $branch) || str_contains($branch, '..') || str_contains($branch, '//')) {
            throw new RepositoryException('Ungültiger Branch-Name', 400);
        }
        $suffix = '/' . rawurlencode($owner) . '/' . rawurlencode($repository)
            . '/scan?branch=' . rawurlencode($branch);
        return $this->gitRepositoryBrowserCall('/git_deploy/repositories' . $suffix, '/git_upload/repositories' . $suffix);
    }

    private function validateGitRepositoryRef(string $owner, string $repository, string $branch): void
    {
        if (!preg_match('/^[A-Za-z0-9_.-]{1,128}$/', $owner) || !preg_match('/^[A-Za-z0-9_.-]{1,128}$/', $repository)) {
            throw new RepositoryException('Ungültiger Repository-Name', 400);
        }
        if (!preg_match('#^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$#', $branch) || str_contains($branch, '..') || str_contains($branch, '//')) {
            throw new RepositoryException('Ungültiger Branch-Name', 400);
        }
    }

    public function getGitRepositoryTree(string $owner, string $repository, string $branch, string $path = ''): array
    {
        $this->validateGitRepositoryRef($owner, $repository, $branch);
        $suffix = '/' . rawurlencode($owner) . '/' . rawurlencode($repository) . '/tree?branch=' . rawurlencode($branch) . '&path=' . rawurlencode($path);
        return $this->gitRepositoryBrowserCall('/git_deploy/repositories' . $suffix, '/git_upload/repositories' . $suffix);
    }

    public function getGitRepositoryFile(string $owner, string $repository, string $branch, string $path): array
    {
        $this->validateGitRepositoryRef($owner, $repository, $branch);
        $suffix = '/' . rawurlencode($owner) . '/' . rawurlencode($repository) . '/file?branch=' . rawurlencode($branch) . '&path=' . rawurlencode($path);
        return $this->gitRepositoryBrowserCall('/git_deploy/repositories' . $suffix, '/git_upload/repositories' . $suffix);
    }

    public function getGitRepositoryCommits(string $owner, string $repository, string $branch, string $path = '', int $limit = 30): array
    {
        $this->validateGitRepositoryRef($owner, $repository, $branch);
        $limit = max(1, min(50, $limit));
        $suffix = '/' . rawurlencode($owner) . '/' . rawurlencode($repository) . '/commits?branch=' . rawurlencode($branch) . '&path=' . rawurlencode($path) . '&limit=' . $limit;
        return $this->gitRepositoryBrowserCall('/git_deploy/repositories' . $suffix, '/git_upload/repositories' . $suffix);
    }

    public function getGitRepositoryCompare(string $owner, string $repository, string $base, string $head): array
    {
        if (!preg_match('/^[A-Za-z0-9_.-]{1,128}$/', $owner) || !preg_match('/^[A-Za-z0-9_.-]{1,128}$/', $repository)) {
            throw new RepositoryException('Ungültiger Repository-Name', 400);
        }
        if (!preg_match('/^[0-9a-f]{7,64}$/i', $base) || !preg_match('/^[0-9a-f]{7,64}$/i', $head)) {
            throw new RepositoryException('Ungültige Commit-ID', 400);
        }
        $suffix = '/' . rawurlencode($owner) . '/' . rawurlencode($repository) . '/compare?base=' . rawurlencode($base) . '&head=' . rawurlencode($head);
        return $this->gitRepositoryBrowserCall('/git_deploy/repositories' . $suffix, '/git_upload/repositories' . $suffix);
    }

    public function updateGitRepositoryFile(array $payload, string $actor): array
    {
        $owner = (string)($payload['owner'] ?? '');
        $repository = (string)($payload['repository'] ?? '');
        $branch = (string)($payload['branch'] ?? '');
        $this->validateGitRepositoryRef($owner, $repository, $branch);
        $path = '/git_upload/repositories/' . rawurlencode($owner) . '/' . rawurlencode($repository) . '/file';
        unset($payload['owner'], $payload['repository']);
        return $this->gitUploadCall($path, 'POST', $payload, [
            'X-Deploy-Actor: ' . substr(preg_replace('/[\x00-\x1f\x7f]/', '?', $actor) ?? 'portal-user', 0, 128),
        ]);
    }

    public function stageGitUpload(array $files, string $uploadType, array $relativePaths, bool $stripTopLevel, string $actor, bool $trustedLocalFiles = false): array
    {
        return $this->callMultipartApi('/git_upload/stage', [
            'upload_type' => $uploadType,
            'relative_paths' => $relativePaths,
            'expected_count' => count($files),
            'strip_top_level' => $stripTopLevel ? '1' : '0',
        ], $files, ['X-Deploy-Actor: ' . substr(preg_replace('/[\x00-\x1f\x7f]/', '?', $actor) ?? 'portal-user', 0, 128)], $trustedLocalFiles);
    }

    public function previewGitUpload(array $payload): array
    {
        return $this->gitUploadCall('/git_upload/preview', 'POST', $payload);
    }

    public function pushGitUpload(array $payload, string $actor): array
    {
        return $this->gitUploadCall('/git_upload/push', 'POST', $payload, [
            'X-Deploy-Actor: ' . substr(preg_replace('/[\x00-\x1f\x7f]/', '?', $actor) ?? 'portal-user', 0, 128),
        ]);
    }

    public function discardGitUploadStage(string $stageId): array
    {
        if (!preg_match('/^[0-9a-f]{32}$/', $stageId)) {
            throw new RepositoryException('Ungültige Stage-ID', 400);
        }
        return $this->gitUploadCall('/git_upload/stage/' . rawurlencode($stageId), 'DELETE');
    }

    public function getPackageInfo(): array
    {
        try {
            $result = $this->callApi('/packages/info');
            return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in getPackageInfo()', 0, $e);
        }
    }

    public function getPackagePreview(string $package): array
    {
        $result=$this->callApi('/packages/preview?package='.rawurlencode($package));
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function searchPackages(string $query, int $limit = 30): array
    {
        $result=$this->callApi('/packages/search?q='.rawurlencode($query).'&limit='.max(1,min(100,$limit)));
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function getInstalledPackages(string $query = '', int $limit = 2000): array
    {
        $result=$this->callApi('/packages/installed?q='.rawurlencode($query).'&limit='.max(1,min(2000,$limit)));
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function packageAction(string $action, string $package, string $version = '', bool $confirmRemove = false): array
    {
        try {
            $payload = ['action'=>$action,'package'=>$package];
            if ($version !== '') $payload['version']=$version;
            if ($action === 'remove') $payload['confirm_remove']=$confirmRemove;
            $result = $this->callApi('/packages/action','POST',$payload,[],600);
            return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
        } catch (RepositoryException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new RepositoryException('Unerwarteter Fehler in packageAction()', 0, $e);
        }
    }

    public function getModSecurityInfo(): array
    {
        $result=$this->callApi('/modsecurity/info');
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function getModSecurityConfig(): array
    {
        $result=$this->callApi('/modsecurity/config');
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function installModSecurity(): array
    {
        $result=$this->callApi('/modsecurity/install','POST',[],[],900);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function saveModSecurityConfig(array $config): array
    {
        $result=$this->callApi('/modsecurity/config','POST',$config,[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function getModSecurityRules(): array
    {
        $result=$this->callApi('/modsecurity/rules','GET',[],[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function getModSecurityCustomRules(): array
    {
        $result=$this->callApi('/modsecurity/custom-rules','GET',[],[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function saveModSecurityCustomRules(string $content): array
    {
        $result=$this->callApi('/modsecurity/custom-rules','POST',['content'=>$content],[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function getFail2BanInfo(): array
    {
        $result=$this->callApi('/fail2ban/info','GET',[],[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function installFail2Ban(): array
    {
        $result=$this->callApi('/fail2ban/install','POST',[],[],900);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function saveFail2BanConfig(array $config): array
    {
        $result=$this->callApi('/fail2ban/config','POST',$config,[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function unbanFail2Ban(string $jail,string $ip): array
    {
        $result=$this->callApi('/fail2ban/unban','POST',['jail'=>$jail,'ip'=>$ip],[],60);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function getFirewallInfo(): array
    {
        $result=$this->callApi('/firewall/info','GET',[],[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function installFirewall(): array
    {
        $result=$this->callApi('/firewall/install','POST',[],[],900);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function changeFirewallRule(array $change): array
    {
        $result=$this->callApi('/firewall/change','POST',$change,[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function changeFirewallRules(array $changes, bool $confirmLockout=false): array
    {
        $result=$this->callApi('/firewall/changes','POST',['changes'=>$changes,'confirm_lockout'=>$confirmLockout],[],300);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function administerFirewallZone(string $action, string $zone): array
    {
        $result=$this->callApi('/firewall/zone','POST',['action'=>$action,'zone'=>$zone],[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function controlFirewallService(string $action): array
    {
        $result=$this->callApi('/firewall/service','POST',['action'=>$action],[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function previewFirewallPolicy(array $policy): array
    {
        $result=$this->callApi('/firewall/preview','POST',$policy,[],120);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }

    public function applyFirewallPolicy(array $policy): array
    {
        $result=$this->callApi('/firewall/apply','POST',$policy,[],180);
        return ['http_code'=>$result['http_code'], 'response'=>$result['data'] ?? []];
    }


    public function getClientBaselineInfo(): array { $r=$this->callApi('/baseline/info','GET',[],[],120); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function startClientBaselineInstallJob(string $component,string $repositoryUrl=''): array { $r=$this->callApi('/baseline/install-job','POST',['component'=>$component,'repository_url'=>$repositoryUrl],[],20); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function getClientBaselineInstallJob(string $jobId): array { $r=$this->callApi('/baseline/job/'.rawurlencode($jobId),'GET',[],[],20); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function installClientBaselineComponent(string $component,string $repositoryUrl=''): array { return $this->startClientBaselineInstallJob($component,$repositoryUrl); }
    public function saveClientMonitBaseline(array $config): array { $r=$this->callApi('/baseline/monit-config','POST',$config,[],120); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function testClientMonitBaseline(): array { $r=$this->callApi('/baseline/monit-test','POST',[],[],60); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function saveClientAlloyBaseline(array $config): array { $r=$this->callApi('/baseline/alloy-config','POST',$config,[],120); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function getFileManagerRoots(): array { $r=$this->callApi('/files/roots','GET',[],[],60); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function listManagedFiles(string $path): array { $r=$this->callApi('/files/list?path='.rawurlencode($path),'GET',[],[],60); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function readManagedFile(string $path): array { $r=$this->callApi('/files/read?path='.rawurlencode($path),'GET',[],[],60); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function writeManagedFile(array $data): array { $r=$this->callApi('/files/write','POST',$data,[],120); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function deleteManagedFile(string $path,bool $override=false): array { $r=$this->callApi('/files/delete','POST',['path'=>$path,'override_managed'=>$override],[],60); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }
    public function renameManagedFile(string $source,string $target,bool $override=false): array { $r=$this->callApi('/files/rename','POST',['source'=>$source,'target'=>$target,'override_managed'=>$override],[],60); return ['http_code'=>$r['http_code'],'response'=>$r['data']??[]]; }

}
