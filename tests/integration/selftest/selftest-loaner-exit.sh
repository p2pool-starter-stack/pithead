#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
WORK="$(mktemp -d)"
cleanup() {
    kill "${borrower:-}" "${previous:-}" "${writer:-}" 2>/dev/null || true
    wait "${borrower:-}" "${previous:-}" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
export TEST_INT_DIR="$HERE/.." TEST_WORK="$WORK" TEST_E2E="$WORK/e2e.sh"
sed -e 's@^HERE=.*@HERE="$TEST_INT_DIR"@' -e '/^main$/d' "$HERE/../e2e.sh" >"$WORK/e2e.sh"
cat >"$WORK/ssh" <<'SSH'
#!/usr/bin/env bash
exec bash -c "${@: -1}"
SSH
chmod +x "$WORK/ssh"
export PATH="$WORK:$PATH"
start_borrower() {
    local dir="$1"
    TEST_BORROW_DIR="$dir" RIG_LOCK_FILE="$dir/other.lock" RIG_LOCK_HOLDER="$dir/other.holder" bash -c '
        source "$TEST_INT_DIR/lib.sh"
        rig_lock pithead other ""
        printf "ready\n" >"$TEST_BORROW_DIR/other.ready"
        exec sleep 300
    ' >"$dir/other.log" 2>&1 &
    borrower=$!
    if ! wait_for 5 .05 "unrelated borrower acquisition" test -s "$dir/other.ready"; then
        cat "$dir/other.log" >&2
        kill "$borrower" 2>/dev/null || true
        wait "$borrower"
        printf 'borrower exit: %s\n' "$?" >&2
        borrower=""
        return 1
    fi
    flock -E 75 -n "$dir/other.lock" true
    assert_rc "acknowledged borrower holds its kernel reservation" "$?" 75
}
start_borrower "$WORK" || exit 1
previous="$borrower"
borrower=""
echo "== every real wrapper exit reaps only its own loaner child =="
for outcome in refusal success restore-failure keep check term; do
    export TEST_OUTCOME="$outcome" TEST_WORK="$WORK/$outcome"
    mkdir "$TEST_WORK"
    start_borrower "$TEST_WORK" || exit 1
    timeout 30 bash <<'DRIVER' >"$TEST_WORK/driver.log" 2>&1
set -- candidate
source "$TEST_E2E"
MODE=targeted KEEP=0 BORROW_MINER=1 BENCH_HOST=fixture MINER_HOST=fixture
RIG_LOCK_FILE="$TEST_WORK/loaner.lock" RIG_LOCK_HOLDER="$TEST_WORK/loaner.holder"
: >"$RIG_LOCK_FILE"
rig_lock_remote pithead 'e2e.sh loaner-borrow' '' fixture
printf '%s\n' "$RIG_LOCK_SSH_PID" >"$TEST_WORK/child.pid"
sleep 300 &
printf '%s\n' "$!" >"$TEST_WORK/writer.pid"
RESTORE_DIR="$TEST_WORK" SAFETY_ARCHIVE='' MINER_CFG_BACKUP='' RESTORED=0
parent_lock_checkpoint() { return 0; }
parent_lock_miner_restore() { return 0; }
drain_harness_or_refuse() { [ "$TEST_OUTCOME" != restore-failure ] || exit 7; }
wallet_fixture_restore() { return 0; }
wallet_fixture_verify() { return 0; }
recreate_test_checkout_containers() { return 0; }
verify_restore_proof() { return 0; }
wait_restore_mining_ready() { return 0; }
on_bench() { printf '%s\n' "$*" >>"$TEST_WORK/restore.calls"; return 0; }
deploy_keeping_chain() { return 0; }
wait_bench_healthy() { return 0; }
wait_synced() { [ "${2:-}" = restore ]; }
case "$TEST_OUTCOME" in
refusal) deploy_branch ;;
success) exit 0 ;;
restore-failure) exit 1 ;;
keep) KEEP=1; exit 1 ;;
check) MODE=check; exit 1 ;;
term) kill -TERM "$$" ;;
esac
DRIVER
    rc=$?
    child="$(cat "$TEST_WORK/child.pid")"
    writer="$(cat "$TEST_WORK/writer.pid")"
    expected=1
    [ "$outcome" != success ] || expected=0
    [ "$outcome" != restore-failure ] || expected=7
    [ "$outcome" != term ] || expected=143
    assert_rc "$outcome preserves its exit status" "$rc" "$expected"
    assert_eq "$outcome reaps its own SSH child despite an inherited writer" "$(kill -0 "$child" 2>/dev/null && echo alive || echo gone)" gone
    flock -n "$TEST_WORK/loaner.lock" true
    assert_rc "$outcome releases its own kernel reservation" "$?" 0
    assert_eq "$outcome leaves the unrelated borrower alive" "$(kill -0 "$borrower" 2>/dev/null && echo alive || echo gone)" alive
    flock -E 75 -n "$TEST_WORK/other.lock" true
    assert_rc "$outcome preserves the unrelated kernel reservation" "$?" 75
    assert_eq "$outcome finishes before the inherited writer exits" "$(kill -0 "$writer" 2>/dev/null && echo alive || echo gone)" alive
    kill "$borrower" 2>/dev/null || true
    wait "$borrower"
    assert_rc "$outcome reaps its unrelated borrower after the trial" "$?" 143
    borrower=""
    flock -n "$TEST_WORK/other.lock" true
    assert_rc "$outcome releases the unrelated reservation after cleanup" "$?" 0
    kill "$writer" 2>/dev/null || true
    wait_for 5 .05 "$outcome inherited writer termination" bash -c '! kill -0 "$1" 2>/dev/null' _ "$writer"
    assert_rc "$outcome finishes inherited writer cleanup" "$?" 0
    writer=""
    if [ "$outcome" = refusal ]; then
        assert_contains "the actual deploy readiness refusal was reached" "$(cat "$TEST_WORK/driver.log")" 'post-deploy chain readiness did not recover within 1500s'
        assert_contains "restoration ran before child release" "$(cat "$TEST_WORK/restore.calls")" './pithead upgrade'
    fi
done
assert_eq "the retained previous reservation survives every trial" "$(kill -0 "$previous" 2>/dev/null && echo alive || echo gone)" alive
flock -E 75 -n "$WORK/other.lock" true
assert_rc "the retained previous reservation is still held" "$?" 75
kill "$previous"
wait "$previous"
assert_rc "the previous borrower is reaped after the isolation control" "$?" 143
previous=""
echo "selftest-loaner-exit: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
