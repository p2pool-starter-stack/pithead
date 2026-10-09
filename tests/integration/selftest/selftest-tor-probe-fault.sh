#!/usr/bin/env bash
# Pure regression fixtures: no remote command or real wait runs here.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/run-tor-probe-fault.sh
source "$HERE/../lib/run-tor-probe-fault.sh"

SCRATCH=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-${TMP:-/tmp}}}/tor-probe-selftest.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
PASS=0
FAIL=0
check() {
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n' "$*" >&2
    fi
}

echo "== Tor probe fault skips before any live work when mining assertions are disabled =="
(
    SKIP_MINING_ASSERTS=1
    # A file records calls even inside command substitutions.
    unexpected() {
        echo "$1" >>"$SCRATCH/live-calls"
        return 1
    }
    env_on_box() {
        unexpected env_on_box
        echo false
    }
    wait_for() { unexpected wait_for; }
    rx() { unexpected rx; }
    push_config() { unexpected push_config; }
    pithead() { unexpected pithead; }
    _tor_probe_mining_sample() { unexpected mining_sample; }
    fault_tor_probe_egress
    check test ! -e "$SCRATCH/live-calls"
    check test "$IT_FAIL" -eq 0
    check test "$IT_PASS" -eq 0
    check test "$IT_SKIPPED_LEGS" -eq 1
    check test "$IT_SKIPPED_BY_DESIGN" -eq 1
    check test "$IT_SKIPPED_MISSING" -eq 0
    check test "$IT_SKIPPED_COVERED" -eq 0
    check test "$IT_SKIPPED_PHASES" -eq 0
    check test "$IT_SKIPPED" -eq 0
    check grep -Fq 'Tor clearnet probe fault' <<<"$IT_SKIPPED_NAMES"
    check grep -Fq -- '--no-mining-asserts' <<<"$IT_SKIPPED_NAMES"
    check grep -Fq 'no miner attached' <<<"$IT_SKIPPED_NAMES"
    printf 'skip fixture: %s passed, %s failed\n' "$PASS" "$FAIL"
    test "$FAIL" -eq 0
)

echo "== Missing mining witnesses remain failures without the explicit skip =="
for flag in 0 unset; do
    (
        if [ "$flag" = unset ]; then unset SKIP_MINING_ASSERTS; else SKIP_MINING_ASSERTS=$flag; fi
        waited=0
        env_on_box() { echo true; }
        wait_for() {
            check test "$1" -eq 180
            check test "$2" -eq 10
            check test "$4" = _tor_probe_mining_sample
            waited=$((waited + 1))
            return 1
        }
        fault_tor_probe_egress
        check test "$waited" -eq 1
        check test "$IT_FAIL" -eq 1
        check test "$IT_PASS" -eq 0
        check test "$IT_SKIPPED_LEGS" -eq 0
        check grep -Fq 'Tor probe fault has a live mining witness' <<<"$IT_FAILED_NAMES"
        printf 'binding fixture (%s): %s passed, %s failed\n' "$flag" "$PASS" "$FAIL"
        test "$FAIL" -eq 0
    )
done

echo "== Lifecycle recovery proof rejects false success and unexpected-abort advice =="
for fixture in refusal abort success wrong-guard; do
    (
        IT_FAIL=0 IT_PASS=0
        rx() { [ "$1" != 'docker exec tor /usr/local/bin/tor-recovery-diagnose.sh' ]; }
        pithead() {
            case "$fixture" in
            refusal)
                echo '[WARNING] Tor recovery refused: circuit history is not saturated.'
                return 1
                ;;
            abort)
                echo '[WARNING] Tor recovery refused: circuit history is not saturated.'
                echo 'pithead aborted unexpectedly; bash -x'
                return 1
                ;;
            success) echo '[WARNING] Tor recovery refused: circuit history is not saturated.' ;;
            wrong-guard)
                echo 'Tor recovery refused: data mount is ambiguous.'
                return 1
                ;;
            esac
        }
        set +e # The live harness records nonzero probes without errexit.
        tor_recovery_healthy_probe
        set -e
        if [ "$fixture" = refusal ]; then
            check test "$IT_FAIL" -eq 0
            check test "$IT_PASS" -eq 6
        else
            check test "$IT_FAIL" -eq 1
        fi
        printf 'recovery fixture (%s): %s passed, %s failed\n' "$fixture" "$PASS" "$FAIL"
        test "$FAIL" -eq 0
    )
done
