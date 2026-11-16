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
        cleanup_rotate_onion_fixture() { echo cleanup >>"$log"; }
        wait_synced() { echo synced >>"$log"; }; wait_bench_healthy() { echo healthy >>"$log"; }
        '"$MINING_STUB_SRC"'
        verify_restore_proof() { echo proof >>"$log"; return "${VERIFY_RC:-0}"; }
        recheck_restore_mining() { echo "recheck $1" >>"$log"; return "${RECHECK_RC:-0}"; }
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
    "$(drive_restore_rc 0)" "synced healthy mining proof cleanup recheck 600 "
assert_eq "a failed wait fails the restore, still runs the proof and skips the re-check" \
    "$(drive_restore_rc 1)" "synced healthy mining proof cleanup exit:1 "
assert_eq "a failed proof skips the re-check so no healthy line precedes the failure" \
    "$(VERIFY_RC=1 drive_restore_rc 0)" "synced healthy mining proof cleanup exit:1 "
assert_eq "a failed re-check fails the restore" \
    "$(RECHECK_RC=1 drive_restore_rc 0)" "synced healthy mining proof cleanup recheck 600 exit:1 "

echo "== the re-check catches a dashboard stop after the first sample (#4167) =="
drive_recheck() {
    (
        # shellcheck disable=SC2034
        RESTORE_DIR=/srv/code/baseline
        polls=0 out="" started=0
        ok() { out="$out|ok:$1"; }
        warn() { out="$out|warn:$1"; }
        on_bench() {
            case "$1" in
            *"docker inspect"*)
                local i=$polls
                polls=$((polls + 1))
                [ "${SEQ:$((i < ${#SEQ} ? i : ${#SEQ} - 1)):1}" = 1 ]
                ;;
            *"compose up"* | *"docker start"* | *"compose start"*) started=1 ;;
            *) echo 'restore-mining: stage=mining-services marker=absent p2pool=running proxy=exited' ;;
            esac
        }
        recheck_restore_mining "$1" 0
        rc=$?
        printf '%s %s %s%s\n' "$rc" "$polls" "$started" "$out"
    )
}
SEQ=1 out="$(drive_recheck 5)"
assert_contains "a stack still healthy passes at once" "$out" "0 1 0|ok:re-check"
SEQ=0001 out="$(drive_recheck 5)"
assert_eq "a stop at the re-check is waited out and passes once readmitted" "${out%% *}" "0"
assert_contains "the wait start is logged" "$out" "waiting up to 5s for the dashboard to readmit"
assert_contains "the elapsed time is logged" "$out" "healthy again after waiting"
SEQ=0 out="$(drive_recheck 1)"
assert_eq "a proxy that stays stopped fails the re-check" "${out%% *}" "1"
assert_contains "the failure names xmrig-proxy and the time waited" "$out" "xmrig-proxy (or P2Pool) still not running and healthy after waiting 1s"

probe_health() {
    local dir rc
    dir="$(mktemp -d)"
    mkdir "$dir/bin"
    cat >"$dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "$1 $2" >>"$CALLS"
case "$1 $2" in
"compose ps") [ "${*: -1}" = gone ] || printf 'cid-%s\n' "${*: -1}" ;;
"inspect --format") case "${*: -1}" in cid-p2pool) printf '%s\n' "$P2P" ;; cid-xmrig-proxy) printf '%s\n' "$PROXY" ;; esac ;;
esac
DOCKER
    chmod +x "$dir/bin/docker"
    (
        export PATH="$dir/bin:$PATH" CALLS="$dir/calls" P2P="$1" PROXY="$2"
        RESTORE_DIR="$dir"
        on_bench() { bash -c "$1"; }
        _restore_mining_healthy
    )
    rc=$?
    printf '%s %s' "$rc" "$(sort -u "$dir/calls" | tr '\n' ',')"
    rm -rf "$dir"
}
assert_eq "running services with and without a healthcheck are healthy" \
    "$(probe_health 'running healthy' 'running ' | cut -d' ' -f1)" "0"
assert_eq "an unhealthy proxy is not healthy" "$(probe_health 'running healthy' 'running unhealthy' | cut -d' ' -f1)" "1"
assert_eq "a starting p2pool is not healthy" "$(probe_health 'running starting' 'running healthy' | cut -d' ' -f1)" "1"
assert_eq "a stopped proxy is not healthy" "$(probe_health 'running healthy' 'exited ' | cut -d' ' -f1)" "1"
assert_eq "the probe only lists and inspects, never starts" \
    "$(probe_health 'running healthy' 'exited ' | cut -d' ' -f2-)" "compose ps,inspect --format,"

echo ""
printf 'restore-mining-ready self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
