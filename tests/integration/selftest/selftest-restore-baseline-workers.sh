#!/usr/bin/env bash
# Exercise the real rollback with changing API responses; no daemon or network.
set -euo pipefail
echo "== Image-upgrade rollback worker reconnection =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
source "$HERE/lib/fake-eventual.sh"
# shellcheck source=tests/integration/lib/live-state-support.sh
source "$HERE/lib/live-state-support.sh"
eval "$(sed -n '/^restore_upgrade_baseline() {/,/^}/p' "$HERE/lib/live-upgrade-support.sh")"
td="$(mktemp -d)"
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
        local ready='{"workers":[{"name":"miner"}],"proxy_workers":1,"sync":{"monero":{"state":"done"},"tari":{"state":"done","current":10}},"stratum":{"total_hashes":1}}'
        local empty='{"workers":[],"proxy_workers":0,"sync":{"monero":{"state":"done"},"tari":{"state":"done","current":10}},"stratum":{"total_hashes":1}}'
        case "$scenario" in
        converges) fake_eventual "$td/reads" after 3 "$empty" "$ready" ;;
        never) fake_eventual "$td/reads" never 0 "$empty" "$ready" ;;
        wrong) fake_eventual "$td/reads" after 0 "$empty" "${ready/miner/other}" ;;
        flap) fake_eventual "$td/reads" after 1 "$ready" "$empty" ;;
        esac
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
        [ "${SAFETY_RESTORE_FAILED:-0}" = 1 ] && [ "$_SAFETY_RESTORE_ARMED" = 0 ]
        ;;
    wrong)
        [ "$rc" = 1 ] && [ "$clock" = 10 ] || return 1
        grep -Fq 'differs: workers;' "$td/output"
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
