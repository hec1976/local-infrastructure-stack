#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
portal = (root / 'config-manager-standalone/public/git_upload.php').read_text(encoding='utf-8')
js = (root / 'config-manager-standalone/public/assets/js/git_upload.js').read_text(encoding='utf-8')
repo = (root / 'config-manager-standalone/Repository/ConfigManagerRepository.php').read_text(encoding='utf-8')

# Local staging is outside DocumentRoot/public and bound to the PHP session.
assert "__DIR__ . '/../standalone/data/git-upload-staging'" in portal
assert 'gu_local_stage_session_hash' in portal
assert "hash_equals((string)($data['session_hash'] ?? ''), gu_local_stage_session_hash())" in portal
assert "preg_match('/^[0-9a-f]{32}$/', $id)" in portal
assert 'gu_local_stage_relpath' in portal
assert "str_starts_with($path, '/')" in portal
assert "$part === '..'" in portal

# Chunks and files must be sequential; directory files are streamed directly to local staging.
assert "$chunkIndex !== $expectedChunk" in portal
assert "$fileIndex !== $expectedFileIndex" in portal
assert "fopen('php://input', 'rb')" in portal
assert 'stream_copy_to_stream' in portal
assert "local_stage_begin" in portal
assert "local_stage_chunk_prepare" in portal
assert "local_stage_file" in portal
assert "local_stage_finalize" in portal
assert "local_stage_abort" in portal

# Browser uploads directories in small batches, then finalises once.
assert 'stageDirectoryChunked' in js
assert "cfg.directoryChunkFiles || 10" in js
assert "binaryRequest('local_stage_file'" in js
assert "jsonRequest('local_stage_finalize'" in js
assert "jsonRequest('local_stage_abort'" in js

# Staging id must survive multipart parser issues via a dedicated request header.
assert 'function gu_local_stage_request_id' in portal
assert "HTTP_X_TEKO_UPLOAD_ID" in portal
assert "Lokale Upload-ID fehlt im Request." in portal
assert "zwischen Request-Header und Body widersprüchlich" in portal
assert "X-TEKO-Upload-ID" in js
assert "X-TEKO-Upload-ID" in js
assert "X-TEKO-File-Index" in js
assert "gu_local_stage_request_id();" in portal
assert "gu_local_stage_request_id($payload);" in portal

# Only the internal finalisation path may forward trusted local stage files.
assert 'bool $trustedLocalFiles = false' in repo
assert '$trustedLocalFiles' in repo
assert 'is_file($tmp) && !is_link($tmp) && is_readable($tmp)' in repo

print('git_upload_chunked_staging_test: PASS')
