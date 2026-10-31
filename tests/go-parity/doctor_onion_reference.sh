#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
export PITHEAD_APPLIANCE=$3
fixture_profiles=$4
fixture_enabled=$5
fixture_dashboard=$6
fixture_auth=$7
shift 7
fixture_addresses=("$@")
export PITHEAD_IMPL=bash
export NO_COLOR=1
[ "$0" != "$root/pithead" ] || exit 64

# shellcheck source=/dev/null
source "$root/pithead"
env_get() {
    case "$1" in
    COMPOSE_PROFILES) printf '%s' "$fixture_profiles" ;;
    MONERO_ONION_ADDRESS) printf '%s' "${fixture_addresses[0]:-}" ;;
    TARI_ONION_ADDRESS) printf '%s' "${fixture_addresses[1]:-}" ;;
    P2POOL_ONION_ADDRESS) printf '%s' "${fixture_addresses[2]:-}" ;;
    DASHBOARD_ONION_ENABLED) printf '%s' "$fixture_enabled" ;;
    DASHBOARD_ONION_ADDRESS) printf '%s' "$fixture_dashboard" ;;
    DASHBOARD_ONION_CLIENT_AUTH) printf '%s' "$fixture_auth" ;;
    esac
}

onion_findings_reference() {
    local body starts
    starts=$(grep -Fxc '        local k onion onion_profiles needs onion_fix' "$root/lib/pithead/06-doctor.sh")
    [ "$starts" = 1 ]
    body=$(awk '$0 == "        local k onion onion_profiles needs onion_fix"{found=1} found{print} found && $0 == "        fi"{exit}' "$root/lib/pithead/06-doctor.sh")
    eval "$body"
}

case "$operation" in
missing)
    onion_missing "${fixture_addresses[0]:-}"
    exit
    ;;
dashboard)
    dashboard_onion_status
    exit
    ;;
esac

rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"
onion_findings_reference >&2
/bin/cat "$rows"
