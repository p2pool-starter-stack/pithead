# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# apply finishes a caddy restart an earlier, interrupted apply left pending (#3332). Reuses the
# sandbox recovery.sh leaves converged ($A: committed .env, no apply-incomplete marker).
echo "== black-box: apply finishes a pending caddy restart (#3332) =="
caddy_pending_markers() { find "$A" -maxdepth 1 -name '.env.caddy-restart-pending' -o -name '.env.apply-incomplete' | wc -l; }
# Interrupted after the marker was armed, before apply-incomplete existed: .env is unchanged.
: >"$A/.env.caddy-restart-pending"
: >"$A/docker.log"
(cd "$A" && DOCKER_LOG="$A/docker.log" PATH="$A/bin:$PATH" ./pithead apply -y) >"$A/apply.out" 2>&1
rc=$?
assert_rc "no-change apply with a pending caddy restart succeeds" "$rc" "0"
assert_contains "no-change apply restarts the caddy an interrupted apply never restarted" "$(cat "$A/docker.log")" "compose restart caddy"
assert_eq "no-change apply clears the caddy-restart marker" "$(caddy_pending_markers)" "0"
# Pending restart plus an unrelated .env change: the Caddyfile re-renders identically, yet caddy restarts.
: >"$A/.env.caddy-restart-pending"
: >"$A/docker.log"
jq '.monero.out_peers = 49' "$A/config.json" >"$A/config.json.new" && mv "$A/config.json.new" "$A/config.json"
(cd "$A" && DOCKER_LOG="$A/docker.log" PATH="$A/bin:$PATH" ./pithead apply -y) >"$A/apply.out" 2>&1
rc=$?
assert_rc "apply with a pending caddy restart and an unrelated change succeeds" "$rc" "0"
assert_contains "the unrelated-change apply still restarts caddy" "$(cat "$A/docker.log")" "compose restart caddy"
assert_eq "the unrelated-change apply clears the caddy-restart marker" "$(caddy_pending_markers)" "0"
