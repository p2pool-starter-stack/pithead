#!/usr/bin/env bash
#
# Self-test for the clearnet-sync scenario's egress-firewall handling (#2649).
#
# With the egress firewall on, render_env ignores clearnet_initial_sync, so the matrix's clearnet
# scenario must turn the firewall off to show a real clearnet sync and the #234 transition back to
# Tor. It must also turn the firewall back on before it ends: restore_firewall_after_clearnet
# re-applies the same config with only the firewall flipped, then checks the rules, the zeroed .env
# flags and the completed sync's markers. These cases pin that step against stubs, so a live
# matrix run is not the first place a broken restore shows up.
#
# Pure logic only (no server, no docker), run by `make test-integration-selftest`.
#
# Run: tests/integration/selftest/selftest-clearnet-firewall.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/scenarios.sh
source "$HERE/../scenarios.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-matrix.sh
source "$HERE/../lib/run-matrix.sh"

echo "== clearnet scenario runs with the egress firewall off (#2649) =="
ovr="$(scenario_overrides local-pruned-main-clearnet-sync)"
assert_contains "the clearnet scenario turns the egress firewall off" "$ovr" "network.tor_egress_firewall=false"
others="$(scenario_matrix | grep -v '^local-pruned-main-clearnet-sync' | grep -v '^local-pruned-main-firewall-off' | grep -c 'tor_egress_firewall' || true)"
assert_eq "no other scenario turns the firewall off" "$others" "0"

echo "== clearnet_flag_effective: the flag counts only with the firewall off (#2649) =="
assert_eq "flag true + firewall false -> effective, firewall absent -> not" \
    "$(clearnet_flag_effective '{"monero":{"clearnet_initial_sync":true},"network":{"tor_egress_firewall":false}}' monero) $(clearnet_flag_effective '{"monero":{"clearnet_initial_sync":true}}' monero)" "true false"

echo "== restore_firewall_after_clearnet (#2649) =="
# Stubs for the box: a config.json, an .env the fake apply rewrites, and a marker directory.
BOX="$(mktemp -d)"
trap 'rm -rf "$BOX"' EXIT
OUT_DIR="$BOX/out"
IT_REMOTE_DIR="$BOX"
mkdir -p "$OUT_DIR" "$BOX/state"
APPLY_RC=0
DROP_MARKERS=0
push_config() { printf '%s\n' "$1" >"$BOX/config.json"; }
env_on_box() { grep -E "^$1=" "$BOX/.env" 2>/dev/null | head -n1 | cut -d= -f2-; }
rx() { bash -c "$1"; }
wait_status_ok() { :; }
capture_artifacts() { :; }
pithead() {
    case "$1" in
    apply)
        [ "$APPLY_RC" = 0 ] || return 1
        local fw on
        fw="$(jq -r '.network.tor_egress_firewall' "$BOX/config.json")"
        on=false
        [ "$fw" = "false" ] && on=true
        printf 'TOR_EGRESS_FIREWALL=%s\nMONERO_CLEARNET_SYNC=%s\nTARI_CLEARNET_SYNC=%s\nCLEARNET_STATE_DIR=%s\n' \
            "$fw" "$on" "$on" "$BOX/state" >"$BOX/.env"
        [ "$DROP_MARKERS" = 0 ] || rm -f "$BOX/state/"*.synced
        ;;
    doctor)
        [ "$(env_on_box TOR_EGRESS_FIREWALL)" = "true" ] && echo "OK   Tor-only egress firewall is installed"
        ;;
    esac
}
CN='{"monero":{"clearnet_initial_sync":true},"tari":{"clearnet_initial_sync":true},"network":{"tor_egress_firewall":false}}'
fresh_box() {
    printf 'TOR_EGRESS_FIREWALL=false\nMONERO_CLEARNET_SYNC=true\nTARI_CLEARNET_SYNC=true\nCLEARNET_STATE_DIR=%s\n' "$BOX/state" >"$BOX/.env"
    rm -f "$BOX/state/"*.synced "$BOX/config.json"
    : >"$BOX/state/monero.synced"
    : >"$BOX/state/tari.synced"
}
# Run the step, recording the verdicts it reports instead of counting them against this selftest.
run_restore() { # <config> -> prints "P:<row>" / "F:<row>" lines
    (
        it_pass() { printf 'P:%s\n' "$1"; }
        it_fail() { printf 'F:%s\n' "$1"; }
        it_step() { :; }
        restore_firewall_after_clearnet clearnet "$1"
    )
}

fresh_box
got="$(run_restore "$CN")"
assert_eq "the restore pushes the same config with only the firewall back on" \
    "$(jq -c . "$BOX/config.json")" "$(printf '%s' "$CN" | jq -c '.network.tor_egress_firewall = true')"
assert_contains "the restore proves the firewall is installed again" "$got" "P:egress firewall back on after the clearnet sync (#2649)"
assert_contains "the restore proves the monero flag is ignored" "$got" "P:firewall on: monero clearnet flag ignored (#2649)"
assert_contains "the restore proves the tari flag is ignored" "$got" "P:firewall on: tari clearnet flag ignored (#2649)"
assert_contains "the restore proves the monero sync stays spent" "$got" "P:firewall on: the completed monero clearnet sync stays spent (#234/#2649)"
assert_contains "the restore proves the tari sync stays spent" "$got" "P:firewall on: the completed tari clearnet sync stays spent (#234/#2649)"
case "$got" in
*F:*) it_fail "a clean restore reports no failure" "$got" ;;
*) it_pass "a clean restore reports no failure" ;;
esac

# A render that re-arms the completed sync on the firewall toggle must turn the row red.
fresh_box
DROP_MARKERS=1
got="$(run_restore "$CN")"
DROP_MARKERS=0
assert_contains "a marker removed by the firewall-on apply fails the row" "$got" "F:firewall on: the completed monero clearnet sync stays spent (#234/#2649)"

# A marker that never existed is the transition row's failure, not this one's.
fresh_box
rm -f "$BOX/state/monero.synced"
got="$(run_restore "$CN")"
case "$got" in
*"monero clearnet sync stays spent"*) it_fail "no marker before the apply: no survival row for that chain" "$got" ;;
*) it_pass "no marker before the apply: no survival row for that chain" ;;
esac

# A failed apply is reported, and the step stops there.
fresh_box
APPLY_RC=1
got="$(run_restore "$CN")"
APPLY_RC=0
assert_eq "a failed firewall-on apply is one failure row" "$got" "F:egress firewall back on after the clearnet sync (#2649)"

# Any other config is left alone: no push, no apply, no rows.
for other in '{"network":{"tor_egress_firewall":false}}' \
    '{"monero":{"clearnet_initial_sync":true}}' '{}'; do
    fresh_box
    got="$(run_restore "$other")"
    if [ -z "$got" ] && [ ! -e "$BOX/config.json" ]; then
        it_pass "config left alone: $other"
    else
        it_fail "config left alone: $other" "rows [$got], config pushed: $([ -e "$BOX/config.json" ] && echo yes || echo no)"
    fi
done

echo ""
echo "selftest-clearnet-firewall: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
