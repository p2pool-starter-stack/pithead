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
IT_MONERO_VIEW_KEY="deadbeef"
IT_TARI_VIEW_KEY="tvk"
resolve_overrides "payout_confirm=env"
assert_rc "payout confirm still ok with the monero key and one tari var" "$?" "0"
unset IT_MONERO_VIEW_KEY
resolve_overrides "payout_confirm=env"
assert_rc "one tari env var alone does not enable the row (#2731)" "$?" "1"
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

# The leg: a wallet whose argv names the public fallback, or a birthday other than the configured
# one, fails; the local argv with payouts found passes.
env_on_box() { echo true; }
wait_for() { return 0; }
STUB_ARGV=""
rx() {
    case "$1" in
    *cmdline*) printf '%s' "$STUB_ARGV" | tr ' ' '\0' ;;
    *net/tcp*) printf '%s\n' "$PT" | head -3 ;;
    *api/state*) echo '{"earnings":{"tari_confirmed":{"enabled":true,"count":39}}}' ;;
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
got="$(run_leg "${LOCAL_ARGV%%-p *}-p wallet.fallback_http_server_url=https://rpc.tari.com")"
assert_ne "public fallback fails the leg" "${got#* }" "0"
got="$(run_leg "${LOCAL_ARGV/1425/20000}")"
assert_ne "a birthday other than the configured one fails the leg" "${got#* }" "0"

echo "selftest-tari-wallet: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
