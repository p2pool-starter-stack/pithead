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
# The payout row's gate: the Tari pair alone enables it, with a past birthday; one var does not.
unset IT_MONERO_VIEW_KEY IT_TARI_VIEW_KEY IT_TARI_SPEND_PUBLIC_KEY
# shellcheck disable=SC2034  # consumed by resolve_overrides from lib.sh
IT_MONERO_VIEW_KEY="deadbeef"
# shellcheck disable=SC2034  # consumed by resolve_overrides from lib.sh
IT_TARI_VIEW_KEY="tvk"
resolve_overrides "payout_confirm=env"
assert_rc "payout confirm still ok with the monero key and one tari var" "$?" "0"
unset IT_MONERO_VIEW_KEY
resolve_overrides "payout_confirm=env"
assert_rc "one tari env var alone does not enable the row (#2731)" "$?" "1"
# shellcheck disable=SC2034  # consumed by resolve_overrides from lib.sh
IT_TARI_SPEND_PUBLIC_KEY="tspk"
resolve_overrides "payout_confirm=env"
assert_rc "the tari pair alone enables the row (#2731)" "$?" "0"
assert_eq "no monero key without IT_MONERO_VIEW_KEY" "${RESOLVED/monero.view_key/}" "$RESOLVED"
assert_contains "augments tari.view_key" "$RESOLVED" "tari.view_key=tvk"
assert_contains "augments tari.spend_public_key and a past birthday (#2731)" "$RESOLVED" "tari.spend_public_key=tspk tari.payout_scan_birthday=1425"
unset IT_TARI_VIEW_KEY IT_TARI_SPEND_PUBLIC_KEY

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
STUB_SYNC_RC=0 STUB_GRPC_RC=0 STUB_PAYOUT_RC=0
wait_for() {
    case "$3" in
    *"node reaches chain tip"*) return "$STUB_SYNC_RC" ;;
    *"answers gRPC scans"*) return "$STUB_GRPC_RC" ;;
    *"reports the known past payouts"*) return "$STUB_PAYOUT_RC" ;;
    *) return 0 ;;
    esac
}
STUB_ARGV="" STUB_TCP_RC=0 STUB_HEALTH_RC=0 STUB_MARKER_RC=0 STUB_CMDS="$(mktemp)" STUB_OUT="$(mktemp)" STUB_NAMES="$(mktemp)"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39,"reachable":true,"address_match":true},"confirmed":{"reachable":true,"address_match":true}},"sync":{"tari":{"state":"done","current":384765,"target":384765}}}'
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

run_leg() { # <argv> -> "<pass> <fail> <skipped>" added by one leg run
    local p0=$IT_PASS f0=$IT_FAIL s0=$IT_SKIPPED_LEGS
    STUB_ARGV="$1"
    assert_tari_payout_scan "$CFG" "$ST" >"$STUB_OUT" 2>&1
    printf '%s' "$IT_SKIPPED_NAMES" >"$STUB_NAMES"
    echo "$((IT_PASS - p0)) $((IT_FAIL - f0)) $((IT_SKIPPED_LEGS - s0))"
}
fails_of() { printf '%s\n' "$1" | awk '{print $2}'; }
skips_of() { printf '%s\n' "$1" | awk '{print $3}'; }
got="$(run_leg "$LOCAL_ARGV")"
assert_eq "local argv, payouts found: every row passes" "$(fails_of "$got")" "0"
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
assert_ne "unreachable Tari wallet fails the payout leg" "$(fails_of "$got")" "0"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39,"reachable":true,"address_match":false}}}'
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "Tari address mismatch fails the payout leg" "$(fails_of "$got")" "0"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39}}}'
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "missing real-wallet verdict fails the payout leg" "$(fails_of "$got")" "0"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39,"reachable":true,"address_match":true},"confirmed":{"reachable":true,"address_match":true}},"sync":{"tari":{"state":"done","current":384765,"target":384765}}}'
STUB_HEALTH_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "failed real-image gRPC probe fails the payout leg" "$(fails_of "$got")" "0"
STUB_HEALTH_RC=0 STUB_MARKER_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "first-scan marker left behind fails the payout leg" "$(fails_of "$got")" "0"
STUB_MARKER_RC=0
STUB_HEALTH_RC=1
assert_rc "the wallet gRPC predicate refuses an unreachable probe (#4031)" "$(
    _pred_tari_wallet_grpc
    echo $?
)" "1"
STUB_HEALTH_RC=0
assert_rc "the wallet gRPC predicate accepts a zero-grace probe (#4031)" "$(
    _pred_tari_wallet_grpc
    echo $?
)" "0"
assert_rc "the node predicate is true at chain tip (#4031)" "$(
    _pred_tari_node_synced
    echo $?
)" "0"
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":0,"reachable":true,"address_match":true}},"sync":{"tari":{"state":"syncing","current":100,"target":384765}}}'
assert_rc "the node predicate is false while syncing (#4031)" "$(
    _pred_tari_node_synced
    echo $?
)" "1"
assert_contains "the payout note carries wallet and node observations (#4031)" "$(_tari_payout_scan_note)" "wallet reachable=true address_match=true; tari node syncing 100/384765"
STUB_SYNC_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_eq "a node that never reaches tip skips the past-payout leg (#4031)" "$(skips_of "$got")" "1"
assert_eq "the not-at-tip skip costs the leg no failure (#4031)" "$(fails_of "$got")" "0"
assert_eq "the not-at-tip skip is by design and names the row (#4031)" "$(grep -c '\[by-design\].*Tari wallet finds known past payouts' "$STUB_NAMES")" "1"
assert_contains "the skip names the node reading and the birthday range (#4031)" "$(cat "$STUB_OUT")" "tari node syncing 100/384765 after 900s"
assert_eq "the skip never runs the payout wait (#4031)" "$(grep -c 'still 0 after' "$STUB_OUT")" "0"
STUB_SYNC_RC=0
STUB_STATE='{"earnings":{"tari_confirmed":{"enabled":true,"count":39,"reachable":true,"address_match":true},"confirmed":{"reachable":true,"address_match":true}},"sync":{"tari":{"state":"done","current":384765,"target":384765}}}'
STUB_GRPC_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "a wallet that never answers a gRPC scan fails the past-payout row (#4031)" "$(fails_of "$got")" "0"
assert_contains "the failure names the wallet precondition (#4031)" "$(cat "$STUB_OUT")" "never answered a gRPC scan within 1800s"
assert_eq "the wallet precondition failure is not dressed as a payout timeout (#4031)" "$(grep -c 'still 0 after' "$STUB_OUT")" "0"
STUB_GRPC_RC=0
STUB_PAYOUT_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_ne "no past payouts within the extended wait fails the row (#4031)" "$(fails_of "$got")" "0"
assert_contains "the payout failure reports the extended wait (#4031)" "$(cat "$STUB_OUT")" "tari_confirmed.count still 0 after 5400s"
assert_contains "the payout failure carries live observations (#4031)" "$(cat "$STUB_OUT")" "tari node done 384765/384765"
STUB_PAYOUT_RC=0
# Under the init (#2657) the wallet is not PID 1: the leg reads every process's argv, never /proc/1 alone.
assert_num_ge "the argv read covers every process (#2657)" "$(grep -c '/proc/\[0-9\]\*/cmdline' "$STUB_CMDS")" 1
assert_eq "the argv read never uses only PID 1 (#2657)" "$(grep -c '/proc/1/' "$STUB_CMDS")" "0"
got="$(run_leg "${LOCAL_ARGV%%-p *}-p wallet.fallback_http_server_url=https://rpc.tari.com")"
assert_ne "public fallback fails the leg" "$(fails_of "$got")" "0"
got="$(run_leg "${LOCAL_ARGV/1425/20000}")"
assert_ne "a birthday other than the configured one fails the leg" "$(fails_of "$got")" "0"
got="$(run_leg "${LOCAL_ARGV//172.28.0.27/172.28.0.99}")"
assert_ne "a scan URL on another host fails the leg" "$(fails_of "$got")" "0"
STUB_TCP_RC=1
got="$(run_leg "$LOCAL_ARGV")"
assert_eq "an unreadable socket table fails the no-public-peer row" "$(fails_of "$got")" "1"
STUB_TCP_RC=0

echo "selftest-tari-wallet: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
