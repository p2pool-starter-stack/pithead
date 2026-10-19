#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
WORK="$(mktemp -d)"
trap 'rm -r "$WORK"' EXIT
export E2E_SOURCE="$HERE/../e2e.sh" INTEGRATION_LIB="$HERE/../lib.sh"
export DETACHED_LIB="$HERE/../lib/detached-harness.sh"

assert_not_contains() {
    case "$2" in
    *"$3"*) it_fail "$1" "unexpected match" ;;
    *) it_pass "$1" ;;
    esac
}

cat >"$WORK/driver" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source "$INTEGRATION_LIB"
source "$DETACHED_LIB"
for fn in restore_all run_harness main; do
    eval "$(sed -n "/^$fn() {$/,/^}$/p" "$E2E_SOURCE")"
done
MODE="${TEST_MODE:-targeted}" RESTORED=0 KEEP="${TEST_KEEP:-0}"
MINER_CFG_BACKUP="" RESTORE_DIR=baseline CANONICAL_DIR=baseline E2E_DIR=candidate
BENCH_HOST=fixture BRANCH=candidate WORKERS=1 BORROW_MINER=0
RESTORE_PROOF_FAILED=0 CONTROL_PROOF_FAILED=0 SAFETY_ARCHIVE=""
SCENARIO="" HARNESS_PHASE_ARGS=" --auth-fail-closed" HARNESS_SCENARIO_ARGS=""
REMOTE_NODE_ARGS=() RIG_LOCK_WAIT=0
printf 'candidate-original-id\n' >"$IT_SCRATCH_DIR/container"
log() { :; }
ok() { :; }
step() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() { exit 1; }
preflight() { :; }
provision() { :; }
backup_stack() { :; }
wallet_fixture_capture() { :; }
borrow_miner() { :; }
deploy_branch() { :; }
parent_lock_checkpoint() { :; }
parent_lock_miner_restore() { :; }
rig_lock_remote_release() { :; }
chain_restore_prepare() {
    printf 'remove:%s\n' "$(cat "$IT_SCRATCH_DIR/container")" >>"$ARTIFACT_DIR/events"
    rm "$IT_SCRATCH_DIR/container"
}
control_units_verdict() { echo on-target; }
wallet_fixture_restore() { :; }
wallet_fixture_verify() { :; }
recreate_test_checkout_containers() { :; }
cleanup_rotate_onion_fixture() { :; }
wait_synced() { :; }
wait_bench_healthy() { :; }
wait_restore_mining_ready() { :; }
verify_restore_proof() { test "$(cat "$IT_SCRATCH_DIR/container")" = baseline-healthy-id; }
harness_install_runner() { :; }
harness_pregate() {
    printf 'pregate\n' >>"$ARTIFACT_DIR/events"
    [ "$TRIGGER" != pregate ]
}
harness_launch_records() { HARNESS_RECORDS=records; }
on_bench() {
    case "$1" in
    *"printf 'intent"*) : >"$IT_SCRATCH_DIR/active" ;;
    *nohup*) cat >/dev/null; echo 4242 ;;
    "cat 'candidate/results/e2e-harness."*".state'") echo 'running 4242 999' ;;
    *"sudo -n bash"*)
        rm -f "$IT_SCRATCH_DIR/active"
        printf 'drained\n' >>"$ARTIFACT_DIR/events"
        ;;
    "test -f 'candidate/results/e2e-harness.done'")
        [ "$TRIGGER" != cancel ] || kill -TERM "$$"
        ;;
    "cat 'candidate/results/e2e-harness.done'")
        [ "$TRIGGER" != pass ] && echo 23 || echo 0
        ;;
    *dashboard/Dockerfile*) return 1 ;;
    "cd 'baseline' && { "*)
        test ! -e "$IT_SCRATCH_DIR/container" || return 1
        printf 'baseline-healthy-id\n' >"$IT_SCRATCH_DIR/container"
        printf 'restored\n' >>"$ARTIFACT_DIR/events"
        ;;
    esac
}
trap e2e_exit EXIT
main
SH

cat >"$WORK/hook ; literal" <<'SH'
#!/usr/bin/env bash
test ! -e "$IT_SCRATCH_DIR/active" || exit 81
printf 'hook:%s:%s:%s\n' "$#" "$1" "$(cat "$IT_SCRATCH_DIR/container")" >>"$ARTIFACT_DIR/events"
printf 'PRIVATE CALLBACK OUTPUT\n'
printf 'PRIVATE CALLBACK OUTPUT\n' >&2
case "$HOOK_RESULT" in
fail) exit 7 ;;
signal) kill -TERM "$$" ;;
timeout)
    trap '' TERM
    while :; do sleep 1; done
    ;;
esac
SH
chmod +x "$WORK/hook ; literal"
cp "$WORK/hook ; literal" "$WORK/not-executable"
chmod -x "$WORK/not-executable"
mkdir "$WORK/shadow"
printf '#!/usr/bin/env bash\nexit 99\n' >"$WORK/shadow/hook ; literal"
chmod +x "$WORK/shadow/hook ; literal"

drive() {
    local trigger="$1" result="$2" expected="$3" hook="${4-$WORK/hook ; literal}" rc=0 events
    export IT_SCRATCH_DIR="$WORK/$trigger-$result" ARTIFACT_DIR="$WORK/$trigger-$result/artifacts"
    mkdir -p "$ARTIFACT_DIR"
    : >"$ARTIFACT_DIR/events"
    local hook_env=("IT_E2E_PRE_RESTORE_HOOK=$hook")
    [ "$result" != absent ] || hook_env=(-u IT_E2E_PRE_RESTORE_HOOK)
    (cd "$WORK" && env "${hook_env[@]}" TRIGGER="$trigger" HOOK_RESULT="$result" \
        bash "$WORK/driver") >"$ARTIFACT_DIR/log" 2>&1 || rc=$?
    assert_eq "$trigger/$result preserves the original verdict" "$rc" "$expected"
    events="$(cat "$ARTIFACT_DIR/events")"
    if [ "${TEST_MODE:-}" = check ] || [ "${TEST_KEEP:-0}" = 1 ]; then
        assert_eq "$trigger/$result leaves the candidate alone" "$(cat "$IT_SCRATCH_DIR/container")" candidate-original-id
        assert_not_contains "$trigger/$result never invokes the callback" "$events" 'hook:'
        return
    fi
    assert_eq "$trigger/$result restores the healthy baseline" "$(cat "$IT_SCRATCH_DIR/container")" baseline-healthy-id
    if [ -n "$hook" ] && [ "$result" != missing ] && [ "$result" != non-executable ] && [ "$result" != shell-text ]; then
        assert_contains "$trigger/$result observes the original ID and sole status argument" "$events" "hook:1:$expected:candidate-original-id"
        assert_contains "$trigger/$result captures before removal" "$events" $'candidate-original-id\nremove:candidate-original-id\nrestored'
        if [ "$trigger" != pregate ]; then
            assert_contains "$trigger/$result drains before capture" "$events" $'drained\nhook:'
        fi
    else
        assert_not_contains "$trigger/$result never invokes a callback" "$events" 'hook:'
    fi
    local warnings
    warnings="$(grep -c '^E2E pre-restore hook failed; continuing restoration\.$' "$ARTIFACT_DIR/log" || true)"
    case "$result" in
    success | relative | absent | empty) assert_eq "$trigger/$result has no callback warning" "$warnings" 0 ;;
    *) assert_eq "$trigger/$result emits the fixed warning once" "$warnings" 1 ;;
    esac
    assert_not_contains "$trigger/$result suppresses callback output" "$(cat "$ARTIFACT_DIR/log")" 'PRIVATE CALLBACK OUTPUT'
}

for trigger in ordinary pregate cancel; do
    expected=1
    [ "$trigger" != cancel ] || expected=143
    drive "$trigger" success "$expected"
    drive "$trigger" fail "$expected"
done
drive ordinary signal 1
drive ordinary timeout 1
drive pass fail 0
drive ordinary missing 1 "$WORK/missing"
drive ordinary non-executable 1 "$WORK/not-executable"
drive ordinary shell-text 1 "$WORK/hook ; literal; touch $WORK/injected"
assert_eq "hook text is never evaluated by a shell" "$([ -e "$WORK/injected" ] && echo executed || echo literal)" literal
drive ordinary empty 1 ''
drive ordinary absent 1 ''
PATH="$WORK/shadow:$PATH" drive ordinary relative 1 'hook ; literal'
unset IT_E2E_PRE_RESTORE_HOOK
TEST_MODE=check drive pass success 0
TEST_KEEP=1 drive ordinary success 1

printf '\npassed: %s, failed: %s\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
