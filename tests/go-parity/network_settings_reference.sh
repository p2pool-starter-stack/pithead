#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
config=$2
monero_mode=$3
tari_mode=$4
second_config=${5:-}
second_monero_mode=${6:-$monero_mode}
second_tari_mode=${7:-$tari_mode}
export PITHEAD_IMPL="${NETWORK_SETTINGS_PARITY_IMPL:-bash}"
export PITHEAD_CONFIG_FILE="$config"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/22-config-value-helpers.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27d-go-network-settings.sh"
if [ "${NETWORK_SETTINGS_WITHOUT_GO_HOOK:-0}" = 1 ]; then unset -f _parse_network_config_go; fi

# shellcheck disable=SC1090
source <(
    printf '_network_settings_block() {\n'
    sed -n '/^[[:space:]]*# Bridge network subnet/,/^[[:space:]]*parse_stratum_endpoint[[:space:]]*$/p' \
        "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
    printf '}\n'
)

NETWORK_SUBNET=seed-network-subnet
NETWORK_PREFIX=seed-network-prefix
TOR_EGRESS_FIREWALL=seed-tor-egress-firewall
TOR_AUTO_HEAL=seed-tor-auto-heal
TARI_EXPLORER_URL=seed-tari-explorer-url
P2POOL_CLEARNET=seed-p2pool-clearnet
MONERO_REMOTE_HOST=seed-monero-remote-host
MONERO_REMOTE_RPC_PORT=seed-monero-remote-rpc-port
MONERO_REMOTE_ZMQ_PORT=seed-monero-remote-zmq-port
TARI_REMOTE_HOST=seed-tari-remote-host
TARI_REMOTE_GRPC_PORT=seed-tari-remote-grpc-port
POOL_TYPE=seed-pool-type

_network_settings_finish() {
    local rc=$?
    trap - EXIT
    printf '\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$NETWORK_SUBNET" "$NETWORK_PREFIX" "$TOR_EGRESS_FIREWALL" "$TOR_AUTO_HEAL" \
        "$TARI_EXPLORER_URL" "$P2POOL_CLEARNET" "$MONERO_REMOTE_HOST" \
        "$MONERO_REMOTE_RPC_PORT" "$MONERO_REMOTE_ZMQ_PORT" "$TARI_REMOTE_HOST" \
        "$TARI_REMOTE_GRPC_PORT" "$POOL_TYPE"
    exit "$rc"
}
trap _network_settings_finish EXIT

MONERO_MODE=$monero_mode
TARI_MODE=$tari_mode
export MONERO_MODE TARI_MODE
_network_settings_block
if [ -n "$second_config" ]; then
    cat "$second_config" >"$CONFIG_FILE"
    MONERO_MODE=$second_monero_mode
    TARI_MODE=$second_tari_mode
    _network_settings_block
fi
