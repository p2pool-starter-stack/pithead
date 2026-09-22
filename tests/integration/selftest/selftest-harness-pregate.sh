#!/usr/bin/env bash
#
# Self-test: harness_pregate forwards --workers into both its inline readiness/check
# sub-phases (#2116). Standalone (not folded into selftest-e2e-phases.sh) so it never
# pushes that file past its docs/dev/file-budget.tsv ceiling — same reasoning as
# selftest-rigforge-apply-settle.sh.
#
# The defect: harness_pregate's readiness/check calls never forwarded --workers, so
# EXPECTED_WORKERS silently fell back to run.sh's hardcoded default of 2 regardless of
# what the outer run declared — a one-rig bench then failed "workers online (>= 2)" on
# a healthy stack. No server, no bench, no rig. Run directly, or via
# `make test-integration-selftest`.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# The REAL harness_pregate, not a re-spelling of it.
# shellcheck source=tests/integration/lib/detached-harness.sh
source "$HERE/../lib/detached-harness.sh"

pregate_of() { # <workers> <no_mining_flag> -> the readiness on_bench command, then the check one
    (
        E2E_DIR=/srv/code/pithead-e2e
        on_bench() { printf '%s\n' "$1"; }
        harness_pregate "$1" "$2"
    ) </dev/null
}

echo "== harness_pregate forwards --workers into both inline sub-phases (#2116) =="
PREGATE="$(pregate_of 1 --no-mining-asserts)"
assert_contains "the inline --readiness sub-phase forwards --workers" \
    "$(printf '%s\n' "$PREGATE" | sed -n 1p)" "--workers '1'"
assert_contains "the inline --check sub-phase forwards --workers" \
    "$(printf '%s\n' "$PREGATE" | sed -n 2p)" "--workers '1'"
assert_contains "a different worker count is forwarded too, not a hardcoded '1'" \
    "$(pregate_of 3 --no-mining-asserts | sed -n 1p)" "--workers '3'"

echo "== the reserved-lock wait reaches both executed pre-gates (#504) =="
pregate_wait_of() {
    local work="$1"
    mkdir -p "$work/tests/integration"
    printf '%s\n' '#!/usr/bin/env bash' \
        '[ "${RIG_LOCK_WAIT:-}" = 1 ] || exit 75' \
        'printf "%s\\n" "$RIG_LOCK_WAIT" >>"$PREGATE_RESULT"' >"$work/tests/integration/run.sh"
    chmod +x "$work/tests/integration/run.sh"
    (
        E2E_DIR="$work"
        export RIG_LOCK_WAIT=1 PREGATE_RESULT="$work/waits"
        on_bench() { bash -c "$1"; }
        harness_pregate 1 ""
    )
}
PREGATE_WORK="$(mktemp -d)"
trap 'rm -rf "$PREGATE_WORK"' EXIT
pregate_wait_of "$PREGATE_WORK"
assert_eq "both executed pre-gates inherit the reserved-lock wait" "$(cat "$PREGATE_WORK/waits")" $'1\n1'

echo "== a sub-phase that returns without draining stdin is not reported as a failure (#2457) =="
# The parent-lock pair used to be PIPED in. The sub-phase does read both lines, so the bytes always
# arrived — but a pipeline whose reader returns before the write lands leaves the writer in a closed
# pipe, and `set -o pipefail` promotes that SIGPIPE to the pipeline's status. harness_pregate then
# refuses the destructive launch over a readiness that actually PASSED. It surfaced as a rare CI red
# because two short lines almost always win the race; a payload past the pipe buffer makes the loser
# certain, which is what turns a heisenbug into a gate. A here-string has no pipeline to poison.
pregate_rc() { # <stdin payload> -> harness_pregate's rc against a sub-phase that ignores its stdin
    (
        E2E_DIR=/srv/code/pithead-e2e
        RIG_LOCK_PARENT_ACTOR="$1" RIG_LOCK_PARENT_NONCE=nonce
        on_bench() { return 0; }
        warn() { :; }
        harness_pregate 1 --no-mining-asserts
    ) </dev/null
}
pregate_rc short >/dev/null 2>&1
assert_rc "an ordinary parent-lock payload passes the pregate" "$?" "0"
# Calibration: without the fix THIS is the arm that reds, and the one above still passes — so a
# green here is the here-string working, not the payload being too small to prove anything.
pregate_rc "$(printf 'x%.0s' $(seq 1 100000))" >/dev/null 2>&1
assert_rc "a parent-lock payload past the pipe buffer passes it too" "$?" "0"

echo ""
echo "selftest-harness-pregate: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
