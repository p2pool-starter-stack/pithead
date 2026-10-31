#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
directory=$3
export PITHEAD_APPLIANCE=$4
fixture_completed=$5
export PITHEAD_ENV_FILE=$6
shift 6
fixture_dirs=("$@")
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
cd "$directory"
env_get() {
    case "$1" in
    DEPLOYMENT_COMPLETED) printf '%s' "$fixture_completed" ;;
    MONERO_DATA_DIR) printf '%s' "${fixture_dirs[0]:-}" ;;
    TARI_DATA_DIR) printf '%s' "${fixture_dirs[1]:-}" ;;
    P2POOL_DATA_DIR) printf '%s' "${fixture_dirs[2]:-}" ;;
    DASHBOARD_DATA_DIR) printf '%s' "${fixture_dirs[3]:-}" ;;
    TOR_DATA_DIR) printf '%s' "${fixture_dirs[4]:-}" ;;
    esac
}

data_findings_reference() {
    local body starts
    starts=$(grep -Fxc '    local _stale _l' "$root/lib/pithead/06-doctor.sh")
    [ "$starts" = 1 ]
    body=$(awk '$0 == "    local _stale _l"{found=1} found{print} found && $0 == "    fi"{exit}' "$root/lib/pithead/06-doctor.sh")
    eval "$body"
}

deployment_reference() {
    local body starts
    # shellcheck disable=SC2016
    starts=$(grep -Fxc '    if [ ! -f "$ENV_FILE" ]; then' "$root/lib/pithead/06-doctor.sh")
    [ "$starts" = 1 ]
    body=$(awk '$0 == "    if [ ! -f \"$ENV_FILE\" ]; then"{found=1} found{print} found && $0 == "        fi"{exit}' "$root/lib/pithead/06-doctor.sh")
    eval "$body"$'\nfi'
}

case "$operation" in
missing)
    missing_data_dirs
    exit
    ;;
warnings)
    warn_missing_data_dirs
    exit
    ;;
esac

rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"
case "$operation" in
findings) data_findings_reference >&2 ;;
deployment) deployment_reference >&2 ;;
*) exit 64 ;;
esac
/bin/cat "$rows"
