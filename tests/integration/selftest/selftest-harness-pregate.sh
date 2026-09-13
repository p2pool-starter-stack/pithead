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

echo ""
echo "selftest-harness-pregate: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
