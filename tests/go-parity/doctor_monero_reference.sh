#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
directory=$3
export PITHEAD_APPLIANCE=$4
fixture_user=$5
fixture_pass=$6
fixture_url=$7
fixture_now=$8
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
env_get() {
    case "$1" in
    MONERO_NODE_USERNAME) printf '%s' "$fixture_user" ;;
    MONERO_NODE_PASSWORD) printf '%s' "$fixture_pass" ;;
    MONERO_RPC_URL) printf '%s' "$fixture_url" ;;
    esac
}
date() { printf '%s\n' "$fixture_now"; }
: >"$directory/calls.log"

if [ "$operation" = counts ]; then
    if monerod_peer_counts; then exit 0; else exit 1; fi
fi

export DR_JSON_FILE="$directory/rows"
: >"$DR_JSON_FILE"
case "$operation" in
sync) if check_monerod_synchronized >&2; then :; else exit 1; fi ;;
peers) if monerod_peers_and_tip "$fixture_user" "$fixture_pass" "$fixture_url" >&2; then :; else exit 1; fi ;;
*) exit 64 ;;
esac
/bin/cat "$DR_JSON_FILE"
