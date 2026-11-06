#!/usr/bin/env bash

# shellcheck disable=SC2034
set -euo pipefail
script="$1"
fixture="$2"
platform="$3"
cp "$fixture" config.json
cp "$(dirname "$script")/VERSION" VERSION
# shellcheck source=/dev/null
source "$script"
hostname() { printf legacy-machine; }
nproc() { printf 8; }
chown() { return 0; }
detect_host_timezone() { printf UTC; }
MONERO_ONION=monero.onion TARI_ONION=tari.onion P2POOL_ONION=p2pool.onion
DASHBOARD_ONION="" DASHBOARD_ONION_CLIENT_PUBKEY="" DASHBOARD_ONION_CLIENT_PRIVKEY=""
PROXY_AUTH_TOKEN="fixture-proxy-token"
TARI_WALLET_PASSWORD="" WALLET_RPC_PASSWORD=""
PITHEAD_APPLIANCE="$platform"
if [ "$platform" = 1 ] && [ "${4:-}" = platform-defaults ]; then apply_appliance_defaults; fi
parse_and_validate_config
resolve_dashboard_host
render_env
if declare -F config_get >/dev/null; then
    config_get .local_miner.enabled >local-miner.txt
else
    config_bool '.local_miner.enabled' false >local-miner.txt
fi
printf '%s\n' "${DASHBOARD_HOST:-auto}" >dashboard-host.txt
