#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
portal = (root / 'config-manager-standalone/public/git_upload.php').read_text()
js = (root / 'config-manager-standalone/public/assets/js/git_upload.js').read_text()

assert "local_stage_chunk_prepare" in portal
assert "local_stage_chunk_prepare" in js
assert "X-TEKO-Chunk-Index" in js
assert "X-TEKO-Chunk-Token" in js
assert "X-TEKO-File-Index" in js
assert "HTTP_X_TEKO_CHUNK_INDEX" in portal
assert "HTTP_X_TEKO_CHUNK_TOKEN" in portal
assert "HTTP_X_TEKO_FILE_INDEX" in portal
assert "pending_chunk" in portal
assert "token_hash" in portal
assert "hash_equals" in portal
assert "erwartet %d, erhalten %d" in portal
# Directory file transport is raw binary; multipart and $_FILES are not used for chunks.
chunk_js = js[js.index("const prepared = await jsonRequest('local_stage_chunk_prepare'"):js.index("completedBytes += chunkBytes")]
assert "new FormData()" not in chunk_js
assert "binaryRequest('local_stage_file'" in chunk_js
assert "files: chunkFiles.map" in chunk_js
assert "relative_path: chunkPaths[i]" in chunk_js
assert "xhr.send(file)" in js
assert js.count("xhr.send(form);") == 1
print('git_upload_chunk_sequence_transport_test: PASS')
