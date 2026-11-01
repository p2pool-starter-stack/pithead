#!/usr/bin/env bash
# Pure regression for the required-Tari verdict in run-state.sh (#3059).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib.sh
# shellcheck disable=SC1091 # path resolved at runtime
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/tari-readiness.sh
source "$HERE/../lib/tari-readiness.sh"
# shellcheck source=tests/integration/lib/run-state.sh
# shellcheck disable=SC1091 # path resolved at runtime
source "$HERE/../lib/run-state.sh"

echo "== required Tari uses a fresh bounded observation (#3059) =="

# Drives the real required-Tari block so a stale cached `st` cannot pass unnoticed.
RUN_STATE="$HERE/../lib/run-state.sh"
TARI_BLOCK="$(sed -n '/^    # 7\. Tari sync-gate posture/,/^    # 7b\./p' "$RUN_STATE" | sed '$d')"
assert_contains "required-Tari block extraction retains its env binding" \
    "$TARI_BLOCK" 'assert_eq "TARI_REQUIRED env matches config"'

fixture="$(mktemp -d)" || exit 1
trap 'rm -rf "$fixture"' EXIT

set_states() {
    printf '%s\n' "$@" >"$fixture/states"
    printf '1\n' >"$fixture/index"
}

api_state() {
    local index
    index="$(cat "$fixture/index")"
    sed -n "${index}p" "$fixture/states"
    printf '%s\n' "$((index + 1))" >"$fixture/index"
}

# The extracted production block reaches these names through eval.
# shellcheck disable=SC2034,SC2329
run_case() { # <seen-done> <api-state> [api-state]
    local seen="$1"
    shift
    set_states "$@"
    (
        # The stub skips the sleeps but keeps the real predicate and its success/exhaustion exit.
        wait_for() {
            WAIT_TIMEOUT="$1"
            WAIT_INTERVAL="$2"
            shift 3
            "$@" && return 0
            "$@" && return 0
            return 1
        }
        # Invoked through the extracted caller and shared assertion.
        # shellcheck disable=SC2329
        it_pass() { VERDICT=PASS; }
        # Invoked through the extracted caller and shared assertion.
        # shellcheck disable=SC2329
        it_warn() { VERDICT=WARN; }
        it_fail() {
            VERDICT=FAIL
            FAILURE_DETAIL="${2:-}"
        }
        env_on_box() { printf 'true'; }
        config='{"dashboard":{"tari_required":true}}'
        tari_req=true
        st='{"sync":{"tari":{"state":"loading"}}}'
        TARI_SEEN_DONE="$seen"
        TARI_READINESS_OBSERVATION=not-observed
        WAIT_TIMEOUT=not-called
        WAIT_INTERVAL=not-called
        VERDICT=""
        FAILURE_DETAIL=""
        eval "$TARI_BLOCK"
        printf '%s|%s|%s|%s|%s|%s' "$VERDICT" "$TARI_READINESS_OBSERVATION" \
            "$TARI_SEEN_DONE" "$WAIT_TIMEOUT" "$WAIT_INTERVAL" "$FAILURE_DETAIL"
    )
}

assert_eq "stale then settled feeds the successful fresh sample to the binding verdict" \
    "$(run_case 0 \
        '{"sync":{"tari":{"state":"loading"}}}' \
        '{"sync":{"tari":{"state":"done"}}}')" \
    "PASS|done|1|300|10|"

assert_eq "persistent loading fails despite an earlier scenario's earned proof" \
    "$(run_case 1 \
        '{"sync":{"tari":{"state":"loading"}}}' \
        '{"sync":{"tari":{"state":"loading"}}}')" \
    "FAIL|loading|1|300|10|expected fresh [done] within 300s, last fresh state [loading]"

assert_eq "persistently unreadable state is a distinct binding failure" \
    "$(run_case 1 '' '')" \
    "FAIL|read-error|1|300|10|no readable final /api/state sample within 300s"

# A transport can return a partial response before failing; its body cannot earn a pass.
api_state() {
    printf '%s\n' '{"sync":{"tari":{"state":"done"}}}'
    return 17
}
assert_eq "a failed API read cannot pass through a successful-looking body" \
    "$(run_case 1 ignored ignored)" \
    "FAIL|read-error|1|300|10|no readable final /api/state sample within 300s"

echo "selftest-run-state-tari-observation: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
