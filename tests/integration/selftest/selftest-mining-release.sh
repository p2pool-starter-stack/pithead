#!/usr/bin/env bash
# The running-state battery must sample both miners after the post-restart sync gate releases them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-state.sh
source "$HERE/../lib/run-state.sh"

echo "== mining services release after the sync gate before running-state assertions =="

WAIT_LOG="$(mktemp)"
trap 'rm -f "$WAIT_LOG"' EXIT

state_source="$HERE/../lib/run-state.sh"
wait_line="$(grep -n 'p2pool and xmrig-proxy after sync gate' "$state_source" | cut -d: -f1)"
uid_line="$(grep -nm1 'assert_eq "runtime uid of' "$state_source" | cut -d: -f1)"
tls_line="$(grep -n 'assert_ne "stratum TLS handshake' "$state_source" | cut -d: -f1)"
if [ -n "$wait_line" ] && [ -n "$uid_line" ] && [ -n "$tls_line" ] &&
    [ "$wait_line" -lt "$uid_line" ] && [ "$wait_line" -lt "$tls_line" ]; then
    it_pass "release wait precedes UID and TLS probes"
else
    it_fail "release wait precedes UID and TLS probes"
    exit 1
fi

run_case() (
    STAGE="$1"
    jq_get() { case "$2" in .monero.mode | .tari.mode) echo local ;; *) echo false ;; esac }
    clearnet_flag_effective() { echo false; }
    docker() {
        [ "$*" = 'compose ps --services --status running' ] || return 2
        case "$STAGE" in ready) printf 'p2pool\nxmrig-proxy\n' ;; one) echo p2pool ;; esac
    }
    rx() { eval "$1"; }
    running_services() { rx 'docker compose ps --services --status running'; }
    expected_services() { printf 'p2pool\nxmrig-proxy\n'; }
    wait_for() {
        printf '%s %s %s\n' "$1" "$2" "$4" >"$WAIT_LOG"
        if "$4" "$5"; then
            echo ready >>"$WAIT_LOG"
            return 0
        fi
        if [ "$STAGE" = delayed ]; then
            STAGE=ready
            if "$4" "$5"; then
                echo ready >>"$WAIT_LOG"
                return 0
            fi
        fi
        echo timeout >>"$WAIT_LOG"
        return 1
    }
    it_pass() {
        [ "${PASSES:=0}" -lt 1 ] || exit 0
        PASSES=$((PASSES + 1))
    }
    it_fail() { exit 9; }
    assert_running_state subnet '{}'
    exit 8
)

: >"$WAIT_LOG"
run_case delayed
assert_eq "delayed release passes both container rows" "$?" 0
assert_eq "running-state battery waits on both services with a bounded poll" "$(cat "$WAIT_LOG")" \
    "1500 5 rx
ready"

: >"$WAIT_LOG"
run_case never
assert_eq "a persistent hold still fails a binding container row" "$?" 9
assert_eq "persistent hold gets the same bounded wait" "$(cat "$WAIT_LOG")" \
    "1500 5 rx
timeout"

: >"$WAIT_LOG"
run_case one
assert_eq "one released miner does not satisfy the wait" "$?" 9
assert_eq "both miners are required to finish the wait" "$(tail -1 "$WAIT_LOG")" timeout

[ "$IT_FAIL" -eq 0 ]
