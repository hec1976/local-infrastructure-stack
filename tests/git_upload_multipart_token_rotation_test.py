from pathlib import Path
p = Path(__file__).resolve().parents[1] / 'config-manager-standalone' / 'Repository' / 'ConfigManagerRepository.php'
s = p.read_text()
start = s.index('private function callMultipartApi')
end = s.index('public function getGitUploadInfo', start)
block = s[start:end]
assert '$this->reloadServerTokenFromFile();' in block
assert "if ($code === 401 && $this->reloadServerTokenFromFile())" in block
assert "$headers[0] = 'X-API-Token: ' . ($this->server['token'] ?? '');" in block
assert '$opts[CURLOPT_FRESH_CONNECT] = true;' in block
assert block.count('curl_exec($ch)') >= 2
print('git_upload_multipart_token_rotation_test: PASS')
