#!/usr/bin/env bash
#
# The restore proof must not grade P2Pool and xmrig-proxy before the re-armed sync gate has started
# them again (#3152; bench-ci#1277, #1298). Drives the shipped wait and the shipped restore_all.
# No ssh, no bench, no container runtime.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/restore-mining-ready.sh
source "$HERE/../lib/restore-mining-ready.sh"

echo "== restore waits for the mining services before the proof (#3152) =="

# <polls-until-up|never> <timeout_s> -> "<rc> <polls> <warnings>"
drive_wait() {
    (
        # shellcheck disable=SC2034 # read by the sourced wait
        RESTORE_DIR=/srv/code/baseline
        polls=0 warnings=""
        ok() { :; }
        warn() { warnings="$warnings|$1"; }
        on_bench() {
            case "$1" in
            *"docker compose ps --services --status running"*)
                polls=$((polls + 1))
                [ "$UP_AFTER" != never ] && [ "$polls" -gt "$UP_AFTER" ]
                ;;
            *)
                printf 'restore-mining: stage=mining-services marker=present p2pool=exited proxy=exited\n'
                ;;
            esac
        }
        wait_restore_mining_ready "$2" 0
        rc=$?
        printf '%s %s %s\n' "$rc" "$polls" "$warnings"
    )
}

UP_AFTER=3 out="$(drive_wait 3 100)"
assert_eq "services that come up a few polls late pass" "${out%% *}" "0"
assert_contains "the wait took two consecutive running samples after the start" "$out" " 5 "

UP_AFTER=never out="$(drive_wait never 1)"
assert_eq "services that never come up fail the wait" "${out%% *}" "1"
assert_contains "the timeout names the stage" "$out" "baseline proof stage: mining-services"
assert_contains "the timeout reports the gate marker and service states" "$out" \
    "marker=present p2pool=exited proxy=exited"

# One running sample between stopped ones is a transient release: it must not satisfy the wait.
(
    RESTORE_DIR=/srv/code/baseline
    n=0
    ok() { :; }
    warn() { :; }
    on_bench() {
        case "$1" in
        *"--status running"*)
            n=$((n + 1))
            [ "$n" -eq 2 ] # up only on the second poll, then stopped again
            ;;
        *) echo 'restore-mining: stage=mining-services marker=absent p2pool=exited proxy=running' ;;
        esac
    }
    wait_restore_mining_ready 1 0
    echo "$?"
) >"${TMPDIR:-/tmp}/mining-ready.$$"
assert_eq "a single transient running sample does not satisfy the wait" "$(cat "${TMPDIR:-/tmp}/mining-ready.$$")" "1"
rm -f "${TMPDIR:-/tmp}/mining-ready.$$"

# Malformed diagnostics collapse to the fixed unknown line instead of leaking box output.
diag="$(
    RESTORE_DIR=/x
    on_bench() { echo 'p2pool password=hunter2'; }
    restore_mining_diagnostics
)"
assert_eq "diagnostics outside the fixed grammar are replaced" "$diag" \
    "restore-mining: stage=mining-services marker=unknown p2pool=unknown proxy=unknown"

# restore_all runs the wait after health and before the proof, and a failed wait fails the restore.
RESTORE_SRC="$(sed -n '/^restore_all() {$/,/^}$/p' "$HERE/../e2e.sh")"
assert_eq "the extraction is the whole function" \
    "$(printf '%s\n' "$RESTORE_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "restore_all() { } "
# shellcheck disable=SC2016 # expands inside the child shell
MINING_STUB_SRC='wait_restore_mining_ready() { echo mining >>"$log"; return "$MINING_RC"; }'
drive_restore_rc() {
    RESTORE_SRC="${RESTORE_SRC}" MINING_RC="$1" bash -c '
        log="$(mktemp)"; export log
        exec </dev/null
        MODE=targeted RESTORED=0 KEEP=0 MINER_CFG_BACKUP="" RESTORE_DIR=/srv/code/baseline
        E2E_DIR=/srv/code/pithead-e2e BENCH_HOST=bench SAFETY_ARCHIVE=""
        RESTORE_PROOF_FAILED=0 CONTROL_PROOF_FAILED=0 CONTROL_VERDICT_BEFORE="" BASELINE_IMAGES=""
        log() { :; }; step() { :; }; warn() { :; }; ok() { :; }
        drain_harness_or_refuse() { :; }; parent_lock_checkpoint() { :; }; parent_lock_miner_restore() { :; }
        control_units_verdict() { echo on-target; }
        wallet_fixture_restore() { :; }; wallet_fixture_verify() { :; }; chain_restore_prepare() { :; }
        recreate_test_checkout_containers() { :; }
        wait_synced() { echo synced >>"$log"; }; wait_bench_healthy() { echo healthy >>"$log"; }
        '"$MINING_STUB_SRC"'
        verify_restore_proof() { echo proof >>"$log"; }
        on_bench() { return 0; }
        eval "$RESTORE_SRC"
        # A failed restore ends in `exit 1`; record it instead of ending this shell.
        exit() { echo "exit:$1" >>"$log"; }
        restore_all >/dev/null 2>&1
        tr "\n" " " <"$log"
        rm -f "$log"
    ' 2>/dev/null
}
assert_eq "the wait runs after health and before the proof" \
    "$(drive_restore_rc 0)" "synced healthy mining proof "
assert_eq "a failed wait fails the restore but still runs the proof" \
    "$(drive_restore_rc 1)" "synced healthy mining proof exit:1 "

echo ""
printf 'restore-mining-ready self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
