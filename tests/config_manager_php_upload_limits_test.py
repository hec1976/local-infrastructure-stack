#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
stack = (root / "teko-stack.conf").read_text(encoding="utf-8")
setup = (root / "setup_config_manager.sh").read_text(encoding="utf-8")
ui = (root / "config-manager-standalone/public/git_upload.php").read_text(encoding="utf-8")
js = (root / "config-manager-standalone/public/assets/js/git_upload.js").read_text(encoding="utf-8")

expected = {
    "CONFIG_MANAGER_PHP_POST_MAX_SIZE": "640M",
    "CONFIG_MANAGER_PHP_UPLOAD_MAX_FILESIZE": "512M",
    "CONFIG_MANAGER_PHP_MAX_FILE_UPLOADS": "2000",
    "CONFIG_MANAGER_PHP_MAX_INPUT_VARS": "10000",
    "CONFIG_MANAGER_PHP_MAX_EXECUTION_TIME": "600",
    "CONFIG_MANAGER_PHP_MAX_INPUT_TIME": "600",
}
for key, val in expected.items():
    assert f'{key}="${{{key}:-{val}}}"' in stack, (key, val)

for line in [
    'php_admin_value post_max_size ${CONFIG_MANAGER_PHP_POST_MAX_SIZE}',
    'php_admin_value upload_max_filesize ${CONFIG_MANAGER_PHP_UPLOAD_MAX_FILESIZE}',
    'php_admin_value max_file_uploads ${CONFIG_MANAGER_PHP_MAX_FILE_UPLOADS}',
    'php_admin_value max_input_vars ${CONFIG_MANAGER_PHP_MAX_INPUT_VARS}',
]:
    assert line in setup
assert setup.index('php_admin_value max_file_uploads') < setup.index('<Directory $TARGET_DIR/public>')
assert 'validate_php_size CONFIG_MANAGER_PHP_POST_MAX_SIZE' in setup
assert 'validate_php_uint CONFIG_MANAGER_PHP_MAX_FILE_UPLOADS' in setup
assert 'validate_php_uint CONFIG_MANAGER_PHP_MAX_INPUT_VARS' in setup

# GUI zeigt Runtime-Werte nur noch unter eingeklappten technischen Details.
assert "ini_get('upload_max_filesize')" in ui
assert "ini_get('post_max_size')" in ui
assert "ini_get('max_file_uploads')" in ui
assert "PHP SAPI" in ui
assert "Technische Details" in ui
assert "git-upload-status-grid" not in ui

# Verzeichnis-Uploads nutzen kleine JSON-Plaene und binaere Einzeldatei-Streams; PHP-Multipart-Limits gelten nur fuer ZIP/single request.
assert "'directoryChunkFiles' => 10" in ui
assert "stageDirectoryChunked" in js
assert "local_stage_begin" in js and "local_stage_chunk_prepare" in js and "local_stage_file" in js and "local_stage_finalize" in js
assert "Math.min(Number(cfg.directoryChunkFiles || 10), 20)" in js

print("config_manager_php_upload_limits_test: PASS")
