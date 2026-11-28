#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck disable=SC2034
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-state.sh
source "$HERE/lib/run-state.sh"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

echo "== The probe's own logic =="
if python3 "$HERE/lib/purpose-circuit-probe.py" --self-test; then
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
    [ -z "$PROBE_VERDICT" ] || printf '%s\n' "$PROBE_VERDICT"
    return "$PROBE_RC"
}

echo "== The row passes only on exit 0 plus the probe's verdict =="
PROBE_RC=0
PROBE_VERDICT="purposes exit distinct circuits"
run_row
assert_eq "a probe exit 0 passes the purpose-circuit row" "$row_failed" 0
assert_contains "the row ships the probe through the dashboard image on mining_net" \
    "$(cat "$TD/command")" "--network mining_net"
assert_contains "the row hands the probe the Tor SOCKS proxy" "$(cat "$TD/command")" "TOR_SOCKS_PROXY=socks5h://"

payload="$(base64 <"$HERE/lib/purpose-circuit-probe.py" | tr -d '\n')"
assert_contains "the row ships the real probe file" "$(cat "$TD/command")" "${payload:0:60}"

PROBE_RC=0
PROBE_VERDICT=""
run_row
assert_eq "an exit 0 without the probe's own verdict line fails the row" "$row_failed" 1

PROBE_RC=1
PROBE_VERDICT="purposes did not get distinct exits"
run_row
assert_eq "a probe exit 1 fails the purpose-circuit row" "$row_failed" 1
assert_contains "the failure carries the probe's own output" "$(cat "$TD/row.log")" "health: v4"

[ "$IT_FAIL" -eq 0 ]
