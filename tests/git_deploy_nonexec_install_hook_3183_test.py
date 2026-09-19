from pathlib import Path
root=Path(__file__).resolve().parents[1]
s=(root/'config-agent/lib/GitDeploy.pm').read_text()
assert "sub _expand_fixed_argv" in s
assert "allow_nonexec_shell" in s
needle="_expand_fixed_argv($spec->{argv}, $release, $commit, $target, {allow_nonexec_shell=>1})"
assert needle in s, 'post_deploy must allow repository-created 0644 shell hooks during argv expansion'
assert "unless $program_real =~ /\\.sh\\z/" in s, 'fallback must remain limited to .sh hooks'
assert "$argv = ['/bin/bash', $program_real" in s, 'non-executable shell hook must be run explicitly via /bin/bash'
assert "post_deploy-Programm verlaesst das aktive Release" in s, 'release boundary validation must remain enforced'
print('git_deploy_nonexec_install_hook_3183_test: PASS')
