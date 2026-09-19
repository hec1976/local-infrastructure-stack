from pathlib import Path
s=(Path(__file__).resolve().parents[1]/'baseline-repository/scripts/prepare_repository.sh').read_text()
assert 'copy_downloaded_pkg_from_zypp_cache' in s
assert '/var/cache/zypp/packages' in s
assert "rpm -qp --qf '%{NAME}'" in s
assert 'cp -a "$candidate" "$WORK/repo/"' in s
assert 'zypper --non-interactive download "$pkg"' in s
print('baseline_3164_zypp_cache_regression_test: PASS')
