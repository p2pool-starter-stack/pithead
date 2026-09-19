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

echo "== validate_harness_args: the bare phase token only records that e2e.sh must supply a dest =="
MODE=targeted
HARNESS_ARGS=(--fault-injection-ssh)
validate_harness_args
assert_eq "sets HARNESS_SSH_FAULT" "$HARNESS_SSH_FAULT" "1"
# The token carries no value, but run.sh's --fault-injection-ssh REQUIRES one, so emitting it here
# without the destination would hand run.sh an unparseable flag. e2e.sh appends the pair instead.
assert_eq "emits no phase flag of its own (e2e.sh appends flag+dest together)" "$HARNESS_PHASE_ARGS" ""

HARNESS_ARGS=(--lifecycle)
validate_harness_args
assert_eq "an unrelated phase leaves HARNESS_SSH_FAULT off" "$HARNESS_SSH_FAULT" "0"

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
FAULT_SSH_DEST=""
run_fault_injection_maybe
assert_eq "no destination: IT_MODE stays local for the call" "$RUN_FAULT_SEEN_MODE" "local"
assert_eq "no destination: IT_MODE is still local after" "$IT_MODE" "local"

IT_MODE="local"
IT_SSH_DEST=""
FAULT_SSH_DEST="runner@bench"
run_fault_injection_maybe
assert_eq "with a destination: run_fault_injection sees IT_MODE=ssh" "$RUN_FAULT_SEEN_MODE" "ssh"
assert_eq "with a destination: run_fault_injection sees it" "$RUN_FAULT_SEEN_DEST" "runner@bench"
assert_eq "restored to local after, so the rig lock never sees a non-local mode" "$IT_MODE" "local"
assert_eq "and IT_SSH_DEST is restored too" "$IT_SSH_DEST" ""

echo "== run-cli.sh: the flag implies --fault-injection and insists on a real destination =="
out="$(bash "$HERE/../run.sh" --local --dir /tmp --fault-injection-ssh 2>&1)"
assert_rc "a missing destination is refused" "$?" "2"
assert_contains "and says what it needed" "$out" "requires an SSH destination"
out="$(bash "$HERE/../run.sh" --local --dir /tmp --fault-injection-ssh --hardening 2>&1)"
assert_rc "the NEXT flag is never swallowed as the destination" "$?" "2"
assert_contains "and names the flag it refused to treat as a host" "$out" "got the flag '--hardening'"

echo ""
echo "selftest-fault-injection-ssh: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
