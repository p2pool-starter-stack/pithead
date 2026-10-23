#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/lib/pithead/01-lifecycle.sh"
source "$ROOT/lib/pithead/14-local-miner.sh"
td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT

probe() (
    local appliance=$1 enabled=$2 hold=$3 compose_rc=$4 miner_rc=$5
    local locked=0 started=0
    export PITHEAD_HOLD_CHAIN=$hold
    export REVENUE_CHAIN_CONTAINERS="monerod tari wallet-rpc tari-wallet"
    mutation_lock_acquire() { locked=1; }
    mutation_lock_release() {
        locked=0
        printf 'released\n'
    }
    validate_config_document() { :; }
    log() { :; }
    warn() { :; }
    error() { exit 1; }
    warn_missing_data_dirs() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    provision_egress_check_units() { :; }
    provision_lan_guard_check_units() { :; }
    verify_release_images() { :; }
    print_clearnet_banner() { :; }
    announce_dashboard_url() { :; }
    print_first_run_epilogue() { :; }
    env_get() { printf '%s' "$td"; }
    rearm_sync_gate_marker() { :; }
    docker() { printf 'tor\nmonerod\np2pool\n'; }
    compose_up_checked() {
        [ "$locked" = 1 ] || exit 10
        started=1
        printf 'compose\n'
        return "$compose_rc"
    }
    is_appliance() { [ "$appliance" = 1 ]; }
    machine_role() { printf both; }
    rigforge_dir() { printf '%s' "$td"; }
    config_bool() { printf '%s' "$enabled"; }
    local_miner_hugepages_blocked() { [ "${blocked:-0}" = 1 ]; }
    render_local_miner_config() {
        printf 'render\n'
        printf '{}' >"$td/config.json"
    }
    rigforge_setup_run() {
        [ "$locked:$started" = 1:1 ] || exit 11
        printf 'miner\n'
        return "$miner_rc"
    }
    systemctl() { printf 'systemctl %s\n' "$*" >>"$td/stops"; }
    rm -f "$td/config.json" "$td/stops"
    stack_up
)

check() {
    local expected=$1 actual
    shift
    actual=$(probe "$@")
    [ "$actual" = "$expected" ] || {
        printf 'FAIL: up contract (%s), got %s\n' "$*" "$actual" >&2
        exit 1
    }
}
check $'compose\nrender\nminer\nreleased' 1 true 0 0 0
check $'compose\nreleased' 1 false 0 0 0
grep -qx 'systemctl stop xmrig.service' "$td/stops"
check $'compose\nreleased' 0 true 0 0 0
[ ! -e "$td/stops" ]
check $'compose\nreleased' 1 true 1 0 0
[ ! -e "$td/stops" ]
blocked=1 check $'compose\nreleased' 1 true 0 0 0
grep -qx 'systemctl stop xmrig.service' "$td/stops"
check $'compose\nrender\nminer\nreleased' 1 true 0 0 1
if output=$(probe 1 true 0 1 0); then
    printf 'FAIL: compose failure succeeded\n' >&2
    exit 1
fi
[ "$output" = compose ]
printf 'local miner up selftest: PASS (7 lifecycle cases)\n'
