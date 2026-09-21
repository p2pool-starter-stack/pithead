#!/usr/bin/env bash
# Self-test #2000: --fault-injection-ssh runs the fault-injection phase's own rx() calls (lib.sh)
# over SSH instead of the run's usual --local, without disturbing rig-lock continuity
# (lib/parent-lock.sh requires IT_MODE=local for the whole process). No server, no bench.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/harness-args.sh
source "$HERE/../lib/harness-args.sh"

echo "== validate_harness_args: the phase token is forwarded to run.sh unchanged =="
MODE=targeted
HARNESS_ARGS=(--fault-injection-ssh)
validate_harness_args
assert_eq "forwarded raw, like every other phase" "$HARNESS_PHASE_ARGS" " --fault-injection-ssh"

# bench-ci selects a phase by reading THIS allowlist arm: _HARNESS_ALLOWLIST_RE (bench_ci/
# catalogue.py) takes the first `--a | --b | ...)` arm whose very next line forwards $arg raw, and
# offers exactly those names. A token in a bespoke arm is invisible to it and can never be
# submitted (bench-ci#341/#359), so pin the token to that arm rather than merely to the allowlist.
ARM="$(grep -A1 -E '^[[:space:]]*--lifecycle \|' "$HERE/../lib/harness-args.sh")"
assert_contains "the token is IN the arm bench-ci reads" "$ARM" "--fault-injection-ssh"
assert_contains "and that arm is the one that forwards \$arg raw" "$ARM" 'HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS $arg"'

echo "== run_fault_injection_maybe: swaps IT_MODE/IT_SSH_DEST for the call, then restores them =="
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-faults.sh
source "$HERE/../lib/run-faults.sh"
RUN_FAULT_SEEN_MODE="" RUN_FAULT_SEEN_DEST=""
# Stub OVER the real run_fault_injection sourced above — run_fault_injection_maybe only wraps the
# call, and the phase's own collaborators (rx, capture_artifacts, …) need a live box to run.
run_fault_injection() {
    RUN_FAULT_SEEN_MODE="$IT_MODE"
    RUN_FAULT_SEEN_DEST="$IT_SSH_DEST"
}

IT_MODE="local"
IT_SSH_DEST=""
FAULT_SSH=0
FAULT_SSH_DEST=""
run_fault_injection_maybe
assert_eq "no destination: IT_MODE stays local for the call" "$RUN_FAULT_SEEN_MODE" "local"
assert_eq "no destination: IT_MODE is still local after" "$IT_MODE" "local"

IT_MODE="local"
IT_SSH_DEST=""
FAULT_SSH=0
FAULT_SSH_DEST="runner@bench"
run_fault_injection_maybe
assert_eq "a destination without the selector stays local for the call" "$RUN_FAULT_SEEN_MODE" "local"

IT_MODE="local"
IT_SSH_DEST=""
FAULT_SSH=1
FAULT_SSH_DEST="runner@bench"
run_fault_injection_maybe
assert_eq "with a destination: run_fault_injection sees IT_MODE=ssh" "$RUN_FAULT_SEEN_MODE" "ssh"
assert_eq "with a destination: run_fault_injection sees it" "$RUN_FAULT_SEEN_DEST" "runner@bench"
assert_eq "restored to local after, so the rig lock never sees a non-local mode" "$IT_MODE" "local"
assert_eq "and IT_SSH_DEST is restored too" "$IT_SSH_DEST" ""

echo "== run-cli.sh: the bare token implies --fault-injection and fails closed without a dest =="
# The whole point of the phase is that it took the SSH branch, so a token that arrived without
# e2e.sh's destination must refuse — never quietly run --local and report an SSH proof.
out="$(bash "$HERE/../run.sh" --local --dir /tmp --fault-injection-ssh 2>&1)"
assert_rc "the bare token alone is refused" "$?" "2"
assert_contains "and says it will not run the phase locally" "$out" "refusing to run the phase locally"
out="$(bash "$HERE/../run.sh" --local --dir /tmp --fault-injection-ssh --fault-ssh-dest --hardening 2>&1)"
assert_rc "a following flag is never swallowed as the destination" "$?" "2"
assert_contains "and names the flag it refused to treat as a host" "$out" "got the flag '--hardening'"
out="$(bash "$HERE/../run.sh" --local --dir /tmp --fault-ssh-dest 2>&1)"
assert_rc "a dest flag with no value is refused" "$?" "2"
assert_contains "and says what it needed" "$out" "requires an SSH destination"

echo ""
echo "selftest-fault-injection-ssh: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
