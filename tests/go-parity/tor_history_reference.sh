#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
directory=$3
fixture_outage=$4
fixture_at=$5
fixture_now=$6
fixture_prefix=$7
fixture_mount=$8
export PITHEAD_APPLIANCE=$9
fixture_mount_ok=${10}
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
date() { printf '%s\n' "$fixture_now"; }
env_get() { [ "$1" != NETWORK_PREFIX ] || printf '%s' "$fixture_prefix"; }
tor_recovery_mount() {
    [ "$fixture_mount_ok" = 1 ] || return 1
    printf '%s\n' "$fixture_mount"
}
: >"$directory/tools.log"

case "$operation" in
next)
    mutation_lock_acquire() { _PITHEAD_LOCK_OWNED=1; }
    control_write_result() {
        if [ "$2" = tor-heal-outage ]; then
            printf '%s\n' "$3" >"$directory/results/tor-heal-outage.json"
        fi
    }
    control_audit() { :; }
    fixture_mount_ok=0
    control_tor_history "$directory" fixture tor-heal "$fixture_outage" "$fixture_at"
    ;;
valid) tor_recovery_heal_outage "$directory" ;;
saturated) tor_recovery_state_saturated "$fixture_mount/state" ;;
egress) tor_recovery_egress_down ;;
doctor)
    export DR_JSON_FILE="$directory/doctor.rows"
    : >"$DR_JSON_FILE"
    check_tor_circuit_history >&2
    /bin/cat "$DR_JSON_FILE"
    ;;
*) exit 64 ;;
esac
