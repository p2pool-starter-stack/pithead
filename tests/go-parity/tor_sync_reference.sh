#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
fixture_prefix=$2
export EGRESS_SYNC_CLOSE_CHAIN=$3
fixture_state_dir=$4
fixture_monero=$5
fixture_tari=$6
fixture_p2pool=$7
fixture_xvb_enabled=$8
fixture_xvb_tor=$9
export PITHEAD_IMPL=bash
export NO_COLOR=1
export REFERENCE_OS=Linux
export PITHEAD_APPLIANCE=0

# shellcheck source=/dev/null
source "$root/pithead"
env_get() {
    case "$1" in
    NETWORK_PREFIX) printf '%s' "$fixture_prefix" ;;
    MONERO_CLEARNET_SYNC) printf '%s' "$fixture_monero" ;;
    TARI_CLEARNET_SYNC) printf '%s' "$fixture_tari" ;;
    P2POOL_CLEARNET) printf '%s' "$fixture_p2pool" ;;
    XVB_ENABLED) printf '%s' "$fixture_xvb_enabled" ;;
    XVB_TOR_ENABLED) printf '%s' "$fixture_xvb_tor" ;;
    esac
}
clearnet_state_dir() {
    printf '%s' "$fixture_state_dir"
}
tor_egress_sync_ips
