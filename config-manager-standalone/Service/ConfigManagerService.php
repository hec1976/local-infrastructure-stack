<?php
declare(strict_types=1);

namespace ConfigManager\Service;

use ConfigManager\Repository\ConfigManagerRepository;
use ConfigManager\Exceptions\RepositoryException;
use ConfigManager\Exceptions\ServiceException;

/**
 * Service-Schicht für den Config-Manager.
 * - Kümmert sich um Fehler-Mapping (RepositoryException -> ServiceException)
 * - Bietet bequeme Wrapper rund um das Repository
 */
class ConfigManagerService
{
    /** Allgemeine Standardfehlermeldung für unerwartete Fehler */
    public const ERROR_UNEXPECTED = 'Unerwarteter Fehler im Service';

    /** @var ConfigManagerRepository */
    private ConfigManagerRepository $repo;

    public function __construct(ConfigManagerRepository $repo)
    {
        $this->repo = $repo;
    }

    /** Read-only Gesamtstatus des Config-Agenten. */
    public function getAgentOverview(): array
    {
        try {
            return $this->repo->getAgentOverview();
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 502, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Read-only Health-Check; ein degradierter HTTP-Status wird als Datenwert weitergegeben. */
    public function getAgentHealth(): array
    {
        try {
            return $this->repo->getAgentHealth();
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 502, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Zentral normalisierter Monit-Status dieses Servers. */
    public function getMonitStatus(): array
    {
        try {
            return $this->repo->getMonitStatus();
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 502, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Version des Backend-Dienstes (z.B. "1.6.1") */
    public function getServerVersion(): string
    {
        try {
            // nutzt die neue Repository-Hilfsmethode (liefert '0.0.0' bei Fehler)
            return $this->repo->fetchVersion();
        } catch (RepositoryException $e) {
            // konservativ degradieren (keine harte Exception für UI-Initialisierung)
            return '0.0.0';
        } catch (\Throwable $e) {
            return '0.0.0';
        }
    }

    /** Bequemer Check: Unterstützt das Backend /backups/batch? (ab Agent 1.6.2) */
    public function serverSupportsBatch(): bool
    {
        return version_compare($this->getServerVersion(), '1.6.2', '>=');
    }

    /** Liste aller konfigurierten Objekte (Metadaten) */
    public function getAllConfigs(): array
    {
        try {
            return $this->repo->getConfigs();
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Inhalt einer Konfiguration lesen */
    public function getConfigContent(string $name): string
    {
        try {
            return $this->repo->getConfigContent($name);
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Inhalt speichern (inkl. Backup & apply_meta via Backend) */
    public function saveConfigContent(string $name, string $content): array
    {
        try {
            return $this->repo->saveConfigContent($name, $content);
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /**
     * Backups für mehrere IDs laden.
     * Nutzt Batch nur, wenn der Agent mindestens Version 1.6.2 meldet. Sonst Einzel-Calls.
     */
    public function getAllBackups(array $ids): array
    {
        try {
            return $this->repo->getBackups($ids, $this->serverSupportsBatch());
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Backups für eine ID */
    public function getSingleBackups(string $id): array
    {
        try {
            return $this->repo->getSingleBackups($id);
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Aktion auf Dienst/Script ausführen (status/start/restart/... oder Runner) */
    public function callAction(string $name, string $cmd): array
    {
        try {
            return $this->repo->callAction($name, $cmd);
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Backup wiederherstellen */
    public function restoreBackup(string $name, string $filename): array
    {
        try {
            return $this->repo->restoreBackup($name, $filename);
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Inhalt einer Backup-Datei lesen (Preview) */
    public function getBackupContent(string $name, string $filename): string
    {
        try {
            return $this->repo->getBackupContent($name, $filename);
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Registry managed_configs.json lesen */
    public function getRawConfigs(): array
    {
        try {
            return $this->repo->getRawConfigs();
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Registry managed_configs.json schreiben (atomar) */
    public function saveRawConfigs(string $json): array
    {
        try {
            return $this->repo->saveRawConfigs($json);
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), 400, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    public function getManagedConfigsBackups(): array
    {
        try { return $this->repo->getManagedConfigsBackups(); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function getManagedConfigsBackup(string $filename): array
    {
        try { return $this->repo->getManagedConfigsBackup($filename); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function restoreManagedConfigs(string $filename): array
    {
        try { return $this->repo->restoreManagedConfigs($filename); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    /** Git-Deploy-Profile des Agents laden. */
    public function getGitDeployments(): array
    {
        try {
            return $this->repo->getGitDeployments();
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Letzten Git-Deploy-Status laden. */
    public function getGitDeployStatus(string $deployment, string $deployToken = ''): array
    {
        try {
            return $this->repo->getGitDeployStatus($deployment, $deployToken);
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Verfuegbare Commits fuer den manuellen Restore laden. */
    public function getGitDeployReleases(string $deployment, string $deployToken = ''): array
    {
        try {
            return $this->repo->getGitDeployReleases($deployment, $deployToken);
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    /** Diff-Vorschau vor einem Git-Deploy laden. */
    public function compareGitDeploy(string $deployment, string $commitSha, string $deployToken = ''): array
    {
        try { return $this->repo->compareGitDeploy($deployment, $commitSha, $deployToken); }
        catch (ServiceException $e) { throw $e; }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    /** Profilgebundenen Git-Pull-Deploy ausführen. */
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
            return $this->repo->deployGit(
                $deployment,
                $commitSha,
                $deployToken,
                $requestedBy,
                $diffPreviewToken,
                $diffFilesChanged,
                $deploymentDirection
            );
        } catch (ServiceException $e) {
            throw $e;
        } catch (RepositoryException $e) {
            throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e);
        } catch (\Throwable $e) {
            throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e);
        }
    }

    public function getGitDeployConfig(): array
    {
        try { return $this->repo->getGitDeployConfig(); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function validateGitDeployConfig(string $content): array
    {
        try { return $this->repo->validateGitDeployConfig($content); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function saveGitDeployConfig(string $content, string $expectedSha256 = ''): array
    {
        try { return $this->repo->saveGitDeployConfig($content, $expectedSha256); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function getGitDeployConfigBackups(): array
    {
        try { return $this->repo->getGitDeployConfigBackups(); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function getGitDeployConfigBackup(string $filename): array
    {
        try { return $this->repo->getGitDeployConfigBackup($filename); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function restoreGitDeployConfig(string $filename): array
    {
        try { return $this->repo->restoreGitDeployConfig($filename); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }



    public function getGitDeploySettings(): array
    {
        try { return $this->repo->getGitDeploySettings(); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode(), $e); }
    }

    public function validateGitDeploySettings(string $content): array
    {
        try { return $this->repo->validateGitDeploySettings($content); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode(), $e); }
    }

    public function saveGitDeploySettings(string $content): array
    {
        try { return $this->repo->saveGitDeploySettings($content); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode(), $e); }
    }

    public function getGitDeploySettingsBackups(): array
    {
        try { return $this->repo->getGitDeploySettingsBackups(); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode(), $e); }
    }

    public function restoreGitDeploySettings(string $filename): array
    {
        try { return $this->repo->restoreGitDeploySettings($filename); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode(), $e); }
    }


    public function getGitUploadInfo(): array
    {
        try { return $this->repo->getGitUploadInfo(); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function createGitUploadRepository(array $payload, string $actor): array
    {
        try { return $this->repo->createGitUploadRepository($payload, $actor); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function getGitUploadRepositories(bool $refresh = false): array
    {
        try { return $this->repo->getGitUploadRepositories($refresh); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function getGitUploadBranches(string $owner, string $repository): array
    {
        try { return $this->repo->getGitUploadBranches($owner, $repository); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function scanGitRepository(string $owner, string $repository, string $branch): array
    {
        try { return $this->repo->scanGitRepository($owner, $repository, $branch); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function getGitRepositoryTree(string $owner, string $repository, string $branch, string $path = ''): array
    {
        try { return $this->repo->getGitRepositoryTree($owner, $repository, $branch, $path); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
    }

    public function getGitRepositoryFile(string $owner, string $repository, string $branch, string $path): array
    {
        try { return $this->repo->getGitRepositoryFile($owner, $repository, $branch, $path); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
    }

    public function getGitRepositoryCommits(string $owner, string $repository, string $branch, string $path = '', int $limit = 30): array
    {
        try { return $this->repo->getGitRepositoryCommits($owner, $repository, $branch, $path, $limit); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
    }

    public function getGitRepositoryCompare(string $owner, string $repository, string $base, string $head): array
    {
        try { return $this->repo->getGitRepositoryCompare($owner, $repository, $base, $head); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
    }

    public function updateGitRepositoryFile(array $payload, string $actor): array
    {
        try { return $this->repo->updateGitRepositoryFile($payload, $actor); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
    }

    public function stageGitUpload(array $files, string $uploadType, array $relativePaths, bool $stripTopLevel, string $actor, bool $trustedLocalFiles = false): array
    {
        try { return $this->repo->stageGitUpload($files, $uploadType, $relativePaths, $stripTopLevel, $actor, $trustedLocalFiles); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function previewGitUpload(array $payload): array
    {
        try { return $this->repo->previewGitUpload($payload); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function pushGitUpload(array $payload, string $actor): array
    {
        try { return $this->repo->pushGitUpload($payload, $actor); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function discardGitUploadStage(string $stageId): array
    {
        try { return $this->repo->discardGitUploadStage($stageId); }
        catch (RepositoryException $e) { throw new ServiceException($e->getMessage(), $e->getCode() ?: 502, $e); }
        catch (\Throwable $e) { throw new ServiceException(self::ERROR_UNEXPECTED, 500, $e); }
    }

    public function getPackageInfo(): array
    {
        return $this->repo->getPackageInfo();
    }

    public function getPackagePreview(string $package): array
    {
        if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9+_.:@-]{0,127}$/', $package)) throw new ServiceException('Ungültiger Paketname.',400);
        return $this->repo->getPackagePreview($package);
    }

    public function searchPackages(string $query, int $limit = 30): array
    {
        if (!preg_match('/^[A-Za-z0-9+_.:@-]{2,64}$/', $query)) throw new ServiceException('Paketsuche muss 2 bis 64 gültige Zeichen enthalten.',400);
        return $this->repo->searchPackages($query,max(1,min(100,$limit)));
    }

    public function getInstalledPackages(string $query = '', int $limit = 2000): array
    {
        if ($query !== '' && !preg_match('/^[A-Za-z0-9+_.:@-]{1,128}$/', $query)) throw new ServiceException('Ungültige Paketsuche.',400);
        return $this->repo->getInstalledPackages($query,max(1,min(2000,$limit)));
    }

    public function packageAction(string $action, string $package, string $version = '', bool $confirmRemove = false): array
    {
        if (!preg_match('/^(check|install|upgrade|remove)$/', $action)) {
            throw new ServiceException('Ungültige Paketaktion.',400);
        }
        if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9+_.:@-]{0,127}$/', $package)) {
            throw new ServiceException('Ungültiger Paketname.',400);
        }
        if ($version !== '' && !preg_match('/^[A-Za-z0-9][A-Za-z0-9+_.:~@-]{0,127}$/', $version)) {
            throw new ServiceException('Ungültige Paketversion.',400);
        }
        if ($action === 'remove' && !$confirmRemove) { throw new ServiceException('Remove erfordert explizite Bestätigung.',400); }
        return $this->repo->packageAction($action,$package,$version,$confirmRemove);
    }

    public function getModSecurityInfo(): array
    {
        return $this->repo->getModSecurityInfo();
    }

    public function getModSecurityConfig(): array
    {
        return $this->repo->getModSecurityConfig();
    }

    public function installModSecurity(): array
    {
        return $this->repo->installModSecurity();
    }

    public function getModSecurityRules(): array
    {
        return $this->repo->getModSecurityRules();
    }

    public function getModSecurityCustomRules(): array
    {
        return $this->repo->getModSecurityCustomRules();
    }

    public function saveModSecurityCustomRules(string $content): array
    {
        if (strlen($content) > 131072) { throw new ServiceException('Custom-Rules zu gross (maximal 128 KiB).',400); }
        return $this->repo->saveModSecurityCustomRules($content);
    }

    public function saveModSecurityConfig(array $config): array
    {
        $engine=(string)($config['rule_engine'] ?? '');
        $audit=(string)($config['audit_engine'] ?? '');
        $limit=$config['request_body_limit'] ?? null;
        if (!in_array($engine,['On','Off','DetectionOnly'],true)) {
            throw new ServiceException('Ungültiger ModSecurity Rule-Engine-Modus.',400);
        }
        if (!in_array($audit,['On','Off','RelevantOnly'],true)) {
            throw new ServiceException('Ungültiger ModSecurity Audit-Engine-Modus.',400);
        }
        if (!is_int($limit) && !(is_string($limit) && preg_match('/^\d+$/',$limit))) {
            throw new ServiceException('Ungültiges Request-Body-Limit.',400);
        }
        $limit=(int)$limit;
        if ($limit<1048576 || $limit>1073741824) {
            throw new ServiceException('Request-Body-Limit außerhalb 1 MiB bis 1 GiB.',400);
        }
        $ids=$config['excluded_rule_ids'] ?? [];
        if (!is_array($ids) || count($ids)>200) {
            throw new ServiceException('Ungültige Rule-Ausnahmen.',400);
        }
        $clean=[];
        foreach($ids as $id) {
            $id=(string)$id;
            if (!preg_match('/^[1-9][0-9]{0,8}$/',$id)) {
                throw new ServiceException('Ungültige ModSecurity Rule-ID.',400);
            }
            $clean[]=(int)$id;
        }
        $payload=[
            'rule_engine'=>$engine,
            'request_body_access'=>!empty($config['request_body_access']),
            'response_body_access'=>!empty($config['response_body_access']),
            'request_body_limit'=>$limit,
            'audit_engine'=>$audit,
            'excluded_rule_ids'=>array_values(array_unique($clean)),
        ];
        return $this->repo->saveModSecurityConfig($payload);
    }

    public function getFail2BanInfo(): array
    {
        return $this->repo->getFail2BanInfo();
    }

    public function installFail2Ban(): array
    {
        return $this->repo->installFail2Ban();
    }

    public function saveFail2BanConfig(array $config): array
    {
        $ignore=(string)($config['ignoreip'] ?? '');
        if (strlen($ignore)>2048 || !preg_match('/^[0-9A-Fa-f:.\/\s,]*$/',$ignore)) throw new ServiceException('Ungültige Allowlist.',400);
        $jails=$config['jails'] ?? [];
        if (!is_array($jails) || count($jails)>64) throw new ServiceException('Ungültige Jail-Konfiguration.',400);
        $seen=[];
        foreach ($jails as $j) {
            if (!is_array($j)) throw new ServiceException('Ungültige Jail-Konfiguration.',400);
            $name=strtolower(trim((string)($j['name'] ?? '')));
            if (!preg_match('/^[a-z0-9][a-z0-9_.-]{0,47}$/',$name)) throw new ServiceException('Ungültiger Jail-Name.',400);
            if (isset($seen[$name])) throw new ServiceException('Jail doppelt: '.$name,400); $seen[$name]=true;
            $filter=strtolower(trim((string)($j['filter'] ?? $name)));
            if (!preg_match('/^[a-z0-9][a-z0-9_.-]{0,63}$/',$filter)) throw new ServiceException('Ungültiger Filter für '.$name.'.',400);
            $backend=strtolower(trim((string)($j['backend'] ?? 'auto')));
            if (!in_array($backend,['auto','systemd','polling','pyinotify','gamin'],true)) throw new ServiceException('Ungültiges Backend für '.$name.'.',400);
            $port=(string)($j['port'] ?? 'all');
            if (strlen($port)>200 || !preg_match('/^[a-zA-Z0-9_,:\/-]+$/',$port)) throw new ServiceException('Ungültige Ports für '.$name.'.',400);
            $logpath=trim((string)($j['logpath'] ?? ''));
            if ($logpath!=='' && (strlen($logpath)>512 || !preg_match('#^/var/log/[A-Za-z0-9_./*?@%:+-]+$#',$logpath))) throw new ServiceException('Ungültiger Logpfad für '.$name.'.',400);
            $action=(string)($j['action'] ?? '');
            if (strlen($action)>160 || preg_match('/[\r\n;`|&<>]/',$action)) throw new ServiceException('Ungültige Action für '.$name.'.',400);
            foreach (['maxretry'=>[1,1000],'bantime'=>[1,31536000],'findtime'=>[1,2592000]] as $k=>$range) {
                $v=(int)($j[$k] ?? 0); if ($v<$range[0] || $v>$range[1]) throw new ServiceException("Ungültiger Wert $name/$k.",400);
            }
            $fr=(string)($j['failregex'] ?? ''); $ir=(string)($j['ignoreregex'] ?? '');
            if (strlen($fr)>4000 || strlen($ir)>4000 || preg_match('/[\r\n]/',$fr.$ir)) throw new ServiceException('Ungültige Filter-Regel für '.$name.'.',400);
            if ($fr!=='' && strpos($fr,'<HOST>')===false) throw new ServiceException('Failregex für '.$name.' muss <HOST> enthalten.',400);
        }
        return $this->repo->saveFail2BanConfig($config);
    }

    public function unbanFail2Ban(string $jail,string $ip): array
    {
        if (!preg_match('/^[A-Za-z0-9_.-]{1,64}$/',$jail)) throw new ServiceException('Ungültiger Jail-Name.',400);
        if (!filter_var($ip,FILTER_VALIDATE_IP)) throw new ServiceException('Ungültige IP-Adresse.',400);
        return $this->repo->unbanFail2Ban($jail,$ip);
    }

    public function getFirewallInfo(): array { return $this->repo->getFirewallInfo(); }
    public function installFirewall(): array { return $this->repo->installFirewall(); }
    public function changeFirewallRule(array $change): array
    {
        $action=strtolower(trim((string)($change['action']??''))); $kind=strtolower(trim((string)($change['kind']??''))); $zone=trim((string)($change['zone']??'public')); $value=trim((string)($change['value']??''));
        if(!in_array($action,['add','remove'],true)||!in_array($kind,['port','service','source','source_port','rich_rule','interface'],true)) throw new ServiceException('Ungültige Firewall-Aenderung.',400);
        if(!preg_match('/^[A-Za-z0-9_.-]{1,64}$/',$zone)||$value===''||strlen($value)>1000) throw new ServiceException('Ungültige Firewall-Regel.',400);
        return $this->repo->changeFirewallRule(['action'=>$action,'kind'=>$kind,'zone'=>$zone,'value'=>$value,'confirm_lockout'=>!empty($change['confirm_lockout'])]);
    }
    public function changeFirewallRules(array $changes, bool $confirmLockout=false): array
    {
        if(count($changes)<1) throw new ServiceException('Keine Firewall-Aenderungen uebergeben.',400);
        if(count($changes)>32) throw new ServiceException('Maximal 32 Firewall-Aenderungen pro Vorgang.',400);
        $out=[];
        foreach($changes as $c){
            if(!is_array($c)) throw new ServiceException('Ungültige Firewall-Aenderung.',400);
            $action=strtolower(trim((string)($c['action']??''))); $kind=strtolower(trim((string)($c['kind']??'')));
            $zone=trim((string)($c['zone']??'public')); $value=trim((string)($c['value']??''));
            if(!in_array($action,['add','remove'],true)||!in_array($kind,['port','service','source','source_port','rich_rule','interface'],true)) throw new ServiceException('Ungültige Firewall-Aenderung.',400);
            if(!preg_match('/^[A-Za-z0-9_.-]{1,64}$/',$zone)||$value===''||strlen($value)>1000) throw new ServiceException('Ungültige Firewall-Regel.',400);
            $out[]=['action'=>$action,'kind'=>$kind,'zone'=>$zone,'value'=>$value];
        }
        return $this->repo->changeFirewallRules($out,$confirmLockout);
    }
    public function administerFirewallZone(string $action, string $zone): array
    {
        $action=strtolower(trim($action)); $zone=trim($zone);
        if(!in_array($action,['create','delete'],true)) throw new ServiceException('Ungültige Zonenaktion.',400);
        if(!preg_match('/^[A-Za-z0-9_-]{1,17}$/',$zone)) throw new ServiceException('Ungültiger Zonenname. Erlaubt sind bis zu 17 Zeichen aus A-Z, a-z, 0-9, Bindestrich und Unterstrich.',400);
        return $this->repo->administerFirewallZone($action,$zone);
    }
    public function controlFirewallService(string $action): array
    {
        $action=strtolower(trim($action));
        if(!in_array($action,['enable','disable','restart'],true)) throw new ServiceException('Ungültige Firewall-Dienstaktion.',400);
        return $this->repo->controlFirewallService($action);
    }
    public function previewFirewallPolicy(array $policy): array { return $this->repo->previewFirewallPolicy($this->normalizeFirewallPolicy($policy)); }
    public function applyFirewallPolicy(array $policy): array { return $this->repo->applyFirewallPolicy($this->normalizeFirewallPolicy($policy)); }
    private function normalizeFirewallPolicy(array $policy): array
    {
        $zone=trim((string)($policy['zone'] ?? 'public'));
        if (!preg_match('/^[A-Za-z0-9_.-]{1,64}$/',$zone)) throw new ServiceException('Ungültige Firewall-Zone.',400);
        $rules=$policy['rules'] ?? []; if(!is_array($rules)||count($rules)>64) throw new ServiceException('Ungültige Firewall-Regeln.',400);
        $out=[];
        foreach($rules as $r){ if(!is_array($r)) throw new ServiceException('Ungültige Firewall-Regel.',400); $port=(int)($r['port']??0); $proto=strtolower(trim((string)($r['proto']??'tcp'))); $source=trim((string)($r['source']??''));
            if($port<1||$port>65535||!in_array($proto,['tcp','udp'],true)) throw new ServiceException('Ungültige Firewall-Regel.',400);
            if($source!=='' && strlen($source)>128) throw new ServiceException('Ungültige Firewall-Quelle.',400);
            $out[]=['port'=>$port,'proto'=>$proto,'source'=>$source,'description'=>substr(trim((string)($r['description']??'')),0,120)];
        }
        return ['zone'=>$zone,'rules'=>$out];
    }


    public function getClientBaselineInfo(): array { return $this->repo->getClientBaselineInfo(); }
    public function installClientBaselineComponent(string $component,string $repositoryUrl=''): array { if($component!=='baseline-packages') throw new ServiceException('Ungültige Baseline-Paketaktion.',400); if(!filter_var($repositoryUrl,FILTER_VALIDATE_URL)||!preg_match('#^https://#i',$repositoryUrl)) throw new ServiceException('Ungültige HTTPS Baseline-Repository-URL.',400); return $this->repo->startClientBaselineInstallJob($component,$repositoryUrl); }
    public function getClientBaselineInstallJob(string $jobId): array { if(!preg_match('/^bl-[A-Za-z0-9_.-]{8,96}$/',$jobId)) throw new ServiceException('Ungültige Baseline-Job-ID.',400); return $this->repo->getClientBaselineInstallJob($jobId); }
    public function saveClientMonitBaseline(array $config): array {
        $bind=trim((string)($config['bind']??'127.0.0.1')); $port=(int)($config['port']??2812); $user=trim((string)($config['username']??'monitadmin')); $pass=(string)($config['password']??'');
        if(!preg_match('/^[A-Za-z0-9_.:-]{1,128}$/',$bind)||$port<1024||$port>65535||!preg_match('/^[A-Za-z0-9_.-]{1,64}$/',$user)||($pass!=='' && (strlen($pass)<12||strlen($pass)>256))) throw new ServiceException('Ungültige Monit-Grundkonfiguration. Passwort leer lassen = vorhandenes Secret beibehalten; neues Passwort mindestens 12 Zeichen.',400);
        return $this->repo->saveClientMonitBaseline(['bind'=>$bind,'port'=>$port,'username'=>$user,'password'=>$pass]);
    }
    public function testClientMonitBaseline(): array { return $this->repo->testClientMonitBaseline(); }
    public function saveClientAlloyBaseline(array $config): array {
        $loki=trim((string)($config['loki_url']??'')); $prom=trim((string)($config['prometheus_remote_write_url']??''));
        foreach([$loki,$prom] as $u){ if($u!=='' && (!filter_var($u,FILTER_VALIDATE_URL)||!preg_match('#^https?://#i',$u))) throw new ServiceException('Ungültiger Observability-Endpoint.',400); }
        return $this->repo->saveClientAlloyBaseline(['loki_url'=>$loki,'prometheus_remote_write_url'=>$prom,'identity'=>(array)($config['identity']??[])]);
    }
    public function getFileManagerRoots(): array { return $this->repo->getFileManagerRoots(); }
    public function listManagedFiles(string $path): array { if(strlen($path)>1024) throw new ServiceException('Pfad zu lang.',400); return $this->repo->listManagedFiles($path); }
    public function readManagedFile(string $path): array { if(strlen($path)>1024) throw new ServiceException('Pfad zu lang.',400); return $this->repo->readManagedFile($path); }
    public function writeManagedFile(array $data): array { $path=(string)($data['path']??'');$content=(string)($data['content']??'');$mode=(string)($data['mode']??'0640');$override=!empty($data['override_managed']);if(strlen($path)>1024||strlen($content)>1048576||!preg_match('/^0?[0-7]{3,4}$/',$mode)) throw new ServiceException('Ungültige Dateioperation.',400);return $this->repo->writeManagedFile(['path'=>$path,'content'=>$content,'mode'=>$mode,'override_managed'=>$override]); }
    public function deleteManagedFile(string $path,bool $override=false): array { if(strlen($path)>1024) throw new ServiceException('Pfad zu lang.',400); return $this->repo->deleteManagedFile($path,$override); }
    public function renameManagedFile(string $source,string $target,bool $override=false): array { if(strlen($source)>1024||strlen($target)>1024) throw new ServiceException('Pfad zu lang.',400); return $this->repo->renameManagedFile($source,$target,$override); }

}
