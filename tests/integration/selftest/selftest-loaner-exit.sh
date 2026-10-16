#!/usr/bin/env bash
# Drive the real deploy refusal and EXIT restore with a local SSH transport fixture.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TEST_INT_DIR="$HERE/.." TEST_WORK="$WORK"
sed -e 's@^HERE=.*@HERE="$TEST_INT_DIR"@' -e '/^main$/d' "$HERE/../e2e.sh" >"$WORK/e2e.sh"
cat >"$WORK/ssh" <<'SSH'
#!/usr/bin/env bash
# Execute the real remote helper locally; only the transport is replaced.
exec bash -c "${@: -1}"
SSH
chmod +x "$WORK/ssh"
export PATH="$WORK:$PATH"
echo "== every real wrapper exit reaps only its own loaner child =="
for outcome in refusal success restore-failure keep check term; do
    export TEST_OUTCOME="$outcome"
    timeout 30 bash <<'DRIVER' >"$WORK/$outcome.log" 2>&1
set -- candidate
source "$TEST_WORK/e2e.sh"
MODE=targeted KEEP=0 BORROW_MINER=1 BENCH_HOST=fixture MINER_HOST=fixture
RIG_LOCK_FILE="$TEST_WORK/loaner.lock" RIG_LOCK_HOLDER="$TEST_WORK/loaner.holder"
: >"$RIG_LOCK_FILE"
rig_lock_remote pithead 'e2e.sh loaner-borrow' '' fixture
printf '%s\n' "$RIG_LOCK_SSH_PID" >"$TEST_WORK/child.pid"
# An unrelated borrow is never touched by cleanup of the loaner child.
RIG_LOCK_FILE="$TEST_WORK/other.lock" RIG_LOCK_HOLDER="$TEST_WORK/other.holder" bash -c '
    : >"$RIG_LOCK_FILE"
    source "$TEST_INT_DIR/lib.sh"
    rig_lock pithead other ""
    exec sleep 20
' 8>&- &
other=$!
printf '%s\n' "$other" >"$TEST_WORK/other.pid"
# Deliberately retain an inherited writer after the harness exits.
sleep 20 &
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
    child="$(cat "$WORK/child.pid")"
    other="$(cat "$WORK/other.pid")"
    writer="$(cat "$WORK/writer.pid")"
    expected=1
    [ "$outcome" != success ] || expected=0
    [ "$outcome" != restore-failure ] || expected=7
    [ "$outcome" != term ] || expected=143
    assert_rc "$outcome preserves its exit status" "$rc" "$expected"
    assert_eq "$outcome reaps its own SSH child despite an inherited writer" "$(kill -0 "$child" 2>/dev/null && echo alive || echo gone)" gone
    flock -n "$WORK/loaner.lock" true
    assert_rc "$outcome releases its own kernel reservation" "$?" 0
    assert_eq "$outcome leaves the unrelated borrower alive" "$(kill -0 "$other" 2>/dev/null && echo alive || echo gone)" alive
    kill "$writer" "$other" "$child" 2>/dev/null || true
    if [ "$outcome" = refusal ]; then
        assert_contains "the actual deploy readiness refusal was reached" "$(cat "$WORK/refusal.log")" 'post-deploy chain readiness did not recover within 1500s'
        assert_contains "restoration ran before child release" "$(cat "$WORK/restore.calls")" './pithead upgrade'
    fi
done
echo "selftest-loaner-exit: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
