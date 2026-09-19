from pathlib import Path
s=(Path(__file__).resolve().parents[1]/'baseline-repository/scripts/prepare_repository.sh').read_text()
assert 'zypper --non-interactive download "$pkg"' in s
assert '--directory' not in '\n'.join(line for line in s.splitlines() if 'zypper ' in line and 'download' in line)
assert 'copy_downloaded_pkg_from_zypp_cache' in s
print('baseline_3162_repository_download_regression_test: PASS')
