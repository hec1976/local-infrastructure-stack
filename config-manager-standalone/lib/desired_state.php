<?php
declare(strict_types=1);

function ds_policy_id(string $value): string
{
    $value = trim($value);
    if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $value)) {
        throw new InvalidArgumentException('Ungueltige Policy-ID.');
    }
    return $value;
}

function ds_commit(string $value): string
{
    $value = strtolower(trim($value));
    if (!preg_match('/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/', $value)) {
        throw new InvalidArgumentException('Desired Commit muss eine vollstaendige SHA sein.');
    }
    return $value;
}

function ds_validate_document(array $doc): array
{
    if ((int)($doc['schema_version'] ?? 0) !== 1) {
        throw new InvalidArgumentException('desired_state.json: schema_version muss 1 sein.');
    }
    if (!isset($doc['policies']) || !is_array($doc['policies'])) {
        throw new InvalidArgumentException('desired_state.json: policies muss ein Objekt sein.');
    }

    $normalized = ['schema_version' => 1, 'policies' => []];

    foreach ($doc['policies'] as $id => $policy) {
        $id = ds_policy_id((string)$id);
        if (!is_array($policy)) {
            throw new InvalidArgumentException("Policy $id muss ein Objekt sein.");
        }

        $selector = is_array($policy['selector'] ?? null) ? $policy['selector'] : [];
        $groups = [];
        foreach ((array)($selector['groups'] ?? []) as $group) {
            $group = trim((string)$group);
            if (!preg_match('/^[A-Za-z0-9._-]{1,64}$/', $group)) {
                throw new InvalidArgumentException("Policy $id: ungueltige Gruppe.");
            }
            $groups[strtolower($group)] = $group;
        }

        $labels = [];
        if (isset($selector['labels']) && !is_array($selector['labels'])) {
            throw new InvalidArgumentException("Policy $id: selector.labels muss ein Objekt sein.");
        }
        foreach ((array)($selector['labels'] ?? []) as $k => $v) {
            $k = trim((string)$k);
            $v = trim((string)$v);
            if (!preg_match('/^[A-Za-z0-9._-]{1,64}$/', $k)
                || !preg_match('/^[A-Za-z0-9._:@\/-]{1,128}$/', $v)) {
                throw new InvalidArgumentException("Policy $id: ungueltiges Label.");
            }
            $labels[$k] = $v;
        }

        $groupMatch = strtolower(trim((string)($selector['group_match'] ?? 'all')));
        if (!in_array($groupMatch, ['any', 'all'], true)) {
            throw new InvalidArgumentException("Policy $id: selector.group_match muss any oder all sein.");
        }

        // Backward compatibility:
        // Alte v1.6.x Policies ohne "source" werden als Git-Policies gelesen.
        $source = is_array($policy['source'] ?? null) ? $policy['source'] : [];
        $sourceType = strtolower(trim((string)($source['type'] ?? 'git')));
        if (!in_array($sourceType, ['git', 'config_manager'], true)) {
            throw new InvalidArgumentException("Policy $id: source.type muss git oder config_manager sein.");
        }

        $normalizedSource = ['type' => $sourceType];
        $deployment = '';
        $desiredType = '';
        $desiredValue = '';

        if ($sourceType === 'git') {
            $deployment = trim((string)($source['deployment'] ?? $policy['deployment'] ?? ''));
            if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $deployment)) {
                throw new InvalidArgumentException("Policy $id: Git deployment ist ungueltig.");
            }

            $desired = is_array($source['desired'] ?? null)
                ? $source['desired']
                : (is_array($policy['desired'] ?? null) ? $policy['desired'] : []);
            $desiredType = strtolower(trim((string)($desired['type'] ?? 'allowed_ref')));
            if (!in_array($desiredType, ['allowed_ref', 'commit', 'tag'], true)) {
                throw new InvalidArgumentException("Policy $id: Git desired.type muss allowed_ref, commit oder tag sein.");
            }
            $desiredValue = trim((string)($desired['value'] ?? ''));
            if ($desiredType === 'commit') {
                $desiredValue = ds_commit($desiredValue);
            } elseif ($desiredType === 'tag') {
                if (!preg_match('/^[A-Za-z0-9._\/-]{1,128}$/', $desiredValue) || str_contains($desiredValue, '..')) {
                    throw new InvalidArgumentException("Policy $id: desired tag ist ungueltig.");
                }
            } else {
                $desiredValue = '';
            }

            $normalizedSource['deployment'] = $deployment;
            $normalizedSource['desired'] = ['type' => $desiredType, 'value' => $desiredValue];
        } else {
            $referenceServer = trim((string)($source['reference_server'] ?? ''));
            $sourceConfig = trim((string)($source['source_config'] ?? ''));
            $targetConfig = trim((string)($source['target_config'] ?? $sourceConfig));

            if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $referenceServer)) {
                throw new InvalidArgumentException("Policy $id: reference_server ist ungueltig.");
            }
            foreach (['source_config' => $sourceConfig, 'target_config' => $targetConfig] as $field => $value) {
                if (!preg_match('/^[A-Za-z0-9._:-]{1,256}$/', $value)) {
                    throw new InvalidArgumentException("Policy $id: $field ist ungueltig.");
                }
            }

            $normalizedSource += [
                'reference_server' => $referenceServer,
                'source_config' => $sourceConfig,
                'target_config' => $targetConfig,
            ];

            // Compatibility fields for UI/API consumers.
            $desiredType = 'config_hash';
            $desiredValue = '';
        }

        $enforcement = strtolower(trim((string)($policy['enforcement'] ?? 'manual')));
        if (!in_array($enforcement, ['check_only', 'manual'], true)) {
            throw new InvalidArgumentException("Policy $id: enforcement muss check_only oder manual sein.");
        }

        $maxTargets = (int)($policy['max_targets'] ?? 100);
        if ($maxTargets < 1 || $maxTargets > 100) {
            throw new InvalidArgumentException("Policy $id: max_targets muss zwischen 1 und 100 liegen.");
        }

        $rolloutRaw = is_array($policy['rollout'] ?? null) ? $policy['rollout'] : [];
        $strategy = strtolower(trim((string)($rolloutRaw['strategy'] ?? 'all')));
        if (!in_array($strategy, ['all','canary'], true)) {
            throw new InvalidArgumentException("Policy $id: rollout.strategy muss all oder canary sein.");
        }
        $canarySelector = ['groups'=>[], 'labels'=>[]];
        $maxCanaryTargets = 5;
        $requireCanaryCompliant = true;
        if ($strategy === 'canary') {
            $cs = is_array($rolloutRaw['canary_selector'] ?? null) ? $rolloutRaw['canary_selector'] : [];
            foreach ((array)($cs['groups'] ?? []) as $group) {
                $group = trim((string)$group);
                if (!preg_match('/^[A-Za-z0-9._-]{1,64}$/', $group)) {
                    throw new InvalidArgumentException("Policy $id: ungueltige Canary-Gruppe.");
                }
                $canarySelector['groups'][] = $group;
            }
            foreach ((array)($cs['labels'] ?? []) as $k=>$v) {
                $k=trim((string)$k); $v=trim((string)$v);
                if (!preg_match('/^[A-Za-z0-9._-]{1,64}$/',$k)
                    || !preg_match('/^[A-Za-z0-9._:@\/-]{1,128}$/',$v)) {
                    throw new InvalidArgumentException("Policy $id: ungueltiges Canary-Label.");
                }
                $canarySelector['labels'][$k]=$v;
            }
            if ($canarySelector['groups'] === [] && $canarySelector['labels'] === []) {
                throw new InvalidArgumentException("Policy $id: Canary-Selector darf nicht leer sein.");
            }
            $maxCanaryTargets=(int)($rolloutRaw['max_canary_targets'] ?? 5);
            if ($maxCanaryTargets < 1 || $maxCanaryTargets > min(20,$maxTargets)) {
                throw new InvalidArgumentException("Policy $id: max_canary_targets ist ungueltig.");
            }
            $requireCanaryCompliant = !array_key_exists('require_canary_compliant',$rolloutRaw)
                || !empty($rolloutRaw['require_canary_compliant']);
        }

        $normalized['policies'][$id] = [
            'enabled' => !empty($policy['enabled']),
            'description' => substr(trim((string)($policy['description'] ?? '')), 0, 500),
            'source' => $normalizedSource,
            // Legacy/GUI compatibility for existing Git code and reports.
            'deployment' => $deployment,
            'selector' => ['groups' => array_values($groups), 'labels' => $labels, 'group_match' => $groupMatch],
            'desired' => ['type' => $desiredType, 'value' => $desiredValue],
            'enforcement' => $enforcement,
            'max_targets' => $maxTargets,
            'rollout' => [
                'strategy'=>$strategy,
                'canary_selector'=>$canarySelector,
                'max_canary_targets'=>$maxCanaryTargets,
                'require_canary_compliant'=>$requireCanaryCompliant,
            ],
        ];
    }

    return $normalized;
}

function ds_server_matches(array $server, array $policy): bool
{
    $selector = is_array($policy['selector'] ?? null) ? $policy['selector'] : [];
    $requiredGroups = array_map('strtolower', (array)($selector['groups'] ?? []));
    $serverGroups = array_map('strtolower', (array)($server['groups'] ?? []));

    $groupMatch = strtolower((string)($selector['group_match'] ?? 'all'));
    if ($requiredGroups !== []) {
        if ($groupMatch === 'any') {
            $matched = false;
            foreach ($requiredGroups as $group) {
                if (in_array($group, $serverGroups, true)) { $matched = true; break; }
            }
            if (!$matched) return false;
        } else {
            foreach ($requiredGroups as $group) {
                if (!in_array($group, $serverGroups, true)) return false;
            }
        }
    }

    $serverLabels = is_array($server['labels'] ?? null) ? $server['labels'] : [];
    foreach ((array)($selector['labels'] ?? []) as $key => $value) {
        if (!array_key_exists($key, $serverLabels) || (string)$serverLabels[$key] !== (string)$value) {
            return false;
        }
    }
    return true;
}


function ds_selector_matches(array $server, array $selector): bool
{
    $requiredGroups=array_map('strtolower',(array)($selector['groups'] ?? []));
    $serverGroups=array_map('strtolower',(array)($server['groups'] ?? []));
    $groupMatch=strtolower((string)($selector['group_match'] ?? 'all'));
    if ($requiredGroups !== []) {
        if ($groupMatch === 'any') {
            $matched=false;
            foreach ($requiredGroups as $group) {
                if (in_array($group,$serverGroups,true)) { $matched=true; break; }
            }
            if (!$matched) return false;
        } else {
            foreach ($requiredGroups as $group) {
                if (!in_array($group,$serverGroups,true)) return false;
            }
        }
    }
    $serverLabels=is_array($server['labels'] ?? null) ? $server['labels'] : [];
    foreach ((array)($selector['labels'] ?? []) as $key=>$value) {
        if (!array_key_exists($key,$serverLabels) || (string)$serverLabels[$key] !== (string)$value) return false;
    }
    return true;
}

function ds_rollout_partition(array $targets, array $policy): array
{
    $rollout=is_array($policy['rollout'] ?? null) ? $policy['rollout'] : ['strategy'=>'all'];
    if (($rollout['strategy'] ?? 'all') !== 'canary') {
        return ['canary'=>[], 'remaining'=>$targets];
    }
    $canary=[]; $remaining=[];
    $selector=(array)($rollout['canary_selector'] ?? []);
    foreach ($targets as $idx=>$server) {
        if (ds_selector_matches($server,$selector)) $canary[$idx]=$server;
        else $remaining[$idx]=$server;
    }
    $limit=(int)($rollout['max_canary_targets'] ?? 5);
    if (count($canary) > $limit) {
        throw new RuntimeException("Canary-Selector trifft ".count($canary)." Server, erlaubt sind maximal $limit.");
    }
    if ($canary === []) throw new RuntimeException('Canary-Selector trifft keinen Zielserver.');
    return ['canary'=>$canary, 'remaining'=>$remaining];
}

function ds_resolve_tag_commit(array $releases, string $tag): ?string
{
    $entries = $releases['releases'] ?? $releases['commits'] ?? [];
    foreach ((array)$entries as $entry) {
        if (!is_array($entry)) continue;
        $tags = array_map('strval', (array)($entry['tags'] ?? []));
        if (!in_array($tag, $tags, true)) continue;
        $commit = strtolower(trim((string)($entry['commit'] ?? '')));
        if (preg_match('/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/', $commit)) return $commit;
    }
    return null;
}

function ds_compliance(?string $activeCommit, ?string $desiredCommit, ?string $error = null): string
{
    if ($error !== null && $error !== '') return 'error';
    if ($desiredCommit === null || $desiredCommit === '') return 'desired_unknown';
    if ($activeCommit === null || $activeCommit === '') return 'not_installed';
    return strtolower($activeCommit) === strtolower($desiredCommit) ? 'compliant' : 'drift';
}

function ds_summary(array $results): array
{
    $out = ['total'=>count($results),'compliant'=>0,'drift'=>0,'not_installed'=>0,'desired_unknown'=>0,'error'=>0];
    foreach ($results as $row) {
        $state = (string)($row['compliance'] ?? 'error');
        if (array_key_exists($state, $out)) $out[$state]++; else $out['error']++;
    }
    return $out;
}

function ds_atomic_save(string $file, array $doc): void
{
    $dir = dirname($file);
    if (!is_dir($dir) || !is_writable($dir)) throw new RuntimeException('Desired-State-Verzeichnis ist nicht schreibbar.');
    if (is_link($file)) throw new RuntimeException('desired_state.json darf kein Symlink sein.');

    $json = json_encode($doc, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
    if (!is_string($json)) throw new RuntimeException('Desired-State JSON konnte nicht kodiert werden.');

    $tmp = tempnam($dir, '.desired-state.');
    if (!is_string($tmp) || $tmp === '') throw new RuntimeException('Temporaere Desired-State-Datei konnte nicht angelegt werden.');
    try {
        if (file_put_contents($tmp, $json . "\n", LOCK_EX) === false) {
            throw new RuntimeException('Desired-State-Datei konnte nicht geschrieben werden.');
        }
        @chmod($tmp, 0640);
        if (!rename($tmp, $file)) throw new RuntimeException('Desired-State-Datei konnte nicht atomar aktiviert werden.');
    } finally {
        if (is_file($tmp)) @unlink($tmp);
    }
}
