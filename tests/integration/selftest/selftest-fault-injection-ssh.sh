#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/harness-args.sh
source "$HERE/../lib/harness-args.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-faults.sh
source "$HERE/../lib/run-faults.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/stack space's \$cash"
export SSH_CALL_LOG="$WORK/ssh-call"
cat >"$WORK/bin/ssh" <<'SSH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SSH_CALL_LOG"
for arg; do remote="$arg"; done
unset TMPDIR IT_SCRATCH_DIR
bash -c "$remote"
SSH
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"

echo "== SSH fault phase transport, quoting and argument refusals =="
MODE=targeted HARNESS_ARGS=(--fault-injection-ssh)
validate_harness_args
assert_eq "the SSH selector is forwarded unchanged" "$HARNESS_PHASE_ARGS" " --fault-injection-ssh"

run_fault_injection() {
    rx "printf '%s' $(quote_arg "quoted 'value' \$cash ;") >probe"
    return 7
}
IT_MODE=local IT_SSH_DEST=original
IT_SSH_OPTS=(-o BatchMode=yes)
IT_REMOTE_DIR="$WORK/stack space's \$cash"
FAULT_SSH=0 FAULT_SSH_DEST="runner@bench"
run_fault_injection_maybe
assert_rc "the local phase preserves its return code" "$?" 7
assert_eq "a destination without the selector never invokes SSH" "$(test -f "$SSH_CALL_LOG" && echo yes || echo no)" no

FAULT_SSH=1
run_fault_injection_maybe
assert_rc "the SSH phase preserves its return code" "$?" 7
assert_eq "the quoted snippet reached the stack directory" "$(cat "$IT_REMOTE_DIR/probe")" "quoted 'value' \$cash ;"
assert_eq "rx() invoked SSH with options and the selected destination" \
    "$(sed '$d' "$SSH_CALL_LOG" 2>/dev/null)" "$(printf '%s\n' -n -o BatchMode=yes runner@bench)"
assert_eq "the process transport is restored after the phase" "$IT_MODE|$IT_SSH_DEST" "local|original"

echo "== SSH fault phase keeps runner scratch in a fresh target shell =="
export IT_SCRATCH_DIR="$WORK/scratch quote's \$cash"
mkdir -p "$IT_SCRATCH_DIR"
run_fault_injection() {
    printf '%s\n' 'test "${TMPDIR:?runner scratch required}" = "${IT_SCRATCH_DIR:?runner scratch required}" &&
        f=$(mktemp "$TMPDIR/fault-scratch.XXXXXX") && test -f "$f" && printf "%s" "$f" >scratch-probe' |
        rx 'bash -s' --stdin
}
run_fault_injection_maybe
assert_rc "fresh SSH shell receives usable runner scratch" "$?" 0
assert_contains "the target creates its temporary file inside the quoted scratch directory" \
    "$(cat "$IT_REMOTE_DIR/scratch-probe" 2>/dev/null)" "$IT_SCRATCH_DIR/fault-scratch."

out="$(bash "$HERE/../run.sh" --local --dir "$WORK" --fault-injection-ssh 2>&1)"
assert_rc "a bare selector without its destination is refused" "$?" 2
assert_contains "the error refuses to run locally" "$out" "refusing to run the phase locally"
out="$(bash "$HERE/../run.sh" --local --dir "$WORK" --fault-injection-ssh --fault-ssh-dest --hardening 2>&1)"
assert_rc "an option cannot become an SSH destination" "$?" 2
assert_contains "the error identifies the invalid destination" "$out" "got the flag '--hardening'"
out="$(bash "$HERE/../run.sh" --local --dir "$WORK" --fault-ssh-dest 2>&1)"
assert_rc "a destination flag without a value is refused" "$?" 2
assert_contains "the error names the required destination" "$out" "requires an SSH destination"

echo "selftest-fault-injection-ssh: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
