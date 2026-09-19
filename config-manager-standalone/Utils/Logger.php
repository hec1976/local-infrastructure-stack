<?php
namespace ConfigManager\Utils;

use Exception;

class Logger
{
    /**
     * Kompatibilitaet fuer alte Aufrufer. Es gibt keine lokalen Logdateien mehr.
     * Alle Audit-Events werden ueber shared/lib/core/audit.php in audit_log geschrieben.
     */
    public function __construct(?string $logDirectory = null)
    {
    }

    public static function resolveLogDirectory(): string
    {
        return '';
    }

    public static function listLogDirectories(): array
    {
        return [];
    }

    /**
     * Universelles Audit fuer LDAP/Objekte und Datei-Aenderungen.
     *
     * @param string $user        Wer war es?
     * @param string $function    Funktionsname/Modul
     * @param string $action      Aktion create/update/save/delete
     * @param string $identity    Eindeutige Identitaet, z.B. DN oder Filename
     * @param mixed  $data        Neue Daten, Array fuer LDAP, String fuer Datei
     * @param mixed  $currentData Vorherige Daten, Array fuer LDAP, String fuer Datei
     * @param string $type        ldap oder file
     * @throws Exception wenn das zentrale Audit nicht geschrieben werden kann
     */
    public function log(
        string $user,
        string $function,
        string $action,
        string $identity,
        $data = [],
        $currentData = [],
        string $type = 'ldap'
    ): void {
        $this->loadAuditHelper();

        $payload = [
            'audit_type' => $type,
            'actor' => $user,
        ];

        if ($type === 'file') {
            $before = is_string($currentData) ? $currentData : '';
            $after  = is_string($data) ? $data : '';
            $beforeText = $this->normalizeTextForDiff($before);
            $afterText  = $this->normalizeTextForDiff($after);

            $payload += [
                'before_md5'       => md5($before),
                'after_md5'        => md5($after),
                'before_len'       => strlen($before),
                'after_len'        => strlen($after),
                'before_text_md5'  => md5($beforeText),
                'after_text_md5'   => md5($afterText),
                'before_eol'       => $this->detectEolLabel($before),
                'after_eol'        => $this->detectEolLabel($after),
                'eol_only'         => ($before !== $after && $beforeText === $afterText),
                'diff'             => $this->fileShortDiff($before, $after),
            ];
        } else {
            $ignoreFields = ['hasese', 'sesiriv'];

            $dataNorm        = $this->normalizeLdapEntry($data);
            $currentDataNorm = $this->normalizeLdapEntry($currentData);
            $diff            = $this->arrayDiffAssocRecursive($dataNorm, $currentDataNorm, $ignoreFields);

            $payload += [
                'data'        => $dataNorm,
                'currentData' => $currentDataNorm,
                'diff'        => $diff,
            ];
        }

        if (!\mmbb_audit_write($action, $identity, $payload, $function, 'ok')) {
            throw new Exception('Logging-Fehler: Zentrale Audit-DB konnte nicht geschrieben werden.');
        }
    }

    private function loadAuditHelper(): void
    {
        if (function_exists('mmbb_audit_write')) {
            return;
        }

        require_once __DIR__ . '/../../../shared/lib/core/audit.php';

        if (!function_exists('mmbb_audit_write')) {
            throw new Exception('Logging-Fehler: mmbb_audit_write() nicht verfuegbar.');
        }
    }

    /**
     * Gibt geaenderte Zeilen zwischen zwei Strings zurueck.
     * @return array<int,array{line:int,before:string,after:string}>
     */
    private function fileShortDiff(string $before, string $after): array
    {
        $beforeNorm = $this->normalizeTextForDiff($before);
        $afterNorm  = $this->normalizeTextForDiff($after);

        if ($beforeNorm === $afterNorm) {
            return [];
        }

        $linesA = explode("\n", $beforeNorm);
        $linesB = explode("\n", $afterNorm);
        $max = max(count($linesA), count($linesB));
        $diffLines = [];

        $cut = static function (string $s, int $start, int $len): string {
            if (function_exists('mb_substr')) {
                return mb_substr($s, $start, $len);
            }
            return substr($s, $start, $len);
        };

        for ($i = 0; $i < $max; $i++) {
            $old = $linesA[$i] ?? '';
            $new = $linesB[$i] ?? '';
            if ($old !== $new) {
                $diffLines[] = [
                    'line'   => $i + 1,
                    'before' => $cut($old, 0, 500),
                    'after'  => $cut($new, 0, 500),
                ];
            }
        }
        return $diffLines;
    }

    private function normalizeTextForDiff(string $text): string
    {
        return str_replace(["\r\n", "\r"], "\n", $text);
    }

    private function detectEolLabel(string $text): string
    {
        $crlf = substr_count($text, "\r\n");
        $withoutCrlf = str_replace("\r\n", '', $text);
        $lf = substr_count($withoutCrlf, "\n");
        $cr = substr_count($withoutCrlf, "\r");

        if ($crlf > 0 && $lf === 0 && $cr === 0) {
            return 'CRLF';
        }
        if ($lf > 0 && $crlf === 0 && $cr === 0) {
            return 'LF';
        }
        if ($cr > 0 && $crlf === 0 && $lf === 0) {
            return 'CR';
        }
        if ($crlf > 0 || $lf > 0 || $cr > 0) {
            return 'mixed';
        }
        return 'none';
    }

    private function normalizeLdapEntry($entry): array
    {
        if (is_array($entry) && isset($entry[0]) && is_array($entry[0]) && count($entry) === 1) {
            $entry = $entry[0];
        }

        $normalized = [];
        foreach ((array)$entry as $key => $value) {
            if (strtolower((string)$key) === 'dn') {
                $key = 'DN';
            }
            if (is_int($key) || ctype_digit((string)$key)) {
                continue;
            }

            $multiValueAttributes = ['enabledservice', 'domainaliasname', 'shadowaddress'];
            if (in_array(strtolower((string)$key), $multiValueAttributes, true)) {
                $normalized[$key] = $this->normalizeMultiValue($value);
            } else {
                $normalized[$key] = is_string($value) ? trim($value) : $value;
            }
        }
        return $normalized;
    }

    private function normalizeMultiValue($value): array
    {
        if (is_array($value)) {
            $result = [];
            foreach ($value as $item) {
                $result = array_merge(
                    $result,
                    preg_split('/\r?\n/', (string)$item, -1, PREG_SPLIT_NO_EMPTY) ?: []
                );
            }
        } else {
            $result = preg_split('/\r?\n/', (string)$value, -1, PREG_SPLIT_NO_EMPTY) ?: [];
        }

        $result = array_map('trim', $result);
        $result = array_filter($result, 'strlen');
        $result = array_unique($result);
        sort($result);
        return array_values($result);
    }

    private function arrayDiffAssocRecursive(array $new, array $old, array $ignoreFields = []): array
    {
        $diff = [];
        $arrayFields = ['enabledservice'];

        foreach ($new as $key => $value) {
            if (in_array($key, $ignoreFields, true)) {
                continue;
            }

            if (in_array($key, $arrayFields, true)) {
                $val1 = (array)($new[$key] ?? []);
                $val2 = (array)($old[$key] ?? []);
                if ($val1 !== $val2 && (!$this->isEmptyVal($val1) || !$this->isEmptyVal($val2))) {
                    $diff[$key] = ['old' => $val2, 'new' => $val1];
                }
                continue;
            }

            $oldVal = array_key_exists($key, $old) ? $old[$key] : null;
            if ($value !== $oldVal && (!$this->isEmptyVal($value) || !$this->isEmptyVal($oldVal))) {
                $diff[$key] = ['old' => $oldVal, 'new' => $value];
            }
        }

        foreach ($old as $key => $value) {
            if (in_array($key, $ignoreFields, true)) {
                continue;
            }
            if (!array_key_exists($key, $new) && !$this->isEmptyVal($value)) {
                $diff[$key] = ['old' => $value, 'new' => null];
            }
        }

        return $diff;
    }

    private function isEmptyVal($val): bool
    {
        return $val === null || $val === '' || (is_array($val) && count($val) === 0);
    }
}
