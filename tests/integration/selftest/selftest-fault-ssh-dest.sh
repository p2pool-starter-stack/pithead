#!/usr/bin/env bash
# Self-test #2000: --fault-injection-ssh proves the fault-injection phase's rx() calls (lib.sh)
# over SSH instead of the run's usual --local, without disturbing rig-lock continuity
# (lib/parent-lock.sh requires IT_MODE=local for the whole process). No server, no bench.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/harness-args.sh
source "$HERE/../lib/harness-args.sh"

echo "== validate_harness_args: --fault-injection-ssh translates to a plain run.sh phase flag =="
MODE=targeted
HARNESS_ARGS=(--fault-injection-ssh)
validate_harness_args
assert_eq "translates to --fault-injection (run.sh has no such flag itself)" "$HARNESS_PHASE_ARGS" " --fault-injection"
assert_eq "sets HARNESS_SSH_FAULT" "$HARNESS_SSH_FAULT" "1"

HARNESS_ARGS=(--lifecycle)
validate_harness_args
assert_eq "an unrelated phase leaves HARNESS_SSH_FAULT off" "$HARNESS_SSH_FAULT" "0"

echo "== run_fault_injection_maybe: swaps IT_MODE/IT_SSH_DEST for the call, then restores them =="
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-faults.sh
source "$HERE/../lib/run-faults.sh"
RUN_FAULT_SEEN_MODE="" RUN_FAULT_SEEN_DEST=""
# Stub OVER the real run_fault_injection sourced above — run_fault_injection_maybe only wraps the
# call, and its own allowlisted collaborators (rx, capture_artifacts, …) need a live box to run.
run_fault_injection() {
    RUN_FAULT_SEEN_MODE="$IT_MODE"
    RUN_FAULT_SEEN_DEST="$IT_SSH_DEST"
}

IT_MODE="local"
IT_SSH_DEST=""
FAULT_SSH_DEST=""
run_fault_injection_maybe
assert_eq "no --fault-ssh-dest: IT_MODE stays local for the call" "$RUN_FAULT_SEEN_MODE" "local"
assert_eq "no --fault-ssh-dest: IT_MODE is still local after" "$IT_MODE" "local"

IT_MODE="local"
IT_SSH_DEST=""
FAULT_SSH_DEST="runner@bench"
run_fault_injection_maybe
assert_eq "--fault-ssh-dest: run_fault_injection sees IT_MODE=ssh" "$RUN_FAULT_SEEN_MODE" "ssh"
assert_eq "--fault-ssh-dest: run_fault_injection sees the destination" "$RUN_FAULT_SEEN_DEST" "runner@bench"
assert_eq "--fault-ssh-dest: IT_MODE restored to local after (rig-lock continuity)" "$IT_MODE" "local"
assert_eq "--fault-ssh-dest: IT_SSH_DEST restored to empty after" "$IT_SSH_DEST" ""

echo "== run-cli.sh: --fault-ssh-dest without --fault-injection is refused =="
out="$(bash "$HERE/../run.sh" --local --dir /tmp --fault-ssh-dest runner@bench 2>&1)"
rc=$?
assert_rc "refused before any run" "$rc" "2"
assert_contains "names the missing flag" "$out" "--fault-ssh-dest requires --fault-injection"

echo ""
echo "selftest-fault-ssh-dest: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
