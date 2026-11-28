#!/usr/bin/env bash
#
# Self-test for the Tari payout-scan leg (run-tari-wallet.sh, #2731), driven as pure functions
# against a stubbed rx: no bench, no containers. Standalone, like the other run-*.sh self-tests.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-tari-wallet.sh
source "$HERE/../lib/run-tari-wallet.sh"

echo "== selftest: Tari payout-scan leg (#2731) =="
# Every incomplete fixture set must remain a missing-fixture verdict (#2885).
for mask in 0 1 2 3 4 5 6 7; do
    unset IT_MONERO_VIEW_KEY IT_TARI_VIEW_KEY IT_TARI_SPEND_PUBLIC_KEY
    keys=(IT_MONERO_VIEW_KEY IT_TARI_VIEW_KEY IT_TARI_SPEND_PUBLIC_KEY)
    for i in 0 1 2; do
        if ((mask & (1 << i))); then
            printf -v "${keys[$i]}" '%064d' "$((i + 1))"
        fi
    done
    resolve_overrides "payout_confirm=env"
    rc=$?
    if [ "$mask" -eq 7 ]; then
        assert_rc "all payout fixtures enable the row (#2885)" "$rc" 0
        for key in "${keys[@]}"; do
            assert_contains "$key reaches overrides" "$RESOLVED" "${!key}"
        done
        assert_contains "Tari birthday remains configured (#2731)" "$RESOLVED" "tari.payout_scan_birthday=1425"
    else
        assert_rc "fixture set $mask cannot enable the row (#2885)" "$rc" 1
        assert_eq "fixture set $mask has missing verdict" "$SKIP_CLASS" missing
        for key in "${keys[@]}"; do
            if [ -z "${!key:-}" ]; then
                assert_contains "fixture set $mask names absent $key" "$SKIP_REASON" "$key"
            else
                assert_eq "fixture set $mask never logs $key" "${SKIP_REASON//${!key}/}" "$SKIP_REASON"
            fi
        done
    fi
done
unset IT_MONERO_VIEW_KEY IT_TARI_VIEW_KEY IT_TARI_SPEND_PUBLIC_KEY

# /proc/net/tcp remotes: loopback and bridge peers are local, a public address is not.
PT='  sl  local_address rem_address   st
   0: 1F00A8C0:C350 1B001CAC:2328 01
   1: 0100007F:C351 0100007F:465E 01
   2: 1F00A8C0:C352 00000000:0000 0A
   3: 1F00A8C0:C353 08080808:01BB 01'
assert_eq "public_remotes_in_proc_tcp flags only the public peer" "$(public_remotes_in_proc_tcp "$PT")" "8.8.8.8"
assert_eq "public_remotes_in_proc_tcp: all-local is empty" "$(public_remotes_in_proc_tcp "$(printf '%s\n' "$PT" | head -4)")" ""

# The leg: a wallet whose argv names the public fallback or another host, a birthday other than the
# configured one, or an unreadable socket table fails; the local argv with payouts found passes.
env_on_box() { case "$1" in TARI_GRPC_ADDRESS) echo 172.28.0.27:18142 ;; *) echo true ;; esac }
wait_for() { return 0; }
STUB_ARGV="" STUB_TCP_RC=0 STUB_HEALTH_RC=0 STUB_MARKER_RC=0 STUB_CMDS="$(mktemp)"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39,"reachable":true,"address_match":true},"confirmed":{"reachable":true,"address_match":true}}}'
rx() {
    case "$1" in
    *cmdline*)
        printf '%s\n' "$1" >>"$STUB_CMDS"
        printf '%s ' "$STUB_ARGV" | tr ' ' '\0'
        ;;
    *net/tcp*)
        [ "$STUB_TCP_RC" -eq 0 ] || return "$STUB_TCP_RC"
        printf '%s\n' "$PT" | head -3
        ;;
    *PAYOUT_SCAN_GRACE_SEC=0*) return "$STUB_HEALTH_RC" ;;
    *'.payout-scanning'*) return "$STUB_MARKER_RC" ;;
    *api/state*) echo "$STUB_STATE" ;;
    esac
}
CFG='{"tari":{"view_key":"k","payout_scan_birthday":"1425"}}'
ST='{"earnings":{"tari_confirmed":{"enabled":true,"count":0}}}'
LOCAL_ARGV="minotari_console_wallet --birthday 1425 -p wallet.http_server_url=http://172.28.0.27:9000 -p wallet.fallback_http_server_url=http://172.28.0.27:9000"

run_leg() { # <argv> -> "<pass> <fail>" added by one leg run
    local p0=$IT_PASS f0=$IT_FAIL
    STUB_ARGV="$1"
    assert_tari_payout_scan "$CFG" "$ST" >/dev/null
    local p=$((IT_PASS - p0)) f=$((IT_FAIL - f0))
    IT_PASS=$p0 IT_FAIL=$f0
    echo "$p $f"
}
got="$(run_leg "$LOCAL_ARGV")"
assert_eq "local argv, payouts found: every row passes" "${got#* }" "0"
assert_rc "real-wallet status predicate accepts reachable matching Tari" "$(
    _pred_payout_wallet_ready tari_confirmed
    echo $?
)" "0"
assert_rc "real-wallet status predicate accepts reachable matching Monero" "$(
    _pred_payout_wallet_ready confirmed
    echo $?
)" "0"
STUB_MARKER_RC=0
assert_rc "a Monero wallet with no scan marker counts as caught up" "$(
    _pred_monero_wallet_caught_up
    echo $?
)" "0"
STUB_MARKER_RC=1
assert_rc "a Monero wallet still holding its scan marker is not caught up" "$(
    _pred_monero_wallet_caught_up
    echo $?
)" "1"
STUB_MARKER_RC=0
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39,"reachable":false,"address_match":true}}}'
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "unreachable Tari wallet fails the payout leg" "${got#* }" "0"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39,"reachable":true,"address_match":false}}}'
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "Tari address mismatch fails the payout leg" "${got#* }" "0"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39}}}'
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "missing real-wallet verdict fails the payout leg" "${got#* }" "0"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39,"reachable":true,"address_match":true},"confirmed":{"reachable":true,"address_match":true}}}'
STUB_HEALTH_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "failed real-image gRPC probe fails the payout leg" "${got#* }" "0"
STUB_HEALTH_RC=0 STUB_MARKER_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "first-scan marker left behind fails the payout leg" "${got#* }" "0"
STUB_MARKER_RC=0
# Under the init (#2657) the wallet is not PID 1: the leg reads every process's argv, never /proc/1 alone.
assert_num_ge "the argv read covers every process (#2657)" "$(grep -c '/proc/\[0-9\]\*/cmdline' "$STUB_CMDS")" 1
assert_eq "the argv read never uses only PID 1 (#2657)" "$(grep -c '/proc/1/' "$STUB_CMDS")" "0"
got="$(run_leg "${LOCAL_ARGV%%-p *}-p wallet.fallback_http_server_url=https://rpc.tari.com")"
assert_ne "public fallback fails the leg" "${got#* }" "0"
got="$(run_leg "${LOCAL_ARGV/1425/20000}")"
assert_ne "a birthday other than the configured one fails the leg" "${got#* }" "0"
got="$(run_leg "${LOCAL_ARGV//172.28.0.27/172.28.0.99}")"
assert_ne "a scan URL on another host fails the leg" "${got#* }" "0"
STUB_TCP_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_eq "an unreadable socket table fails the no-public-peer row" "${got#* }" "1"
STUB_TCP_RC=0

echo "selftest-tari-wallet: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
