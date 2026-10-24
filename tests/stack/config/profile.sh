#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:?}/pithead-profiles.XXXXXX")
export PITHEAD_CONFIG_FILE="$WORK/config.json" PITHEAD_ENV_FILE="$WORK/.env"
source "$ROOT/pithead"
cd "$WORK"
cp "$ROOT/VERSION" VERSION
WALLET_RPC_PASSWORD=fixture TARI_WALLET_PASSWORD=fixture PROXY_AUTH_TOKEN=fixture
PITHEAD_DRY_RUN=1
PITHEAD_ENV_DRYRUN="$ENV_FILE"
MONERO_ONION=fixture TARI_ONION=fixture P2POOL_ONION=fixture DASHBOARD_ONION=""
DASHBOARD_ONION_CLIENT_PUBKEY="" DASHBOARD_ONION_CLIENT_PRIVKEY="" HOST_IP=localhost
read_render() {
    local key
    for key in PITHEAD_PROFILE P2POOL_FLAGS P2POOL_CLEARNET TOR_EGRESS_FIREWALL XVB_TOR_ENABLED NOTIFY_TOR TOR_AUTO_HEAL PROXY_STRATUM_TLS XMRIG_API_AUTH PROXY_STRATUM_PASSWORD XMRIG_API_TOKEN MONERO_CLEARNET_SYNC TARI_CLEARNET_SYNC; do
        printf -v "$key" '%s' "$(env_get "$key")"
    done
}
log() { printf '%s\n' "$*"; }
is_appliance() { return 1; }
for profile in performance balance privacy; do
    jq -n --arg profile "$profile" '{profile:$profile,monero:{wallet_address:"48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD",node_username:"fixture",node_password:"fixture"},tari:{mode:"local",wallet_address:"126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ"},dashboard:{secure:false}}' >"$CONFIG_FILE"
    parse_and_validate_config >"$WORK/parse.log"
    render_env >"$WORK/render.log"
    read_render
    printf "testing %s: %s:%s:%s:%s:%s:%s:%s:%s:%s\n" "$profile" "$MONERO_CLEARNET_SYNC" "$TARI_CLEARNET_SYNC" "$P2POOL_CLEARNET" "$TOR_EGRESS_FIREWALL" "$XVB_TOR_ENABLED" "$NOTIFY_TOR" "$TOR_AUTO_HEAL" "$PROXY_STRATUM_TLS" "$XMRIG_API_AUTH"
    [ "$PITHEAD_PROFILE" = "$profile" ]
    [[ "$P2POOL_FLAGS" == *--no-upnp* ]]
    if [ "$profile" = performance ]; then
        [ "$MONERO_CLEARNET_SYNC:$TARI_CLEARNET_SYNC:$P2POOL_CLEARNET:$TOR_EGRESS_FIREWALL:$XVB_TOR_ENABLED:$NOTIFY_TOR:$TOR_AUTO_HEAL:$PROXY_STRATUM_TLS:$XMRIG_API_AUTH" = true:true:true:false:false:false:false:false:none ]
        [[ "$P2POOL_FLAGS" != *--socks5* && "$P2POOL_FLAGS" != *--no-clearnet-p2p* ]]
        [ -z "$PROXY_STRATUM_PASSWORD$XMRIG_API_TOKEN" ]
    elif [ "$profile" = balance ]; then
        [ "$MONERO_CLEARNET_SYNC:$TARI_CLEARNET_SYNC:$P2POOL_CLEARNET:$TOR_EGRESS_FIREWALL:$XVB_TOR_ENABLED:$NOTIFY_TOR:$TOR_AUTO_HEAL:$PROXY_STRATUM_TLS:$XMRIG_API_AUTH" = false:false:false:true:true:true:true:false:none ]
        [[ "$P2POOL_FLAGS" == *--socks5* && "$P2POOL_FLAGS" != *--no-clearnet-p2p* ]]
        [ -z "$PROXY_STRATUM_PASSWORD$XMRIG_API_TOKEN" ]
        [[ "$(profile_status)" == *'auto-heal is inactive'* ]]
    else
        [ "$MONERO_CLEARNET_SYNC:$TARI_CLEARNET_SYNC:$P2POOL_CLEARNET:$TOR_EGRESS_FIREWALL:$XVB_TOR_ENABLED:$NOTIFY_TOR:$TOR_AUTO_HEAL:$PROXY_STRATUM_TLS:$XMRIG_API_AUTH" = false:false:false:true:true:true:true:true:token ]
        [[ "$P2POOL_FLAGS" == *--socks5* && "$P2POOL_FLAGS" == *--no-clearnet-p2p* ]]
        [[ "$PROXY_STRATUM_PASSWORD" =~ ^[0-9a-f]{24}$ && "$XMRIG_API_TOKEN" =~ ^[0-9a-f]{48}$ ]]
        token_before="$XMRIG_API_TOKEN" password_before="$PROXY_STRATUM_PASSWORD"
        render_env >"$WORK/render.log"
        read_render
        [ "$XMRIG_API_TOKEN" = "$token_before" ] && [ "$PROXY_STRATUM_PASSWORD" = "$password_before" ]
    fi
    [[ "$(describe_change PITHEAD_PROFILE balance "$profile")" == CONFIRM$'\t'* ]]
    printf 'PASS: %s profile render and confirmation\n' "$profile"
done
jq '.profile="performance" | .p2pool.clearnet=false' "$CONFIG_FILE" >"$WORK/next"
cp "$WORK/next" "$CONFIG_FILE"
[ "$(config_bool .p2pool.clearnet true)" = false ]
[[ "$(profile_status)" == *'Custom (performance)'* ]]
profile_select "$CONFIG_FILE" privacy
jq '.p2pool.clearnet=true' "$CONFIG_FILE" >"$WORK/next"
cp "$WORK/next" "$CONFIG_FILE"
parse_and_validate_config >"$WORK/parse.log"
render_env >"$WORK/render.log"
read_render
[[ "$P2POOL_FLAGS" != *--no-clearnet-p2p* && "$P2POOL_FLAGS" != *--socks5* ]]
jq '.profile="performance" | .monero.mode="remote" | .monero.remote={host:"node.example",rpc_port:18081,zmq_port:18083} | .tari.mode="remote" | .tari.remote={host:"tari.example",grpc_port:18142}' "$CONFIG_FILE" >"$WORK/next"
cp "$WORK/next" "$CONFIG_FILE"
parse_and_validate_config >"$WORK/parse.log"
render_env >"$WORK/render.log"
read_render
[ "$MONERO_CLEARNET_SYNC:$TARI_CLEARNET_SYNC" = false:false ]
printf 'PASS: explicit overrides, selection, remote node guards\n'
mkdir -p "$WORK/bin"
cat >"$WORK/bin/p2pool" <<'EOF'
#!/usr/bin/env bash
for attempt in {1..100}; do
    [ ! -s "$BRIDGE_CAPTURE" ] || exit 0
    sleep 0.01
done
exit 1
EOF
cat >"$WORK/bin/socat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BRIDGE_CAPTURE"
EOF
chmod +x "$WORK/bin/p2pool" "$WORK/bin/socat"
export BRIDGE_CAPTURE="$WORK/bridge"
PATH="$WORK/bin:$PATH" P2POOL_FLAGS='--mini --no-clearnet-p2p' NETWORK_PREFIX=10.84.0 P2POOL_PORT=37888 bash "$ROOT/build/p2pool/entrypoint.sh" >"$WORK/entrypoint.log" 2>&1
[ "$(cat "$BRIDGE_CAPTURE")" = 'TCP4-LISTEN:37888,bind=10.84.0.28,range=10.84.0.25/32,fork,reuseaddr TCP4:127.0.0.1:37888' ]
if PATH="$WORK/bin:$PATH" P2POOL_FLAGS=--no-clearnet-p2p NETWORK_PREFIX=10.84.0 P2POOL_PORT=3333 bash "$ROOT/build/p2pool/entrypoint.sh" >>"$WORK/entrypoint.log" 2>&1; then exit 1; fi
for chain in monero tari; do
    (
        # shellcheck disable=SC1090
        PITHEAD_TEST_SOURCE=1 source "$ROOT/build/$chain/entrypoint.sh"
        CLEARNET_MARKER="$WORK/synced"
        touch "$CLEARNET_MARKER"
        MONERO_CLEARNET_SYNC=true TARI_CLEARNET_SYNC=true PITHEAD_PROFILE=performance
        clearnet_sync_active
        PITHEAD_PROFILE=balance
        if clearnet_sync_active; then exit 1; fi
    )
done
printf 'PASS: source-restricted peer-port bridge and persistent clearnet operation\n'

(
    env_get() {
        case "$1" in
        PITHEAD_PROFILE) printf '%s' "$selected_profile" ;;
        NETWORK_PREFIX) printf '10.84.0' ;;
        MONERO_CLEARNET_SYNC | TARI_CLEARNET_SYNC) printf true ;;
        esac
    }
    clearnet_state_dir() { printf '%s' "$WORK"; }
    mutation_lock_path() { printf '%s' "$WORK/mutation"; }
    touch "$WORK/monero.synced" "$WORK/tari.synced"
    selected_profile=performance
    [ "$(tor_egress_sync_ips)" = $'10.84.0.26\n10.84.0.27' ]
    mkdir -p "$(tor_egress_choice_marker)"
    arm_tor_egress_choice_marker
    [ -d "$(tor_egress_choice_marker)/monero" ] && [ -d "$(tor_egress_choice_marker)/tari" ]
    rendered=$(render_tor_egress_boot_unit /sbin/iptables 10.84.0.0/24 10.84.0.25 10.84.0.26 10.84.0.27)
    [[ "$rendered" == *'test -d '*'/monero'* && "$rendered" == *'test -d '*'/tari'* ]]
    if egress_sync_refresh monero; then exit 1; fi
    selected_profile=balance
    [ -z "$(tor_egress_sync_ips)" ]
    prune_tor_egress_choice_markers
    [ ! -e "$(tor_egress_choice_marker)/monero" ] && [ ! -e "$(tor_egress_choice_marker)/tari" ]
)
printf 'PASS: explicit firewall override keeps Performance nodes admitted across sync and boot; stale Tor transitions rejected\n'

rm -f "$CONFIG_FILE"
[ "$(profile_status)" = "Profile: unavailable (configuration missing)." ]
printf 'PASS: profile display tolerates a missing configuration without changing health status\n'
