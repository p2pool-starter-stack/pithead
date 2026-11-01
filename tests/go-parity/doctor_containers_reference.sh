#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
directory=$3
fixture_hold=$4
fixture_name=$5
fixture_state=$6
fixture_status=$7
fixture_chain_hold=$8
export PITHEAD_IMPL=bash
export PITHEAD_APPLIANCE=0
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
os_migration_hold_active() { [ "$fixture_hold" = 1 ]; }
: >"$directory/calls.log"
printf '0\n' >"$directory/step"

case "$operation" in
verdict)
    revenue_container_verdict "$fixture_name" "$fixture_state" "$fixture_status" "$fixture_chain_hold"
    exit
    ;;
names)
    if container_restarting_names; then exit 0; else exit 1; fi
    ;;
esac

export DR_JSON_FILE="$directory/rows"
: >"$DR_JSON_FILE"
case "$operation" in
restarts) check_container_restarts >&2 ;;
revenue) check_revenue_containers >&2 ;;
*) exit 64 ;;
esac
/bin/cat "$DR_JSON_FILE"
