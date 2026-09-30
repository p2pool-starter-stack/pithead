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
export IT_SCRATCH_DIR="$WORK/scratch quote'" LIB="$HERE/../lib.sh" PREFLIGHT_RESULT="$WORK/preflight"
# shellcheck disable=SC2034 # consumed by the real on_bench function extracted below
BENCH_HOST=unused E2E_DIR="$WORK/target"
# Model SSH dropping ambient scratch variables; execute the real wrapper's remote command.
parent_lock_on_bench() { env -u TMPDIR -u IT_SCRATCH_DIR bash -c "$2"; }
cat >"$WORK/target/tests/integration/run.sh" <<'HARNESS'
#!/usr/bin/env bash
set -uo pipefail
source "$LIB"
IT_MODE=local IT_REMOTE_DIR="$PWD"
parse_args() { :; }
rig_lock() { :; }
preflight() { touch "$PREFLIGHT_RESULT"; }
assert_current_state() { :; }
summary() { [ "$IT_FAIL" -eq 0 ]; }
READINESS=0 CHECK_ONLY=1
eval "$MAIN_SRC"
main
HARNESS
# Mock the Linux /proc process-identity read; device faults are selected below.
printf '#!/usr/bin/env bash\necho 42\n' >"$WORK/tools/awk"
chmod +x "$WORK/tools/awk"
REAL_STAT="$(command -v stat)"
export REAL_STAT
cat >"$WORK/tools/stat" <<'STAT'
#!/usr/bin/env bash
case "${STAT_CASE:-}:$3" in
    both-error:*) exit 1 ;;
    parent-error:*/..) exit 1 ;;
    parent-error-output:*/..) "$REAL_STAT" "$@"; exit 1 ;;
    scratch-error:*/..|scratch-error-output:*/..) ;;
    scratch-error-output:*) "$REAL_STAT" "$@"; exit 1 ;;
    scratch-error:*) exit 1 ;;
    empty:*) exit 0 ;;
    mismatch:*/..) echo 999; exit 0 ;;
esac
exec "$REAL_STAT" "$@"
STAT
chmod +x "$WORK/tools/stat"
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
assert_contains "real main records the required scratch row" \
    "$(cat "$E2E_DIR/results/e2e-harness.log")" "runner scratch usable in target rx shell"
assert_eq "valid scratch reaches preflight" "$(test -f "$PREFLIGHT_RESULT" && echo yes)" yes
assert_eq "harness completion is successful" "$(cat "$E2E_DIR/results/e2e-harness.done")" 0

# Invoke the same real main directly so the detached guard cannot hide a missing rx gate.
run_main() {
    rm -f "$PREFLIGHT_RESULT"
    (cd "$E2E_DIR" && TMPDIR="$IT_SCRATCH_DIR" bash tests/integration/run.sh) >"$WORK/main.log" 2>&1
}
assert_main_refuses() {
    run_main
    assert_rc "real main rejects $1" "$?" 1
    assert_contains "real main records rejected scratch for $1" "$(cat "$WORK/main.log")" \
        "runner scratch usable in target rx shell"
    assert_eq "$1 stops before preflight" "$(test ! -e "$PREFLIGHT_RESULT" && echo yes)" yes
    assert_eq "$1 leaves no rx scratch probe" \
        "$(compgen -G "$IT_SCRATCH_DIR/rx-scratch.*" || :)" ""
}
for STAT_CASE in both-error scratch-error parent-error scratch-error-output parent-error-output empty mismatch; do
    export STAT_CASE
    rm -f "$PREFLIGHT_RESULT"
    run_installed
    assert_rc "detached runner rejects $STAT_CASE" "$?" 1
    assert_eq "detached refusal is recorded for $STAT_CASE" "$(cat "$E2E_DIR/results/e2e-harness.done")" 1
    assert_contains "detached refusal explains $STAT_CASE" "$(cat "$E2E_DIR/results/e2e-harness.log")" "target scratch unavailable"
    assert_eq "detached $STAT_CASE never launches the harness" "$(test ! -e "$PREFLIGHT_RESULT" && echo yes)" yes
    assert_main_refuses "$STAT_CASE"
done
unset STAT_CASE

# File-creation failure is unusable storage even if both device queries succeed.
printf '#!/usr/bin/env bash\nexit 1\n' >"$WORK/tools/mktemp"
chmod +x "$WORK/tools/mktemp"
run_installed
assert_rc "detached runner rejects unusable scratch" "$?" 1
assert_main_refuses "unusable scratch"
rm -f "$WORK/tools/mktemp"

mv "$IT_SCRATCH_DIR" "$WORK/scratch-saved"
run_installed
assert_rc "missing scratch refuses instead of falling back" "$?" 1
assert_contains "missing scratch has an explicit diagnostic" \
    "$(cat "$E2E_DIR/results/e2e-harness.log")" "target scratch unavailable"
assert_eq "refusal completion is recorded" "$(cat "$E2E_DIR/results/e2e-harness.done")" 1
assert_main_refuses "missing scratch"
ln -s "$WORK/scratch-saved" "$IT_SCRATCH_DIR"
run_installed
assert_rc "symlink scratch refuses" "$?" 1
assert_main_refuses "symlink scratch"

echo "selftest-harness-scratch: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
