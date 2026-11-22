#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck disable=SC2034 # run-state module source guard
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-state.sh
source "$HERE/../lib/run-state.sh"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

if python3 "$HERE/../lib/purpose-circuit-probe.py" --self-test; then
    it_pass "purpose circuit probe self-test"
else
    it_fail "purpose circuit probe self-test"
fi

run_row() {
    local before=$IT_FAIL
    assert_purpose_circuits >"$TD/row.log" 2>&1
    row_failed=$((IT_FAIL - before))
    IT_FAIL=$before
}

rx() {
    printf '%s\n' "$1" >"$TD/command"
    printf '%s\n' "health: v4" "notify: v4"
    return "$PROBE_RC"
}

PROBE_RC=0
run_row
assert_eq "a probe exit 0 passes the purpose-circuit row" "$row_failed" 0
assert_contains "the row ships the probe through the dashboard image on mining_net" \
    "$(cat "$TD/command")" "--network mining_net"
assert_contains "the row hands the probe the Tor SOCKS proxy" "$(cat "$TD/command")" "TOR_SOCKS_PROXY=socks5h://"

PROBE_RC=1
run_row
assert_eq "a probe exit 1 fails the purpose-circuit row" "$row_failed" 1
assert_contains "the failure carries the probe's own output" "$(cat "$TD/row.log")" "health: v4"

[ "$IT_FAIL" -eq 0 ]
