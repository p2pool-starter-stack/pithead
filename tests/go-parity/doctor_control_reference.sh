#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
export PITHEAD_APPLIANCE=$3
directory=$4
export PITHEAD_UNIT_DIR=$5
fixture_enabled=$6
fixture_spool=$7
export PITHEAD_HUGEPAGES_MARKER=$8
os_type=$9
service=${10:-}
verb=${11:-}
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
# shellcheck disable=SC2153
[ "$OS_TYPE" = "$os_type" ]
cd "$directory"
env_get() {
    case "$1" in
    DASHBOARD_CONTROL_ENABLED) printf '%s' "$fixture_enabled" ;;
    CONTROL_DIR) printf '%s' "$fixture_spool" ;;
    esac
}
config_get() { [ "$1" = .local_miner.enabled ] && printf '%s' "$fixture_enabled"; }

case "$operation" in
unit-dir)
    control_unit_dir
    exit
    ;;
owner)
    owner=$(control_units_owner_dir "$service" "$verb")
    printf '%s' "$owner"
    exit
    ;;
esac

rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"
case "$operation" in
control) check_control_units >&2 ;;
miner) check_local_miner_hugepages_blocked >&2 ;;
*) exit 64 ;;
esac
/bin/cat "$rows"
