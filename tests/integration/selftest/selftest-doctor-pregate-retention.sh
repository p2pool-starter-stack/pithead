#!/usr/bin/env bash
# Exercise the wrapper's real pregate commands across the real preflight cleanup boundary.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/detached-harness.sh
source "$HERE/../lib/detached-harness.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doctor-pregate.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
E2E_DIR="$TEST_DIR/checkout with spaces"
mkdir -p "$E2E_DIR/tests/integration"
export TEST_LIB_DIR="$HERE/.."
cat >"$E2E_DIR/tests/integration/run.sh" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
# Run the actual assertion and preflight with target I/O stubbed; no stack is touched.
source "$TEST_LIB_DIR/lib.sh"
INTEGRATION_RUN_SUITE=1
source "$TEST_LIB_DIR/lib/run-matrix.sh"
source "$TEST_LIB_DIR/lib/run-scenario.sh"
OUT_DIR="$PWD/tests/integration/results"
phase=''
while [ "$#" -gt 0 ]; do
    case "$1" in
    --readiness|--check|--scenario) phase="$1" ;;
    --out) OUT_DIR="$2"; shift ;;
    esac
    shift
done
IT_MODE=local IT_SSH_DEST='' IT_REMOTE_DIR=. IT_PITHEAD=pithead
SAFETY_BACKUP=0 EXPECTED_WORKERS=1
rx() { case "$1" in 'cat config.json') echo '{}' ;; esac; return 0; }
env_on_box() { echo true; }
secret_fingerprint() { echo fixture-fingerprint; }
record_manifest() { echo manifest >"$OUT_DIR/manifest.txt"; }
pithead() {
    printf '%s\n' 'OK egress firewall is installed' 'OK workers can connect' 'OK dashboard answers on 127.0.0.1:8000'
    printf 'invocation rc %s\n' "$DOCTOR_RC" >&2
    return "$DOCTOR_RC"
}
[ "$phase" != --readiness ] || [ "${TEST_READINESS_FAIL:-0}" = 0 ] || exit 1
preflight || exit 1
[ "$phase" != --check ] || assert_doctor_ok
[ "$IT_FAIL" -eq 0 ]
RUNNER
on_bench() { bash -c "$1"; }
warn() { printf '%s\n' "$*"; }

echo '== asserted pregate files survive destructive preflight for success and failure =='
previous=''
for DOCTOR_RC in 0 7 0; do
    export DOCTOR_RC
    rc=0
    harness_pregate 1 '' >"$TEST_DIR/pregate.log" || rc=$?
    if [ "$DOCTOR_RC" = 0 ]; then
        [ "$rc" = 0 ] || exit 1
    else
        [ "$rc" = 1 ] || exit 1
        grep -q 'expected rc 0, got 7' "$TEST_DIR/pregate.log" || exit 1
    fi
    evidence=("$E2E_DIR"/results/pregate-check/check/doctor-asserted.*)
    [ "${#evidence[@]}" = 1 ] && [ -f "${evidence[0]}/output.txt" ] || exit 1
    [ "$(cat "${evidence[0]}/exit-code.txt")" = "$DOCTOR_RC" ] || exit 1
    expected=$'OK egress firewall is installed\nOK workers can connect\nOK dashboard answers on 127.0.0.1:8000'
    expected+=$'\n'"invocation rc $DOCTOR_RC"
    [ "$(cat "${evidence[0]}/output.txt")" = "$expected" ] || exit 1
    [ -z "$previous" ] || [ ! -e "$previous" ] || {
        echo 'new pregate retained evidence from the previous job'
        exit 1
    }
    # A failed pregate refuses destructive work. Simulate the boundary anyway to prove
    # its evidence is durable too, without authorizing a failing stack to proceed.
    mkdir -p "$E2E_DIR/tests/integration/results"
    touch "$E2E_DIR/tests/integration/results/stale"
    on_bench "cd $(quote_arg "$E2E_DIR") && bash tests/integration/run.sh --scenario" >"$TEST_DIR/preflight.log" || exit 1
    [ ! -e "$E2E_DIR/tests/integration/results/stale" ] || exit 1
    [ "$(cat "${evidence[0]}/output.txt")" = "$expected" ] || exit 1
    [ "$(cat "${evidence[0]}/exit-code.txt")" = "$DOCTOR_RC" ] || exit 1
    previous="${evidence[0]}"
done
echo "== refused readiness cannot collect an earlier job's doctor evidence =="
export TEST_READINESS_FAIL=1
rc=0
harness_pregate 1 '' >"$TEST_DIR/refused.log" || rc=$?
[ "$rc" = 1 ] || exit 1
[ ! -e "$previous" ] || exit 1
[ ! -e "$E2E_DIR/results/pregate-check" ] || exit 1
echo '== check-mode wrapper preflight removes evidence before an early refusal =='
mkdir -p "$E2E_DIR/results/pregate-check/check/doctor-asserted.stale"
PREFLIGHT_SRC="$(sed -n '/^preflight() {$/,/^}$/p' "$HERE/../e2e.sh")"
[ "$(printf '%s\n' "$PREFLIGHT_SRC" | sed -n '1p;$p' | tr '\n' ' ')" = 'preflight() { } ' ] || exit 1
rc=0
(
    # shellcheck disable=SC2034 # consumed by the extracted wrapper preflight
    MODE=check BENCH_HOST=fixture BORROW_MINER=0 CANONICAL_DIR=fixture
    log() { :; }
    ok() { :; }
    die() { exit 1; }
    parent_lock_checkpoint() { return 0; }
    on_bench() {
        case "$1" in
        'echo ok >/dev/null') return 0 ;;
        rm*) bash -c "$1" ;;
        *) return 1 ;;
        esac
    }
    eval "$PREFLIGHT_SRC"
    preflight
) >"$TEST_DIR/check-refused.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || exit 1
[ ! -e "$E2E_DIR/results/pregate-check" ] || exit 1
echo '== evidence cleanup failure refuses the pregate =='
(
    on_bench() {
        echo call >>"$TEST_DIR/cleanup-calls"
        return 1
    }
    rc=0
    harness_pregate 1 '' >"$TEST_DIR/cleanup-failed.log" || rc=$?
    [ "$rc" = 1 ] || exit 1
    [ "$(wc -l <"$TEST_DIR/cleanup-calls")" = 1 ] || exit 1
    grep -q 'could not clear prior check evidence' "$TEST_DIR/cleanup-failed.log" || exit 1
) || exit 1
echo 'selftest-doctor-pregate-retention: PASS'
