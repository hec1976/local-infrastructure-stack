from pathlib import Path
root = Path(__file__).resolve().parents[1]
agent = (root/'config-agent/lib/PlatformBaseline.pm').read_text()
ui = (root/'config-manager-standalone/public/client_baseline.php').read_text()

# Monit passwords are always quoted. This avoids numeric-only credentials being
# parsed as a numeric token by Monit's configuration parser.
assert 'allow $user:\\"$password\\"' in agent
assert 'allow $user:$password\\n' not in agent

# A normal Baseline status refresh must not run package repository searches.
info = agent.split('sub _pb_info {',1)[1].split("get '/baseline/info'",1)[0]
assert "_pb_package_state('monit',0)" in info
assert "_pb_package_state('alloy',0)" not in info
assert '_pkg_preview' not in info

# Ab 3.17 ist die Baseline nur noch Monit-Zugang; Software-Rollout erfolgt ueber Git Deploy.
assert 'Repository + Baseline-Pakete installieren' not in ui
assert 'observability-client' in ui
assert 'saveAlloy' not in ui
print('baseline_3143_monit_speed_regression_test: OK')
