#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC2034 # globals are consumed by sourced functions
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-onion-targets.sh"
source "$HERE/../lib/run-rotate-onion.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT_DIR="$WORK"
ONION="$(printf 'a%.0s' $(seq 56)).onion"
TOR_DIR=/srv/tor-fixture
IT_MODE=local
IT_ROTATE_ONION_FIXTURE_ATTESTATION="$TOR_DIR"
BUILD_RC=0
PROBE_RC=0
PROBE_OUT=""
env_on_box() {
    case "$1" in
    TOR_DATA_DIR) echo "$TOR_DIR" ;;
    DASHBOARD_ONION_ENABLED | DASHBOARD_ONION_CLIENT_AUTH) echo true ;;
    DASHBOARD_ONION_ADDRESS) echo "$ONION" ;;
    esac
}
rotate_onion_data_dir() { echo "$1"; }
sleep() { :; }
rx() {
    case "$1" in
    *"docker build"*) return "$BUILD_RC" ;;
    *"docker run"*)
        printf '%s' "$PROBE_OUT"
        return "$PROBE_RC"
        ;;
    *) return 0 ;;
    esac
}

probe() { # <build rc> <probe rc> <probe output>
    BUILD_RC="$1" PROBE_RC="$2" PROBE_OUT="$3"
    rm -f "$OUT_DIR/onion-baseline-probe.failure.json"
    local before="$IT_FAIL"
    run_rotate_onion >/dev/null 2>&1
    local delta=$((IT_FAIL - before))
    IT_FAIL="$before"
    assert_eq "baseline failure keeps its non-passing verdict" "$delta" 1
    assert_eq "baseline failure leaves nothing armed to restore" "$ROTATE_ONION_RESTORE_ARMED" 0
    rotate_onion_restore
    assert_rc "restore after a baseline failure is a no-op success" "$?" 0
}
stage_of() { jq -r '[.stage, (.probe_exit | tostring), (.http_status | tostring)] | join(" ")' "$OUT_DIR/onion-baseline-probe.failure.json"; }

echo "== distinct baseline failure stages are retained =="
probe 1 0 ""
assert_eq "build failure" "$(stage_of)" "build null null"
probe 0 2 "PROBE-FAIL: tor did not bootstrap within 120s
$ONION secret-marker"
assert_eq "client bootstrap failure" "$(stage_of)" "client-bootstrap 2 null"
probe 0 1 "PROBE-FAIL: $ONION -> HTTP 000 (wanted 200|401)"
assert_eq "HTTP reachability failure" "$(stage_of)" "http-reachability 1 0"
probe 0 1 "PROBE-FAIL: $ONION -> HTTP 503 (wanted 200|401)"
assert_eq "unexpected HTTP status" "$(stage_of)" "http-status 1 503"
probe 0 4 ""
assert_eq "authorization input failure" "$(stage_of)" "authorization 4 null"
probe 0 9 "garbage secret-marker"
assert_eq "unclassified exit" "$(stage_of)" "error 9 null"
_onion_reachable_external "not-an-onion"
assert_eq "malformed input stage" "$ONION_PROBE_STAGE:$?" "input:3"
rm -f "$OUT_DIR/onion-baseline-probe.failure.json"
capture_onion_baseline_failure
assert_eq "input stage retained" "$(stage_of)" "input null null"
probe 0 9 "garbage secret-marker"
assert_eq "no onion address or raw output is retained" "$(grep -Ec "$ONION|secret-marker|aaaa" "$OUT_DIR/onion-baseline-probe.failure.json" || true)" 0
assert_num_ge "record stays below 512 bytes" 512 "$(wc -c <"$OUT_DIR/onion-baseline-probe.failure.json" | tr -d ' ')"

echo "== a reachable baseline writes no diagnostic =="
rm -f "$OUT_DIR/onion-baseline-probe.failure.json"
PROBE_OUT="PROBE-OK: $ONION reachable over Tor -> HTTP 200" PROBE_RC=0 BUILD_RC=0
_onion_reachable_external
assert_rc "reachable baseline passes" "$?" 0
assert_eq "no artifact on success" "$([ -e "$OUT_DIR/onion-baseline-probe.failure.json" ] && echo yes || echo no)" no

echo "== an unwritable artifact directory is explicit =="
OUT_DIR="$WORK/missing"
capture_onion_baseline_failure >"$WORK/write.log" 2>&1
assert_rc "failed artifact write returns 1" "$?" 1
assert_contains "failed write is named" "$(cat "$WORK/write.log")" 'could not be retained'

echo "selftest-onion-baseline-diagnostics: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
