#!/usr/bin/env bash
set -uo pipefail
echo "== Tari pre-upgrade identity read =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
eval "$(sed -n '/^tari_error_summary() {/,/^}/p;/^tari_block_identity_checked() {/,/^}/p;/^chain_identity_failure_detail() {/,/^}/p' "$HERE/lib/live-tari-identity.sh")"
td="$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/tari-id.XXXXXX")"
trap 'rm -rf "$td"' EXIT
TARI_IDENTITY="" TARI_IDENTITY_ERROR=""
sleep() { :; }
bump() { echo x >>"$td/c"; }
count() { wc -l <"$td/c" | tr -d ' '; }
reset_calls() { : >"$td/c"; }
good="12 $(printf 'ab%.0s' {1..32})"
denied=$'Traceback (most recent call last):\ngrpc._channel._InactiveRpcError: <_InactiveRpcError of RPC that terminated with:\n\tstatus = StatusCode.PERMISSION_DENIED\n\tdetails = "ListHeaders method not made available"\n\tdebug_error_string = "UNKNOWN:Error received from peer ipv4:10.1.2.3:18142"\n>'

reset_calls
tari_identity_remote() {
    bump
    if [ "$(count)" -lt 3 ]; then echo "$denied"; else echo "$good"; fi
}
tari_block_identity_checked 12
assert_eq "a transient Tari failure is retried and then read" "$TARI_IDENTITY|$(count)" "$good|3"

reset_calls
tari_identity_remote() {
    bump
    echo "$denied"
}
if tari_block_identity_checked 12; then it_fail "a persistent Tari refusal fails the read"; else it_pass "a persistent Tari refusal fails the read"; fi
assert_eq "the read is bounded to three attempts" "$(count)" "3"
case "$TARI_IDENTITY_ERROR" in
*PERMISSION_DENIED*"ListHeaders method not made available"*) it_pass "the captured error names the refusal" ;;
*) it_fail "the captured error names the refusal" "$TARI_IDENTITY_ERROR" ;;
esac
case "$TARI_IDENTITY_ERROR" in
*10.1.2.3*) it_fail "the captured error masks addresses" "$TARI_IDENTITY_ERROR" ;;
*) it_pass "the captured error masks addresses" ;;
esac

tari_identity_remote() { echo "StopIteration"; }
tari_block_identity_checked 12 || true
assert_eq "a StopIteration from an empty stream is captured" "$TARI_IDENTITY_ERROR" "attempt 3/3: StopIteration"

tari_identity_remote() { printf 'Warning: noise\n%s\n' "$good"; }
tari_block_identity_checked 12
assert_eq "stderr noise next to a valid identity does not fail the read" "$TARI_IDENTITY" "$good"

tari_identity_remote() { :; }
tari_block_identity_checked 12 || true
assert_eq "a silent empty read says there was no output" "$TARI_IDENTITY_ERROR" "attempt 3/3: no output"

dns=$'status = StatusCode.UNAVAILABLE\ndetails = "DNS resolution failed for tari-node.lab.example:18142: C-ares status is not ARES_SUCCESS"\ndebug_error_string = "name=tari-node.lab.example [::1]:18142"'
tari_identity_remote() { echo "$dns"; }
tari_block_identity_checked 12 || true
case "$TARI_IDENTITY_ERROR" in
    *lab.example* | *18142*) it_fail "hostnames and ports are masked" "$TARI_IDENTITY_ERROR" ;;
    *) it_pass "hostnames and ports are masked" ;;
esac

TARI_IDENTITY_ERROR="attempt 3/3: status = StatusCode.PERMISSION_DENIED"
assert_eq "the failure detail names Tari, the height and the error" \
    "$(chain_identity_failure_detail "$good" "" 12)" \
    "could not read: Tari block at height 12 (ListHeaders: attempt 3/3: status = StatusCode.PERMISSION_DENIED); upgrade not attempted"
assert_eq "the failure detail names Monero when only Monero is missing" \
    "$(chain_identity_failure_detail "" "$good" 12)" \
    "could not read: Monero tip hash (get_info returned none); upgrade not attempted"
