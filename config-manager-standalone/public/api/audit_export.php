<?php

declare(strict_types=1);

/**
 * Local-only Audit REST export for the TEKO Loki importer.
 *
 * GET /api/audit_export.php?after_id=123&limit=500
 * Authorization: Bearer <CONFIG_MANAGER_LOKI_EXPORT_TOKEN>
 */

require_once __DIR__ . '/../../standalone/env.php';
require_once __DIR__ . '/../../standalone/audit.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function audit_export_fail(int $status, string $message): never
{
    http_response_code($status);
    echo json_encode(
        ['ok' => false, 'error' => $message],
        JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
    );
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
    header('Allow: GET');
    audit_export_fail(405, 'Method not allowed');
}

$auth = (string)($_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '');
if ($auth === '' && function_exists('getallheaders')) {
    $headers = getallheaders();
    if (is_array($headers)) {
        $auth = (string)($headers['Authorization'] ?? $headers['authorization'] ?? '');
    }
}
if (!preg_match('/^Bearer\s+(.+)$/i', $auth, $m)) {
    audit_export_fail(401, 'Unauthorized');
}

$expected = (string)secret_env('CONFIG_MANAGER_LOKI_EXPORT_TOKEN', '');
if (strlen($expected) < 32) {
    audit_export_fail(503, 'Audit export is not configured');
}

$presented = trim($m[1]);
if (!hash_equals($expected, $presented)) {
    audit_export_fail(401, 'Unauthorized');
}

$afterId = filter_input(INPUT_GET, 'after_id', FILTER_VALIDATE_INT);
$limit   = filter_input(INPUT_GET, 'limit', FILTER_VALIDATE_INT);

$afterId = ($afterId === false || $afterId === null) ? 0 : max(0, (int)$afterId);
$limit   = ($limit === false || $limit === null) ? 500 : max(1, min(1000, (int)$limit));

try {
    ensure_log_schema();
    $pdo = log_db();

    $st = $pdo->prepare(
        'SELECT id, ts, module, user, action, identity, function, result, payload
           FROM audit_log
          WHERE id > ?
          ORDER BY id ASC
          LIMIT ?'
    );
    $st->bindValue(1, $afterId, PDO::PARAM_INT);
    $st->bindValue(2, $limit, PDO::PARAM_INT);
    $st->execute();

    $events = $st->fetchAll(PDO::FETCH_ASSOC) ?: [];
    $lastId = $afterId;
    if ($events !== []) {
        $last = end($events);
        $lastId = (int)$last['id'];
    }

    echo json_encode(
        [
            'ok' => true,
            'after_id' => $afterId,
            'last_id' => $lastId,
            'count' => count($events),
            'events' => $events,
        ],
        JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
    );
} catch (Throwable $e) {
    error_log('audit_export.php: ' . $e->getMessage());
    audit_export_fail(500, 'Audit export failed');
}
