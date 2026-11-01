#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

root=$1
fixture=$2
platform=$3
resource_cores=$4
resource_trace=$5
resource_sysctl=${6:-}
script="$root/pithead"
export RESOURCES_TRACE_LOG="$resource_trace"

uname() { printf 'Linux\n'; }
cp "$fixture" config.json
cp "$root/VERSION" VERSION
# shellcheck source=/dev/null
source "$script"

hostname() { printf legacy-machine; }
nproc() {
    printf 'nproc:%s\n' "$resource_cores" >>"$resource_trace"
    [ "$resource_cores" != fail ] || return 99
    printf '%s\n' "$resource_cores"
}
sysctl() {
    printf 'sysctl:%s\n' "$resource_sysctl" >>"$resource_trace"
    [ -n "$resource_sysctl" ] || return 99
    printf '%s\n' "$resource_sysctl"
}
chown() { return 0; }
detect_host_timezone() { printf UTC; }

eval "$(declare -f log | sed '1s/^log /resource_original_log /')"
eval "$(declare -f error | sed '1s/^error /resource_original_error /')"
log() {
    printf 'log:%s\n' "$1" >>"$resource_trace"
    resource_original_log "$@"
}
error() {
    printf 'error:%s\n' "$1" >>"$resource_trace"
    resource_original_error "$@"
}

MONERO_ONION=monero.onion TARI_ONION=tari.onion P2POOL_ONION=p2pool.onion
DASHBOARD_ONION="" DASHBOARD_ONION_CLIENT_PUBKEY="" DASHBOARD_ONION_CLIENT_PRIVKEY=""
PROXY_AUTH_TOKEN="fixture-proxy-token"
TARI_WALLET_PASSWORD="" WALLET_RPC_PASSWORD=""
PITHEAD_APPLIANCE="$platform"
parse_and_validate_config
resolve_dashboard_host
render_env
