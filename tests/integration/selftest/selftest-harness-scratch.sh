#!/usr/bin/env bash
# Execute the real wrapper transport and installed detached runner without SSH or Docker.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/detached-harness.sh
source "$HERE/../lib/detached-harness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/target/tests/integration" "$WORK/tools" "$WORK/scratch quote'"
MAIN_SRC="$(sed -n '/^main() {$/,/^}$/p' "$HERE/../run.sh")"
export MAIN_SRC
export IT_SCRATCH_DIR="$WORK/scratch quote'" LIB="$HERE/../lib.sh" PROBE_RESULT="$WORK/proof"
# shellcheck disable=SC2034 # consumed by the real on_bench function extracted below
BENCH_HOST=unused E2E_DIR="$WORK/target"
# Model SSH dropping ambient scratch variables; execute the real wrapper's remote command.
parent_lock_on_bench() { env -u TMPDIR -u IT_SCRATCH_DIR bash -c "$2"; }
cat >"$WORK/target/tests/integration/run.sh" <<'HARNESS'
#!/usr/bin/env bash
set -eu
source "$LIB"
IT_MODE=local IT_REMOTE_DIR="$PWD"
f=$(mktemp "$TMPDIR/target.XXXXXX")
[ -f "$f" ] && [ "${f%/*}" = "$IT_SCRATCH_DIR" ]
parse_args() { :; }
rig_lock() { :; }
preflight() { :; }
assert_current_state() { :; }
summary() { [ "$IT_FAIL" -eq 0 ]; }
READINESS=0 CHECK_ONLY=1
eval "$MAIN_SRC"
main
rx 'f=$(mktemp "$TMPDIR/rx.XXXXXX"); test -f "$f" && test "${f%/*}" = "$IT_SCRATCH_DIR" && stat -c %d "$f" >"$PROBE_RESULT"'
HARNESS
# Only the Linux /proc process-identity read is mocked on macOS.
printf '#!/usr/bin/env bash\necho 42\n' >"$WORK/tools/awk"
chmod +x "$WORK/tools/awk"
export PATH="$WORK/tools:$PATH"

echo "== runner scratch survives target transport, detached launch, and local rx =="
on_bench 'test "$TMPDIR" = "$IT_SCRATCH_DIR" && test -d "$TMPDIR" && f=$(mktemp "$TMPDIR/transport.XXXXXX") && test -f "$f"'
assert_rc "wrapper target shell receives usable scratch" "$?" 0
harness_install_runner
assert_rc "real detached runner installs" "$?" 0
run_installed() {
    env -u TMPDIR -u IT_SCRATCH_DIR nohup bash "$E2E_DIR/.e2e-run.sh" \
        "$WORK/state" "$E2E_DIR" "$E2E_DIR" 1 request ack token >/dev/null 2>&1
}
run_installed
assert_rc "installed detached runner completes" "$?" 0
assert_eq "target harness and local rx create files on scratch filesystem" \
    "$(cat "$PROBE_RESULT")" "$(stat -c %d "$WORK")"
assert_eq "harness completion is successful" "$(cat "$E2E_DIR/results/e2e-harness.done")" 0

mv "$IT_SCRATCH_DIR" "$WORK/scratch-saved"
run_installed
assert_rc "missing scratch refuses instead of falling back" "$?" 1
assert_contains "missing scratch has an explicit diagnostic" \
    "$(cat "$E2E_DIR/results/e2e-harness.log")" "target scratch unavailable"
assert_eq "refusal completion is recorded" "$(cat "$E2E_DIR/results/e2e-harness.done")" 1
ln -s "$WORK/scratch-saved" "$IT_SCRATCH_DIR"
run_installed
assert_rc "symlink scratch refuses" "$?" 1

echo "selftest-harness-scratch: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
