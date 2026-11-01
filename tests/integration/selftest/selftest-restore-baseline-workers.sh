#!/usr/bin/env bash
# Exercise the real rollback with changing API responses; no daemon or network.
set -euo pipefail
echo "== Image-upgrade rollback worker reconnection =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-state-support.sh
source "$HERE/lib/live-state-support.sh"
# Extract only rollback so unrelated trust/transport setup cannot affect the fixture.
eval "$(sed -n '/^restore_upgrade_baseline() {/,/^}/p' "$HERE/lib/live-upgrade-support.sh")"
td="$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/restore-workers.XXXXXX")"
trap 'rm -rf "$td"' EXIT

run_case() (
    scenario=$1
    printf '0\n' >"$td/reads"
    clock=0
    now_s() { echo "$clock"; }
    sleep() { clock=$((clock + $1)); }
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    BOUND_RECONNECT=10 EXPECTED_WORKERS=1
    _UPGRADE_RESTORE_ARMED=1 _SAFETY_RESTORE_ARMED=1
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    UPGRADE_BASELINE_REGISTRY=fixture UPGRADE_BASELINE_DIR=baseline
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    UPGRADE_ROLLBACK_DIR=baseline SAFETY_ARCHIVE=archive
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    UPGRADE_STAGE_DIR="$td/stage" UPGRADE_CANDIDATE_DIR="$td/candidate"
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    BASELINE_CONFIG=config UPGRADE_BEFORE_SECRETS=secrets UPGRADE_BEFORE_DERIVED=derived
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    UPGRADE_BEFORE_REFS=refs UPGRADE_BEFORE_REVISIONS=revisions UPGRADE_BEFORE_MOUNTS=mounts
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    UPGRADE_BEFORE_WORKERS=miner UPGRADE_BEFORE_MONERO=10 UPGRADE_BEFORE_TARI=10
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    UPGRADE_BEFORE_MONERO_ID=block UPGRADE_BEFORE_TARI_ID=block
    # shellcheck disable=SC2034 # consumed by the sed-extracted rollback function
    UPGRADE_TELEMETRY_EPOCH=0 UPGRADE_BEFORE_TELEMETRY=rows
    pithead() { :; }
    repoint_baseline_install() { :; }
    restore_state_snapshots() { :; }
    start_restored_baseline() { :; }
    cleanup_state_snapshots() { :; }
    rx() {
        case "$1" in
        'cat config.json') echo config ;;
        *'date +%s'*) echo "100 42" ;;
        *MainPID*) echo 42 ;;
        *journalctl*) return 1 ;;
        *) return 1 ;;
        esac
    }
    upgrade_secret_fingerprints() { echo secrets; }
    derived_state_fingerprint() { echo derived; }
    all_running_refs() { echo refs; }
    first_party_revisions() { echo revisions; }
    stateful_mounts() { echo mounts; }
    monero_chain_tip() { echo '10 block'; }
    chain_tip_valid() { return 0; }
    height_continues() { [ "$2" -ge "$1" ]; }
    monero_block_identity() { echo block; }
    tari_block_identity() { echo block; }
    dashboard_durable_rows() { echo rows; }
    telemetry_rows_continue() { [ "$1" = "$2" ]; }
    worker_names() { api_state | jq -r '.workers[]?.name' | sort -u; }
    api_state() {
        n=$(($(cat "$td/reads") + 1))
        printf '%s\n' "$n" >"$td/reads"
        name=miner count=1
        case "$scenario" in
        converges) [ "$n" -ge 4 ] || {
            name=""
            count=0
        } ;;
        never) name="" count=0 ;;
        wrong) name=other ;;
        flap) [ "$n" = 1 ] || {
            name=""
            count=0
        } ;;
        esac
        jq -n --arg name "$name" --argjson count "$count" \
            '{workers: (if $name == "" then [] else [{name:$name}] end), proxy_workers:$count,
              sync:{monero:{state:"done"},tari:{state:"done",current:10}},stratum:{total_hashes:1}}'
    }
    rc=0
    restore_upgrade_baseline >"$td/output" 2>&1 || rc=$?
    case "$scenario" in
    converges)
        [ "$rc" = 0 ] && [ "$(cat "$td/reads")" = 4 ] || return 1
        grep -Fq 'exact pre-upgrade release baseline restored' "$td/output"
        ;;
    never | flap)
        [ "$rc" = 1 ] && [ "$clock" = 10 ] || return 1
        grep -Fq 'differs: workers proxy-workers;' "$td/output" || return 1
        grep -Fq "rollback worker set: expected=1 observed=0 missing=[8b133a38] extra=[]" "$td/output" || return 1
        [ "${SAFETY_RESTORE_FAILED:-0}" = 1 ] && [ "$_SAFETY_RESTORE_ARMED" = 0 ]
        ;;
    wrong)
        [ "$rc" = 1 ] && [ "$clock" = 10 ] || return 1
        grep -Fq 'differs: workers;' "$td/output" || return 1
        grep -Fq "rollback worker set: expected=1 observed=1 missing=[8b133a38] extra=[d9298a10]" "$td/output" || return 1
        ! grep 'rollback worker set' "$td/output" | grep -Eq 'miner|other'
        ;;
    esac
)
for scenario in converges never wrong flap; do
    if run_case "$scenario"; then
        printf 'PASS: rollback workers %s\n' "$scenario"
    else
        printf 'FAIL: rollback workers %s\n' "$scenario" >&2
        cat "$td/output" >&2
        exit 1
    fi
done

# Exercise the actual forward wait expression without running an upgrade.
forward_wait="$(sed -n '/^[[:space:]]*wait_for .*"the exact pre-upgrade worker set"/s/ ||.*//p' "$HERE/lib/live-gates.sh")"
[ -n "$forward_wait" ]
wait_for() { printf '%s\n' "$1"; }
# shellcheck disable=SC2034 # consumed by the extracted forward wait
before_workers=miner
unset BOUND_RECONNECT
[ "$(eval "$forward_wait")" = 480 ]
# shellcheck disable=SC2034 # consumed by the extracted forward wait
BOUND_RECONNECT=37
[ "$(eval "$forward_wait")" = 37 ]
echo 'PASS: forward worker wait uses reconnect bound'

observation_case() (
    mode=$1
    rx() {
        case "$1" in
        *'date +%s'*) echo '100 42' ;;
        *MainPID*)
            case "$mode" in changed) echo 43 ;; unchanged | journal | absent) echo 42 ;; *) return 1 ;; esac
            ;;
        *journalctl*)
            [[ "$1" == *'--since=@100'* ]] || return 1
            case "$mode" in
            journal) echo 'pithead-miner-recovery: active local miner disconnected for 300 seconds; restarting xmrig' ;;
            absent | changed | unchanged) echo 'private fixture journal content' ;;
            *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
        esac
    }
    start="$(upgrade_miner_observation_start)"
    [ "$start" = '100 42' ] || return 1
    out="$(upgrade_miner_observation_finish "$start")"
    case "$mode" in
    changed) expected='MainPID changed=yes; recovery-agent journal line=no' ;;
    unchanged | absent) expected='MainPID changed=no; recovery-agent journal line=no' ;;
    journal) expected='MainPID changed=no; recovery-agent journal line=yes' ;;
    unavailable) expected='MainPID changed=unavailable; recovery-agent journal line=unavailable' ;;
    esac
    [[ "$out" == "[ITEST] rollback miner observation: $expected" ]] || return 1
    [[ "$out" != *private* ]]
)
for mode in changed unchanged journal absent unavailable; do
    observation_case "$mode"
done
echo 'PASS: rollback miner observations are informational and bounded'
