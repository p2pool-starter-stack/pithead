#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
target=$2
export PITHEAD_IMPL="${CADDY_PARITY_IMPL:-bash}"

C_RESET=''
C_GREEN=''
C_YELLOW=''
C_RED=''
log() { echo -e "${C_GREEN}[pithead]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1" >&2; }
error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2
    exit 1
}

record_call() { printf '%s\n' "$1" >>"$CADDY_CALL_LOG"; }
is_appliance() {
    record_call appliance
    [ "$CADDY_APPLIANCE" = true ]
}
appliance_site_names() {
    record_call sites
    printf '%s' "$CADDY_SITE_HOSTS"
}
hostname() {
    record_call hostname
    [ "${1:-}" = -I ] || return 64
    printf '%s\n' "$CADDY_HOSTNAME_ADDRESSES"
}
container_bridge_addrs() {
    record_call bridges
    printf '%s\n' "$CADDY_BRIDGE_ADDRESSES"
}
is_public_ip() {
    local address=$1 public
    record_call "public:$address"
    for public in $CADDY_PUBLIC_ADDRESSES; do
        [ "$address" != "$public" ] || return 0
    done
    return 1
}
appliance_tls_dir() {
    record_call tls-dir
    printf '%s' "$CADDY_TLS_DIR"
}
appliance_mint_cert() {
    record_call mint
    return "$CADDY_MINT_RC"
}

# shellcheck source=/dev/null
source "$root/lib/pithead/35-caddyfile-and-auth-helpers.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/35a-caddy-go-render.sh"
if [ "$CADDY_CAT_RC" -ne 0 ]; then
    cat() { return "$CADDY_CAT_RC"; }
fi
generate_caddyfile "$target" "$CADDY_MINT_CERT"
