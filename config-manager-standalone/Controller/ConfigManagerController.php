<?php
namespace ConfigManager\Controller;
use ConfigManager\Service\ConfigManagerService;
use ConfigManager\Exceptions\ServiceException;
use ConfigManager\Utils\Logger;
use Exception;

class ConfigManagerController
{
    private $service;
    private $logger;

    public function __construct(ConfigManagerService $service)
    {
        $this->service = $service;
        $this->logger = new Logger();
    }

    // Audit-Logging ueber zentrale Log-DB, analog maildir_mgmt.
    private function logChange(
        string $action,
        string $identity,
        $data = [],
        $currentData = [],
        string $type = 'file'
    ) {
        $user = $_SESSION['user_id'] ?? 'system';
        $function = debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, 2)[1]['function'] ?? __METHOD__;
        $this->logger->log(
            $user,
            $function,
            $action,
            $identity,
            $data,
            $currentData,
            $type
        );
    }

    public function index(array $serverlist, int $server_idx, string $csrf_token)
    {
        try {
            $configs = $this->service->getAllConfigs();
            $ids = array_map(fn($c) => $c['id'], $configs);
            $all_backups = $this->service->getAllBackups($ids);

            return [
                'serverlist'   => $serverlist,
                'server_idx'   => $server_idx,
                'configs'      => $configs,
                'all_backups'  => $all_backups,
                'csrf_token'   => $csrf_token
            ];
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }

    public function getConfigContent($name)
    {
        try {
            return $this->service->getConfigContent($name);
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }

    public function saveConfig($name, $content, ?string $oldContentSnapshot = null, ?string $oldContentMd5 = null)
    {
        try {
            $oldContent = $this->resolveOldContentForSave($name, $oldContentSnapshot, $oldContentMd5);
            $content = $this->normalizeSubmittedFileContent((string)$content, (string)$oldContent);

            // Browser-Formulare liefern Textarea-Inhalte oft als CRLF.
            // Wenn dadurch nach der Normalisierung keine echte Aenderung bleibt,
            // wird nicht gespeichert. Das verhindert unnoetige Backups, Reloads
            // und Audit-Eintraege bei reinen Zeilenende-Unterschieden.
            if ($content === $oldContent) {
                return [
                    'http_code' => 200,
                    'response'  => json_encode([
                        'ok'      => 1,
                        'saved'   => $name,
                        'noop'    => true,
                        'message' => 'Keine echte Änderung erkannt. Speichern wurde übersprungen.'
                    ], JSON_UNESCAPED_UNICODE),
                ];
            }

            $result = $this->service->saveConfigContent($name, $content);
            if (($result['http_code'] ?? 500) === 200) {
                $this->logChange('save', $name, $content, $oldContent, 'file');
            }
            return $result;
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }

    private function resolveOldContentForSave($name, ?string $oldContentSnapshot, ?string $oldContentMd5): string
    {
        if ($oldContentSnapshot !== null) {
            $expectedMd5 = trim((string)$oldContentMd5);
            if ($expectedMd5 === '' || hash_equals($expectedMd5, md5($oldContentSnapshot))) {
                return $oldContentSnapshot;
            }
        }

        // Fallback fuer alte Formulare, direkte POSTs oder manipulierte Snapshots.
        return (string)$this->service->getConfigContent($name);
    }

    private function normalizeSubmittedFileContent(string $content, string $oldContent): string
    {
        if ($oldContent === '') {
            return str_replace(["\r\n", "\r"], "\n", $content);
        }

        $eol = $this->detectDominantEol($oldContent);
        $normalized = str_replace(["\r\n", "\r"], "\n", $content);

        if ($eol === "\n") {
            return $normalized;
        }

        return str_replace("\n", $eol, $normalized);
    }

    private function detectDominantEol(string $text): string
    {
        $crlf = substr_count($text, "\r\n");
        $withoutCrlf = str_replace("\r\n", '', $text);
        $lf = substr_count($withoutCrlf, "\n");
        $cr = substr_count($withoutCrlf, "\r");

        if ($crlf > 0 && $crlf >= $lf && $crlf >= $cr) {
            return "\r\n";
        }
        if ($cr > 0 && $cr > $lf) {
            return "\r";
        }
        return "\n";
    }

    /**
     * Reine Statusabfrage.
     *
     * Wird von index.php fuer automatische Refreshes verwendet und darf bewusst
     * kein Audit schreiben. Sonst fuellt jeder Seitenaufbau und jeder Refresh
     * die zentrale audit_log Tabelle mit Status-Lesungen.
     */
    public function getServiceStatus($name)
    {
        try {
            return $this->service->callAction($name, 'status');
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }

    private function auditOperationalAction(string $action, string $identity, array $payload, string $result): void
    {
        try {
            if (function_exists('mmbb_audit_write')) {
                \mmbb_audit_write($action, $identity, $payload, __METHOD__, $result);
            }
        } catch (\Throwable $e) {
            // Eine erfolgreiche Service-Aktion darf nicht nachtraeglich scheitern,
            // nur weil das Audit temporaer nicht geschrieben werden kann.
            error_log('ConfigManager Audit-Warnung: ' . $e->getMessage());
        }
    }

    public function callAction($name, $cmd)
    {
        $cmd = strtolower(trim((string)$cmd));

        try {
            if ($cmd === 'status') {
                return $this->getServiceStatus($name);
            }

            // journal ist read-only und erzeugt bewusst keinen Mutations-Eintrag.
            if ($cmd === 'journal') {
                return $this->service->callAction($name, $cmd);
            }

            $result = $this->service->callAction($name, $cmd);
            $httpCode = (int)($result['http_code'] ?? 0);
            $ok = $httpCode >= 200 && $httpCode < 300;
            $this->auditOperationalAction(
                'service_' . ($cmd !== '' ? $cmd : 'action'),
                (string)$name,
                ['command' => $cmd, 'http_code' => $httpCode],
                $ok ? 'ok' : 'error'
            );
            return $result;
        } catch (ServiceException $e) {
            if ($cmd !== 'status' && $cmd !== 'journal') {
                $this->auditOperationalAction(
                    'service_' . ($cmd !== '' ? $cmd : 'action'),
                    (string)$name,
                    ['command' => $cmd, 'error' => substr($e->getMessage(), 0, 500)],
                    'error'
                );
            }
            throw $e;
        } catch (\Exception $e) {
            if ($cmd !== 'status' && $cmd !== 'journal') {
                $this->auditOperationalAction(
                    'service_' . ($cmd !== '' ? $cmd : 'action'),
                    (string)$name,
                    ['command' => $cmd, 'error' => substr($e->getMessage(), 0, 500)],
                    'error'
                );
            }
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }

    public function restoreBackup($name, $filename)
    {
        try {
            $oldContent = $this->service->getConfigContent($name);
            $result = $this->service->restoreBackup($name, $filename);
            if (($result['http_code'] ?? 500) === 200) {
                $restoredContent = $this->service->getConfigContent($name);
                $this->logChange('restore', $name, $restoredContent, $oldContent, 'file');
            }
            return $result;
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }

	public function viewBackupContent($name, $filename)
	{
		try {
			$content = $this->service->getBackupContent($name, $filename);

			// Optional: Logging oder Security-Checks, z.B. nur bestimmte Dateigrößen zulassen
			// $this->logView('backup_view', $name, $filename, strlen($content));

			return $content;
		} catch (ServiceException $e) {
			throw $e;
		} catch (\Exception $e) {
			throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
		}
	}


    public function getSingleBackups($id)
    {
        try {
            return $this->service->getSingleBackups($id);
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }

    public function getRawConfigs()
    {
        try {
            return $this->service->getRawConfigs();
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }

    public function saveRawConfigs($json)
    {
        try {
            $oldRaw = $this->service->getRawConfigs();
			$oldjson= json_encode($oldRaw , JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);
            $result = $this->service->saveRawConfigs($json);
            $this->logChange('save_raw', 'config-agent-managed_configs.json', $json, $oldjson, 'file');
            return $result;
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Exception $e) {
            throw new ServiceException("Unerwarteter Fehler: " . $e->getMessage(), 500, $e);
        }
    }





    public function getManagedConfigsBackups(): array
    {
        return $this->service->getManagedConfigsBackups();
    }

    public function getManagedConfigsBackup(string $filename): array
    {
        return $this->service->getManagedConfigsBackup($filename);
    }

    public function restoreManagedConfigs(string $filename): array
    {
        $result = $this->service->restoreManagedConfigs($filename);
        $audit = [
            'file' => 'managed_configs.json',
            'restored_backup' => $filename,
            'pre_restore_backup' => (string)($result['pre_restore_backup'] ?? ''),
            'entries' => (int)($result['entries'] ?? 0),
        ];
        try { $this->logChange('managed_configs_restore', 'managed_configs.json', $audit, [], 'file'); }
        catch (\Throwable $e) { $result['audit_error'] = $e->getMessage(); }
        return $result;
    }

    public function getGitDeployments(): array
    {
        try {
            return $this->service->getGitDeployments();
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new ServiceException('Unerwarteter Fehler: ' . $e->getMessage(), 500, $e);
        }
    }

    public function getGitDeployStatus(string $deployment, string $deployToken = ''): array
    {
        try {
            return $this->service->getGitDeployStatus($deployment, $deployToken);
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new ServiceException('Unerwarteter Fehler: ' . $e->getMessage(), 500, $e);
        }
    }

    public function getGitDeployReleases(string $deployment, string $deployToken = ''): array
    {
        try {
            return $this->service->getGitDeployReleases($deployment, $deployToken);
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new ServiceException('Unerwarteter Fehler: ' . $e->getMessage(), 500, $e);
        }
    }

    public function compareGitDeploy(string $deployment, string $commitSha, string $deployToken = ''): array
    {
        try { return $this->service->compareGitDeploy($deployment, $commitSha, $deployToken); }
        catch (ServiceException $e) { throw $e; }
        catch (\Throwable $e) { throw new ServiceException('Unerwarteter Fehler: ' . $e->getMessage(), 500, $e); }
    }

    /**
     * Führt einen Git-Deploy aus und auditiert ausschliesslich nicht-sensitive
     * Metadaten. Das Deploy-Token wird niemals an den Logger übergeben.
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
            $result = $this->service->deployGit(
                $deployment,
                $commitSha,
                $deployToken,
                $requestedBy,
                $diffPreviewToken,
                $diffFilesChanged,
                $deploymentDirection
            );
            $response = is_array($result['response'] ?? null) ? $result['response'] : [];

            $auditData = [
                'deployment' => $deployment,
                'requested_commit' => strtolower($commitSha),
                'http_code' => (int)($result['http_code'] ?? 0),
                'ok' => !empty($response['ok']),
                'action' => (string)($response['action'] ?? ''),
                'active_commit' => (string)($response['active_commit'] ?? $response['commit'] ?? ''),
                'previous_commit' => (string)($response['previous_commit'] ?? ''),
                'error_stage' => (string)($response['error_stage'] ?? ''),
                'rollback_ok' => is_array($response['rollback'] ?? null)
                    ? (bool)($response['rollback']['ok'] ?? false)
                    : null,
            ];

            try {
                $this->logChange('git_deploy', $deployment, $auditData, [], 'git_deploy');
            } catch (\Throwable $auditError) {
                $result['audit_error'] = $auditError->getMessage();
            }

            return $result;
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new ServiceException('Unerwarteter Fehler: ' . $e->getMessage(), 500, $e);
        }
    }

    /**
     * Stellt einen bekannten frueheren Commit ueber den normalen, geschuetzten
     * Deploy-Pfad wieder her und kennzeichnet den Vorgang separat im Audit.
     */
    public function restoreGit(
        string $deployment,
        string $commitSha,
        string $deployToken,
        string $requestedBy = '',
        string $diffPreviewToken = '',
        int $diffFilesChanged = 0,
        string $deploymentDirection = 'downgrade'
    ): array {
        try {
            $result = $this->service->deployGit(
                $deployment,
                $commitSha,
                $deployToken,
                $requestedBy,
                $diffPreviewToken,
                $diffFilesChanged,
                $deploymentDirection
            );
            $response = is_array($result['response'] ?? null) ? $result['response'] : [];
            $auditData = [
                'deployment' => $deployment,
                'restored_commit' => strtolower($commitSha),
                'http_code' => (int)($result['http_code'] ?? 0),
                'ok' => !empty($response['ok']),
                'active_commit' => (string)($response['active_commit'] ?? $response['commit'] ?? ''),
                'previous_commit' => (string)($response['previous_commit'] ?? ''),
                'error_stage' => (string)($response['error_stage'] ?? ''),
                'rollback_ok' => is_array($response['rollback'] ?? null)
                    ? (bool)($response['rollback']['ok'] ?? false)
                    : null,
            ];
            try {
                $this->logChange('git_restore', $deployment, $auditData, [], 'git_deploy');
            } catch (\Throwable $auditError) {
                $result['audit_error'] = $auditError->getMessage();
            }
            return $result;
        } catch (ServiceException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new ServiceException('Unerwarteter Fehler: ' . $e->getMessage(), 500, $e);
        }
    }

    public function getGitDeployConfig(): array
    {
        return $this->service->getGitDeployConfig();
    }

    public function validateGitDeployConfig(string $content): array
    {
        return $this->service->validateGitDeployConfig($content);
    }

    public function saveGitDeployConfig(string $content): array
    {
        $result = $this->service->saveGitDeployConfig($content);
        $audit = [
            'file' => 'git_deploy.json',
            'bytes' => strlen($content),
            'sha256' => hash('sha256', $content),
            'generation' => (int)($result['generation'] ?? 0),
            'backup' => (string)($result['backup'] ?? ''),
        ];
        try { $this->logChange('git_config_save', 'git_deploy.json', $audit, [], 'git_deploy'); }
        catch (\Throwable $e) { $result['audit_error'] = $e->getMessage(); }
        return $result;
    }

    public function getGitDeployConfigBackups(): array
    {
        return $this->service->getGitDeployConfigBackups();
    }

    public function getGitDeployConfigBackup(string $filename): array
    {
        return $this->service->getGitDeployConfigBackup($filename);
    }

    public function restoreGitDeployConfig(string $filename): array
    {
        $result = $this->service->restoreGitDeployConfig($filename);
        $audit = [
            'file' => 'git_deploy.json',
            'restored_backup' => $filename,
            'pre_restore_backup' => (string)($result['pre_restore_backup'] ?? ''),
            'generation' => (int)($result['generation'] ?? 0),
        ];
        try { $this->logChange('git_config_restore', 'git_deploy.json', $audit, [], 'git_deploy'); }
        catch (\Throwable $e) { $result['audit_error'] = $e->getMessage(); }
        return $result;
    }



    public function getGitDeploySettings(): array
    {
        return $this->service->getGitDeploySettings();
    }

    public function validateGitDeploySettings(string $content): array
    {
        return $this->service->validateGitDeploySettings($content);
    }

    public function saveGitDeploySettings(string $content): array
    {
        $result = $this->service->saveGitDeploySettings($content);
        $audit = [
            'file' => 'global.json',
            'section' => 'git_deploy',
            'bytes' => strlen($content),
            'sha256' => hash('sha256', $content),
            'generation' => (int)($result['generation'] ?? 0),
            'backup' => (string)($result['backup'] ?? ''),
        ];
        try { $this->logChange('git_settings_save', 'global.json:git_deploy', $audit, [], 'git_deploy'); }
        catch (\Throwable $e) { $result['audit_error'] = $e->getMessage(); }
        return $result;
    }

    public function getGitDeploySettingsBackups(): array
    {
        return $this->service->getGitDeploySettingsBackups();
    }

    public function restoreGitDeploySettings(string $filename): array
    {
        $result = $this->service->restoreGitDeploySettings($filename);
        $audit = [
            'file' => 'global.json',
            'section' => 'git_deploy',
            'restored_backup' => $filename,
            'pre_restore_backup' => (string)($result['pre_restore_backup'] ?? ''),
            'generation' => (int)($result['generation'] ?? 0),
        ];
        try { $this->logChange('git_settings_restore', 'global.json:git_deploy', $audit, [], 'git_deploy'); }
        catch (\Throwable $e) { $result['audit_error'] = $e->getMessage(); }
        return $result;
    }


    public function getGitUploadInfo(): array
    {
        return $this->service->getGitUploadInfo();
    }

    public function createGitUploadRepository(array $payload, string $actor): array
    {
        $result = $this->service->createGitUploadRepository($payload, $actor);
        $repo = is_array($result['repository'] ?? null) ? $result['repository'] : [];
        try { $this->logChange('repository_create', (string)($repo['full_name'] ?? ''), [
            'repository' => (string)($repo['full_name'] ?? ''),
            'private' => !empty($repo['private']),
            'actor' => $actor,
        ], [], 'git_upload'); } catch (\Throwable $e) { $result['audit_error'] = $e->getMessage(); }
        return $result;
    }

    public function getGitUploadRepositories(bool $refresh = false): array
    {
        return $this->service->getGitUploadRepositories($refresh);
    }

    public function getGitUploadBranches(string $owner, string $repository): array
    {
        return $this->service->getGitUploadBranches($owner, $repository);
    }

    public function scanGitRepository(string $owner, string $repository, string $branch): array
    {
        return $this->service->scanGitRepository($owner, $repository, $branch);
    }

    public function getGitRepositoryTree(string $owner, string $repository, string $branch, string $path = ''): array
    {
        return $this->service->getGitRepositoryTree($owner, $repository, $branch, $path);
    }

    public function getGitRepositoryFile(string $owner, string $repository, string $branch, string $path): array
    {
        return $this->service->getGitRepositoryFile($owner, $repository, $branch, $path);
    }

    public function getGitRepositoryCommits(string $owner, string $repository, string $branch, string $path = '', int $limit = 30): array
    {
        return $this->service->getGitRepositoryCommits($owner, $repository, $branch, $path, $limit);
    }

    public function getGitRepositoryCompare(string $owner, string $repository, string $base, string $head): array
    {
        return $this->service->getGitRepositoryCompare($owner, $repository, $base, $head);
    }

    public function updateGitRepositoryFile(array $payload, string $actor): array
    {
        $result = $this->service->updateGitRepositoryFile($payload, $actor);
        try { $this->logChange('git_repository_file_edit', (string)(($payload['owner'] ?? '') . '/' . ($payload['repository'] ?? '') . ':' . ($payload['path'] ?? '')), [
            'repository'=>(string)(($payload['owner'] ?? '') . '/' . ($payload['repository'] ?? '')),
            'branch'=>(string)($payload['branch'] ?? ''),
            'path'=>(string)($payload['path'] ?? ''),
            'message'=>(string)($payload['message'] ?? ''),
            'actor'=>$actor,
        ], [], 'git_upload'); } catch (\Throwable $e) { $result['audit_error'] = $e->getMessage(); }
        return $result;
    }

    public function stageGitUpload(array $files, string $uploadType, array $relativePaths, bool $stripTopLevel, string $actor, bool $trustedLocalFiles = false): array
    {
        return $this->service->stageGitUpload($files, $uploadType, $relativePaths, $stripTopLevel, $actor, $trustedLocalFiles);
    }

    public function previewGitUpload(array $payload): array
    {
        return $this->service->previewGitUpload($payload);
    }

    public function pushGitUpload(array $payload, string $actor): array
    {
        $result = $this->service->pushGitUpload($payload, $actor);
        $audit = [
            'repository' => (string)($result['repository'] ?? (($payload['owner'] ?? '') . '/' . ($payload['repository'] ?? ''))),
            'branch' => (string)($result['branch'] ?? ($payload['branch'] ?? '')),
            'commit' => (string)($result['commit'] ?? ''),
            'mode' => (string)($result['mode'] ?? ($payload['mode'] ?? 'update')),
            'noop' => !empty($result['noop']),
            'counts' => is_array($result['counts'] ?? null) ? $result['counts'] : [],
            'actor' => $actor,
        ];
        try { $this->logChange('git_repository_upload', $audit['repository'], $audit, [], 'git_upload'); }
        catch (\Throwable $e) { $result['audit_error'] = $e->getMessage(); }
        return $result;
    }

    public function discardGitUploadStage(string $stageId): array
    {
        return $this->service->discardGitUploadStage($stageId);
    }

    public function getPackageInfo(): array
    {
        return $this->service->getPackageInfo();
    }

    public function getPackagePreview(string $package): array
    {
        return $this->service->getPackagePreview($package);
    }

    public function searchPackages(string $query, int $limit = 30): array
    {
        return $this->service->searchPackages($query,$limit);
    }

    public function getInstalledPackages(string $query = '', int $limit = 2000): array
    {
        return $this->service->getInstalledPackages($query,$limit);
    }

    public function packageAction(string $action, string $package, string $version = '', bool $confirmRemove = false): array
    {
        $result=$this->service->packageAction($action,$package,$version,$confirmRemove);
        if (($result['http_code'] ?? 500) >= 200 && ($result['http_code'] ?? 500) < 300 && $action !== 'check') {
            $this->logChange('package_'.$action,$package,[
                'version'=>$version,
                'result'=>$result['response'] ?? []
            ],[],'package');
        }
        return $result;
    }

    public function getModSecurityInfo(): array
    {
        return $this->service->getModSecurityInfo();
    }

    public function getModSecurityConfig(): array
    {
        return $this->service->getModSecurityConfig();
    }

    public function getModSecurityRules(): array
    {
        return $this->service->getModSecurityRules();
    }

    public function getModSecurityCustomRules(): array
    {
        return $this->service->getModSecurityCustomRules();
    }

    public function saveModSecurityCustomRules(string $content): array
    {
        $result=$this->service->saveModSecurityCustomRules($content);
        if (($result['http_code'] ?? 500) >= 200 && ($result['http_code'] ?? 500) < 300) {
            $this->logChange('modsecurity_custom_rules','modsecurity',['bytes'=>strlen($content)],[],'security');
        }
        return $result;
    }

    public function installModSecurity(): array
    {
        $result=$this->service->installModSecurity();
        if (($result['http_code'] ?? 500) >= 200 && ($result['http_code'] ?? 500) < 300) {
            $this->logChange('modsecurity_install','modsecurity',[
                'result'=>$result['response'] ?? []
            ],[],'security');
        }
        return $result;
    }

    public function saveModSecurityConfig(array $config): array
    {
        $result=$this->service->saveModSecurityConfig($config);
        if (($result['http_code'] ?? 500) >= 200 && ($result['http_code'] ?? 500) < 300) {
            $this->logChange('modsecurity_config','modsecurity',[
                'rule_engine'=>$config['rule_engine'] ?? '',
                'audit_engine'=>$config['audit_engine'] ?? '',
                'request_body_access'=>!empty($config['request_body_access']),
                'response_body_access'=>!empty($config['response_body_access']),
                'request_body_limit'=>$config['request_body_limit'] ?? 0,
                'excluded_rule_ids'=>$config['excluded_rule_ids'] ?? []
            ],[],'security');
        }
        return $result;
    }

    public function getFail2BanInfo(): array
    {
        return $this->service->getFail2BanInfo();
    }

    public function installFail2Ban(): array
    {
        $result=$this->service->installFail2Ban();
        if (($result['http_code'] ?? 500) >= 200 && ($result['http_code'] ?? 500) < 300) $this->logChange('fail2ban_install','fail2ban',['result'=>$result['response'] ?? []],[],'security');
        return $result;
    }

    public function saveFail2BanConfig(array $config): array
    {
        $result=$this->service->saveFail2BanConfig($config);
        if (($result['http_code'] ?? 500) >= 200 && ($result['http_code'] ?? 500) < 300) $this->logChange('fail2ban_config','fail2ban',['config'=>$config],[],'security');
        return $result;
    }

    public function unbanFail2Ban(string $jail,string $ip): array
    {
        $result=$this->service->unbanFail2Ban($jail,$ip);
        if (($result['http_code'] ?? 500) >= 200 && ($result['http_code'] ?? 500) < 300) $this->logChange('fail2ban_unban',$ip,['jail'=>$jail],[],'security');
        return $result;
    }

    public function getFirewallInfo(): array { return $this->service->getFirewallInfo(); }
    public function changeFirewallRule(array $change): array
    {
        $result=$this->service->changeFirewallRule($change);
        if (($result['http_code'] ?? 500)>=200 && ($result['http_code'] ?? 500)<300) $this->logChange('firewall_rule',(string)($change['value']??''),$change,[],'security');
        return $result;
    }
    public function installFirewall(): array
    {
        $result=$this->service->installFirewall();
        if (($result['http_code'] ?? 500)>=200 && ($result['http_code'] ?? 500)<300) $this->logChange('firewall_install','firewall',['result'=>$result['response'] ?? []],[],'security');
        return $result;
    }
    public function changeFirewallRules(array $changes, bool $confirmLockout=false): array
    {
        $result=$this->service->changeFirewallRules($changes,$confirmLockout);
        if (($result['http_code'] ?? 500)>=200 && ($result['http_code'] ?? 500)<300) $this->logChange('firewall_rules',(string)count($changes).' Regeln',['changes'=>$changes,'confirm_lockout'=>$confirmLockout],[],'security');
        return $result;
    }
    public function administerFirewallZone(string $action, string $zone): array
    {
        $result=$this->service->administerFirewallZone($action,$zone);
        if (($result['http_code'] ?? 500)>=200 && ($result['http_code'] ?? 500)<300) $this->logChange('firewall_zone',$zone,['action'=>$action,'zone'=>$zone],[],'security');
        return $result;
    }
    public function controlFirewallService(string $action): array
    {
        $result=$this->service->controlFirewallService($action);
        if (($result['http_code'] ?? 500)>=200 && ($result['http_code'] ?? 500)<300) $this->logChange('firewall_service',$action,['action'=>$action],[],'security');
        return $result;
    }
    public function previewFirewallPolicy(array $policy): array { return $this->service->previewFirewallPolicy($policy); }
    public function applyFirewallPolicy(array $policy): array
    {
        $result=$this->service->applyFirewallPolicy($policy);
        if (($result['http_code'] ?? 500)>=200 && ($result['http_code'] ?? 500)<300) $this->logChange('firewall_policy','firewall',['policy'=>$policy],[],'security');
        return $result;
    }


    public function getClientBaselineInfo(): array { return $this->service->getClientBaselineInfo(); }
    public function installClientBaselineComponent(string $component,string $repositoryUrl=''): array { $r=$this->service->installClientBaselineComponent($component,$repositoryUrl); if(($r['http_code']??500)<300)$this->logChange('client_baseline_install_job',$component,['component'=>$component,'repository_url'=>$repositoryUrl,'job_id'=>$r['response']['job_id']??''],[],'deployment'); return $r; }
    public function getClientBaselineInstallJob(string $jobId): array { return $this->service->getClientBaselineInstallJob($jobId); }
    public function saveClientMonitBaseline(array $config): array { $r=$this->service->saveClientMonitBaseline($config); if(($r['http_code']??500)<300)$this->logChange('client_baseline_monit','monit',['bind'=>$config['bind']??'','port'=>$config['port']??0,'username'=>$config['username']??''],[],'monitoring'); return $r; }
    public function testClientMonitBaseline(): array { return $this->service->testClientMonitBaseline(); }
    public function saveClientAlloyBaseline(array $config): array { $r=$this->service->saveClientAlloyBaseline($config); if(($r['http_code']??500)<300)$this->logChange('client_baseline_alloy','alloy',['loki_url'=>$config['loki_url']??'','prometheus_remote_write_url'=>$config['prometheus_remote_write_url']??''],[],'monitoring'); return $r; }
    public function getFileManagerRoots(): array { return $this->service->getFileManagerRoots(); }
    public function listManagedFiles(string $path): array { return $this->service->listManagedFiles($path); }
    public function readManagedFile(string $path): array { return $this->service->readManagedFile($path); }
    public function writeManagedFile(array $data): array { $r=$this->service->writeManagedFile($data); if(($r['http_code']??500)<300)$this->logChange('file_write',(string)($data['path']??''),['path'=>$data['path']??'','bytes'=>strlen((string)($data['content']??'')),'expert_override'=>!empty($data['override_managed'])],[],'config'); return $r; }
    public function deleteManagedFile(string $path,bool $override=false): array { $r=$this->service->deleteManagedFile($path,$override); if(($r['http_code']??500)<300)$this->logChange('file_delete',$path,['path'=>$path,'expert_override'=>$override],[],'config'); return $r; }
    public function renameManagedFile(string $source,string $target,bool $override=false): array { $r=$this->service->renameManagedFile($source,$target,$override); if(($r['http_code']??500)<300)$this->logChange('file_rename',$source,['source'=>$source,'target'=>$target,'expert_override'=>$override],[],'config'); return $r; }

}
