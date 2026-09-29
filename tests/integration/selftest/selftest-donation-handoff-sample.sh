#!/usr/bin/env bash
# The #2894 timeout sample must identify which read copy is stale without logging credentials.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/rigforge-apply-settle.sh
source "$HERE/../lib/rigforge-apply-settle.sh"
# shellcheck source=tests/integration/lib/rigforge-writable-keys.sh
source "$HERE/../lib/rigforge-writable-keys.sh"

STUB_DETAIL='{"snapshot_at":1790711070.25,"status":"online","rig_config":{"DONATION":1},"history":[{"change_id":"0123456789abcdef","status":"accepted"}],"rigforge":{"generated_at":"2026-09-29T17:04:30Z","stale":true}}'
echo "== DONATION handoff timeout samples =="
_worker_detail() { printf '%s' "$STUB_DETAIL"; }
RIG_HOST=example.test
RIG_CONTROL_PORT=8082
IT_RIG_TOKEN=fixture-secret-never-print
rx() {
    cat >/dev/null # consume curl -K stdin; the token must stay off argv and output
    case "$1" in
    *'/1/summary'*) printf '%s' '{"generated_at":"2026-09-29T17:05:15Z","rigforge":{"config":{"DONATION":0}}}' ;;
    *status*change_id*) printf '%s' '{"change_id":"0123456789abcdef","status":"applied"}' ;;
    esac
}
wait_for() {
    shift 3
    "$@"
    "$@"
    return 1 # model a bounded timeout after two unsuccessful polls
}

log="$(mktemp "$TMPDIR/donation-handoff.XXXXXX")"
trap 'rm -f "$log"' EXIT
res='{"status":"accepted","change_id":"0123456789abcdef"}'
out="$(_settle_worker_apply_key rig1 DONATION 0 "$res" sample-revert 2>"$log")"
assert_eq "stale dashboard value does not promote accepted to applied" "$out" 'accepted||0123456789abcdef'
assert_eq "a timeout retains one sample per poll" "$(rg -c '^\{' "$log")" "2"
sample="$(rg '^\{' "$log" | tail -1 | jq -c '.')"
assert_eq "one bounded sample contains the dashboard value, feed age inputs, history and exact rig status" \
    "$(printf '%s' "$sample" | jq -c '[.dashboard_donation,.history,.dashboard_feed_at,.dashboard_stale,.dashboard_snapshot_at,.dashboard_status,.rig_donation,.rig_feed_at,.rig_status]')" \
    '["1","accepted","2026-09-29T17:04:30Z","true","1790711070.25","online","0","2026-09-29T17:05:15Z","applied"]'
if rg -q 'fixture-secret|example\.test' "$log"; then
    it_fail "sample excludes token and host" "credential or topology escaped"
else
    it_pass "sample excludes token and host"
fi

IT_RIG_TOKEN=''
STUB_DETAIL=''
_pred_donation_revert_sample rig1 0 0123456789abcdef 2>"$log"
assert_eq "failed reads are named, not mistaken for zero" \
    "$(rg '^\{' "$log" | jq -r '[.dashboard_donation,.history,.rig_donation,.rig_status] | join(",")')" \
    'poll_failed,poll_failed,poll_failed,poll_failed'

STUB_DETAIL='{"rig_config":{"DONATION":"fixture-secret"},"history":[{"change_id":"0123456789abcdef","status":"fixture-secret"}],"rigforge":{"generated_at":"fixture-secret","stale":"fixture-secret"}}'
_pred_donation_revert_sample rig1 0 0123456789abcdef 2>"$log"
if rg -q 'fixture-secret' "$log"; then
    it_fail "untrusted fields cannot write arbitrary text to the sample" "unsanitized field"
else
    it_pass "untrusted fields cannot write arbitrary text to the sample"
fi

echo "selftest-donation-handoff-sample: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
