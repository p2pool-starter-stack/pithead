# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== unit: stack_restart — tari starts after Tor on a bare restart (#4064) =="
ROLOG="$SANDBOX/restart-order-docker.log"
: >"$ROLOG"
DOCKER_LOG="$ROLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart >/dev/null 2>&1
assert_eq "bare restart restarts tari after monerod's re-dial, once Tor is bootstrapped" \
    "$(grep 'compose restart' "$ROLOG" | tr '\n' ',')" \
    "[docker] compose restart,[docker] compose restart monerod,[docker] compose restart tari,"
: >"$ROLOG"
DOCKER_LOG="$ROLOG" TARI_RUNNING='' PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart >/dev/null 2>&1
assert_not_contains "a stack without a tari container never restarts tari" "$(cat "$ROLOG")" "compose restart tari"
: >"$ROLOG"
DOCKER_LOG="$ROLOG" TARI_RUNNING=false PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart >/dev/null 2>&1
assert_contains "a tari that exited during the restart is restarted after Tor too" "$(cat "$ROLOG")" "compose restart tari"
: >"$ROLOG"
DOCKER_LOG="$ROLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart tor >/dev/null 2>&1
assert_not_contains "restart tor leaves tari alone" "$(cat "$ROLOG")" "compose restart tari"
: >"$ROLOG"
DOCKER_LOG="$ROLOG" TOR_HEALTH=starting PITHEAD_TOR_REDIAL_POLLS=1 PITHEAD_TOR_REDIAL_POLL_S=0 PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart >/dev/null 2>&1
assert_not_contains "tari is not restarted against an unbootstrapped Tor" "$(cat "$ROLOG")" "compose restart tari"
