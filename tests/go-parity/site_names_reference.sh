#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
export PITHEAD_IMPL="${SITE_NAMES_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/26-appliance-tls-provisioning.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/26a-go-site-names.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/31a-appliance-hostname.sh"
if [ "${SITE_NAMES_WITHOUT_GO_HOOK:-0}" = 1 ]; then
    unset -f _appliance_site_names_go _appliance_cert_alt_string_go
fi

is_appliance() {
    printf 'appliance\n' >>"$SITE_NAMES_CALL_LOG"
    [ "${SITE_NAMES_APPLIANCE:-true}" = true ]
}
hostname() {
    if [ "$#" -eq 0 ]; then
        printf 'hostname\n' >>"$SITE_NAMES_CALL_LOG"
        [ "${SITE_NAMES_HOSTNAME_EMPTY:-0}" = 1 ] || printf '%s' "${SITE_NAMES_HOSTNAME:-rig}"
        return "${SITE_NAMES_HOSTNAME_RC:-0}"
    fi
    if [ "$#" -eq 1 ] && [ "$1" = -I ]; then
        printf 'hostname:-I\n' >>"$SITE_NAMES_CALL_LOG"
        printf '%s' "${SITE_NAMES_ADDRESSES:-}"
        return "${SITE_NAMES_ADDRESSES_RC:-0}"
    fi
    return 64
}
container_bridge_addrs() {
    printf 'bridges\n' >>"$SITE_NAMES_CALL_LOG"
    printf '%s' "${SITE_NAMES_BRIDGES:-}"
    return "${SITE_NAMES_BRIDGES_RC:-0}"
}

case "${SITE_NAMES_IFS:-default}" in
colon) IFS=: ;;
empty) IFS= ;;
esac

if [ "${SITE_NAMES_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\n" "$?" >>"$SITE_NAMES_TRAP_LOG"' ERR
fi

case "$operation" in
site) appliance_site_names ;;
san) appliance_cert_alt_string ;;
*) exit 64 ;;
esac
