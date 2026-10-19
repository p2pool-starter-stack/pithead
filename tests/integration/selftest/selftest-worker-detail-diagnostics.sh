#!/usr/bin/env bash
# Judged responses are captured before later probes, with the original row verdict.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-rigforge.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT_DIR="$WORK"
STATE='{"control_enabled":true,"workers":[{"name":"rig1","status":"online","api_ok":true,"ip":"private-marker","rigforge":{"version":"1.0.0","stale":false,"chips":[{"text":"ok"}],"token":"secret-marker"}}]}'
DETAIL='{"name":"rig1","found":true,"status":"online","rigforge":{"version":null,"stale":true,"token":"secret-marker"}}'
api_state() {
    echo "$STATE"
    echo read >>"$WORK/state.reads"
}
_worker_detail() {
    echo "$DETAIL"
    echo read >>"$WORK/detail.reads"
}
rx() {
    # Later write guards run only after the failure-boundary artifact exists.
    [ -f "$OUT_DIR/worker-detail.failure.json" ] || [ "$EXPECT_CAPTURE" = 0 ] || return 99
    case "$1" in *ACCESS_TOKEN*) echo 400 ;; *) echo 403 ;; esac
}
EXPECT_CAPTURE=1
echo "== judged Worker Inspect failures are retained before later probes =="
run_rigforge_integration rig1
assert_eq "only the original enriched telemetry row fails" "$IT_FAIL" 1
sample="$(cat "$OUT_DIR/worker-detail.failure.json")"
assert_eq "same-read state and detail are retained" "$(echo "$sample" | jq -c '[.state.worker_found,.state.rigforge.version_present,.detail.found,.detail.rigforge.stale,.detail.rigforge.version_present,.detail.rigforge.version_withheld_as_stale]')" '[true,true,true,true,false,true]'
assert_eq "no state refetch was added" "$(wc -l <"$WORK/state.reads" | tr -d ' ')" 1
assert_eq "no detail refetch was added" "$(wc -l <"$WORK/detail.reads" | tr -d ' ')" 1
assert_eq "names, secrets and topology are omitted" "$(echo "$sample" | grep -Ec 'marker|rig1' || true)" 0
assert_num_ge "projection stays below 2048 bytes" 2048 "$(wc -c <"$OUT_DIR/worker-detail.failure.json" | tr -d ' ')"
# Use pretty JSON to pin framing rather than relying on one-line API formatting.
STATE="$(echo "$STATE" | jq .)" DETAIL="$(echo "$DETAIL" | jq .)"
capture_worker_detail_failure rig1 "$STATE" "$DETAIL"
assert_rc "multiline judged reads still capture" "$?" 0
DETAIL='{"name":"rig1","found":true,"status":"online","rigforge":{"version":"1.0.0"}}'
rm "$OUT_DIR/worker-detail.failure.json"
EXPECT_CAPTURE=0 before="$IT_FAIL"
run_rigforge_integration rig1
assert_eq "successful telemetry adds no failures" "$IT_FAIL" "$before"
assert_eq "successful telemetry writes no artifact" "$([ -e "$OUT_DIR/worker-detail.failure.json" ] && echo yes || echo no)" no
capture_worker_detail_failure rig1 '{}' 'invalid secret-marker'
assert_eq "invalid response is explicit without leaking its text" "$(jq -r '.detail.valid' "$OUT_DIR/worker-detail.failure.json")" false
OUT_DIR="$WORK/missing"
capture_worker_detail_failure rig1 "$STATE" "$DETAIL" >"$WORK/write.log" 2>&1
assert_rc "failed artifact writes are explicit" "$?" 1
assert_contains "failed write is named" "$(cat "$WORK/write.log")" 'could not be retained'
# The expected failed row is retained; subtract it only for this selftest summary.
IT_FAIL=$((IT_FAIL - 1))
echo "selftest-worker-detail-diagnostics: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
