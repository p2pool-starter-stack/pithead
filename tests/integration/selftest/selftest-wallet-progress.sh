#!/usr/bin/env bash
# Pure privacy/limiter and wrapper isolation checks; container build belongs to bench-ci.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib.sh"
probe=$HERE/../diagnostics/wallet-progress
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
c++ -std=c++11 -Wall -Wextra -Werror -pthread "$probe/probe-test.cpp" -o "$scratch/probe"
"$scratch/probe" 2>"$scratch/actual"
printf 'wallet_numeric_progress kind=2 count=3774000\nwallet_numeric_progress kind=3 count=18446744073709551615\n' >"$scratch/expected"
assert_rc "probe limiter assertions execute and emitted bytes are numeric only" "$(
    cmp -s "$scratch/expected" "$scratch/actual"
    echo $?
)" 0
source "$HERE/../lib/harness-args.sh"
# Inputs consumed by sourced/evaluated production functions below.
export MODE BORROW_MINER KEEP SCENARIO WORKERS E2E_DIR BENCH_HOST
python3 - "$HERE/../lib/harness-args.sh" <<'PY'
import pathlib
import re
import sys

# bench-ci's phase-discovery contract: assignment must immediately follow the arm.
pattern = (
    r"^[ \t]*((?:--[a-z][a-z0-9-]*[ \t]*\|[ \t]*)*--[a-z][a-z0-9-]*)\)[ \t]*\n"
    r'[ \t]*HARNESS_PHASE_ARGS="\$HARNESS_PHASE_ARGS \$arg"'
)
match = re.search(pattern, pathlib.Path(sys.argv[1]).read_text(), re.M)
assert match and "--wallet-progress" in match[1] and "--lifecycle" in match[1]
PY
selection() (
    MODE=targeted BORROW_MINER=0 KEEP=0 SCENARIO="" HARNESS_ARGS=(--wallet-progress)
    die() { exit 2; }
    case "$1" in
    extra) HARNESS_ARGS+=(--lifecycle) ;;
    scenario) SCENARIO=local-pruned-main-secure-tari ;;
    check) MODE=check ;;
    matrix) MODE=matrix ;;
    rig) BORROW_MINER=1 ;;
    keep) KEEP=1 ;;
    esac
    validate_harness_args
    test "$WALLET_PROGRESS" = 1
)
assert_rc "numeric-only diagnostic phase is selectable" "$(
    selection valid
    echo $?
)" 0
for invalid in extra scenario check matrix rig keep; do
    assert_rc "diagnostic refuses $invalid" "$(
        selection "$invalid"
        echo $?
    )" 2
done
# Execute the actual wrapper branch: no scenario, detached launch or assertion bypass.
src=$(sed -n '/^run_harness() {$/,/^}$/p' "$HERE/../e2e.sh")
diagnostic_run() (
    WALLET_PROGRESS=1 WORKERS=1 E2E_DIR=fixture
    harness_pregate() {
        printf 'pregate:%s:%s\n' "$1" "$2" >>"$scratch/calls"
        return "$pregate_rc"
    }
    on_bench() {
        printf 'capture\n' >>"$scratch/calls"
        return "$capture_rc"
    }
    eval "$src"
    run_harness
)
pregate_rc=1 capture_rc=0
assert_rc "binding pre-gate failure remains a failure" "$(
    diagnostic_run
    echo $?
)" 1
assert_eq "failed pre-gate still collects numeric evidence, without a scenario" "$(cat "$scratch/calls")" $'pregate:1:--no-mining-asserts\ncapture'
pregate_rc=0 capture_rc=1
assert_rc "missing or failed numeric capture fails an otherwise green pre-gate" "$(
    diagnostic_run
    echo $?
)" 1
capture_rc=0
assert_rc "diagnostic success requires both binding gate and capture" "$(
    diagnostic_run
    echo $?
)" 0
mkdir "$scratch/bin"
cat >"$scratch/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'wallet_numeric_progress kind=2 count=3774000' 'private-payment-identifier'
exit "${PROBE_LOG_RC:-0}"
SH
chmod +x "$scratch/bin/docker"
capture_log() (
    cd "$scratch"
    PATH="$scratch/bin:$PATH" bash "$probe/capture.sh" >/dev/null
)
assert_rc "numeric-only capture filters the complete emitted stream" "$(
    capture_log
    echo $?
)" 0
assert_eq "capture omits native metadata" "$(cat "$scratch/results/wallet-numeric-progress.txt")" 'wallet_numeric_progress kind=2 count=3774000'
export PROBE_LOG_RC=124
assert_rc "partial numeric output cannot hide a reader timeout" "$(
    capture_log
    echo $?
)" 1
assert_eq "reader timeout is retained explicitly" "$(cat "$scratch/results/wallet-numeric-capture.txt")" 'wallet_numeric_capture_exit=124'
unset PROBE_LOG_RC
mkdir -p "$scratch/stack/tests/integration/diagnostics"
cp -R "$probe" "$scratch/stack/tests/integration/diagnostics/"
export PROBE_COMMANDS="$scratch/commands"
cat >"$scratch/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%040d\n' 1
SH
cat >"$scratch/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PROBE_COMMANDS"
base="sha256:$(printf '%064d' 1)"
candidate="sha256:$(printf '%064d' 2)"
case "$1 $2" in
'compose config') printf '%s\n' '{"services":{"wallet-rpc":{"image":"production-wallet"}}}' ;;
'image inspect')
    case "$*" in
    *org.pithead.wallet-probe.base* | *production-wallet*) echo "$base" ;;
    *) echo "$candidate" ;;
    esac ;;
'build --build-arg') exit "${PROBE_BUILD_RC:-0}" ;;
'run --rm') printf '%064d  monero-wallet-rpc\n' 3 ;;
'inspect --format') echo "$candidate" ;;
esac
SH
chmod +x "$scratch/bin/git" "$scratch/bin/docker"
install_probe() (
    cd "$scratch/stack"
    TMPDIR="$scratch" PATH="$scratch/bin:$PATH" bash "$probe/install.sh" "$1" >/dev/null
)
export PROBE_BUILD_RC=33
assert_rc "failed build prevents activation intent" "$(
    install_probe build
    echo $?
)" 33
assert_eq "failed build leaves no candidate image record" "$(test -e "$scratch/stack/results/wallet-progress-image.txt" && echo exists || echo absent)" absent
unset PROBE_BUILD_RC
assert_rc "source compilation can run before branch deployment" "$(
    install_probe prepare
    echo $?
)" 0
assert_contains "preparation selects only the source build stage" "$(cat "$PROBE_COMMANDS")" 'build --target probe-build'
assert_rc "job-owned build records a candidate after successful build" "$(
    install_probe build
    echo $?
)" 0
assert_eq "build does not mutate a running service" "$(grep -c ' up ' "$PROBE_COMMANDS" || true)" 0
assert_rc "activation verifies the candidate image identity" "$(
    install_probe activate
    echo $?
)" 0
assert_contains "activation targets only wallet, without building or starting dependencies" "$(cat "$PROBE_COMMANDS")" 'up -d --no-build --no-deps wallet-rpc'
assert_contains "candidate provenance retains the binary hash" "$(cat "$scratch/stack/results/wallet-progress-provenance.txt")" "binary_sha256=$(printf '%064d' 3)"
printf 'foreign-image\n' >"$scratch/stack/results/wallet-progress-image.txt"
assert_rc "activation refuses an image not owned by this revision" "$(
    install_probe activate
    echo $?
)" 1
deploy_trace() (
    WALLET_PROGRESS=1 E2E_DIR=fixture BENCH_HOST=fixture
    source "$HERE/../lib/deploy-branch.sh"
    parent_lock_checkpoint() {
        echo "$1" >>"$scratch/deploy-calls"
        test "$1" != "$lost_at"
    }
    deploy_keeping_chain() { echo deploy >>"$scratch/deploy-calls"; }
    on_bench() {
        case "$1" in
        *install.sh*) echo "${1##*install.sh }" | tr -d '"' >>"$scratch/deploy-calls" ;;
        esac
    }
    log() { :; }
    step() { :; }
    warn() { :; }
    ok() { :; }
    die() { exit 2; }
    wait_bench_healthy() { :; }
    wait_synced() { :; }
    deploy_branch
)
lost_at=none
assert_rc "diagnostic deployment preserves source-before-deploy ordering" "$(
    deploy_trace
    echo $?
)" 0
assert_eq "compile then deploy then activate, with reservation checks between" "$(cat "$scratch/deploy-calls")" $'deploy\nprepare\nwallet-progress-deploy\ndeploy\nwallet-progress\nbuild\nwallet-progress-activate\nactivate'
: >"$scratch/deploy-calls"
lost_at=wallet-progress-deploy
assert_rc "lost reservation after compilation prevents deployment" "$(
    deploy_trace
    echo $?
)" 2
assert_eq "no branch deployment follows lost reservation" "$(cat "$scratch/deploy-calls")" $'deploy\nprepare\nwallet-progress-deploy'
assert_contains "CI lints the diagnostic Dockerfile as a required input" "$(cat "$HERE/../../../.github/workflows/ci.yml")" 'tests/integration/diagnostics/*/Dockerfile'
echo "selftest-wallet-progress: $IT_PASS passed, $IT_FAIL failed"
test "$IT_FAIL" = 0
