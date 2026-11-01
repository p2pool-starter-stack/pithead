#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
target=$2

# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/26-appliance-tls-provisioning.sh"
eval "$(declare -f is_public_ip | sed '1s/is_public_ip/_site_names_is_public_ip/')"
eval "$(declare -f appliance_base_name | sed '1s/appliance_base_name/_site_names_base_name/')"
eval "$(declare -f appliance_site_names | sed '1s/appliance_site_names/_site_names_production/')"

# shellcheck source=/dev/null
source <(sed '$d' "$root/tests/go-parity/caddy_reference.sh") "$root" "$target"

eval "$(declare -f _site_names_is_public_ip | sed '1s/_site_names_is_public_ip/is_public_ip/')"
eval "$(declare -f _site_names_base_name | sed '1s/_site_names_base_name/appliance_base_name/')"
eval "$(declare -f _site_names_production | sed '1s/_site_names_production/appliance_site_names/')"
hostname() {
    if [ "$#" -eq 0 ]; then
        record_call hostname
        printf '%s' "${CADDY_HOSTNAME:-}"
        return 0
    fi
    [ "$#" -eq 1 ] && [ "$1" = -I ] || return 64
    record_call hostname:-I
    printf '%s' "$CADDY_HOSTNAME_ADDRESSES"
}
appliance_hostname_label() {
    is_appliance || return 0
    printf '%s' "${CADDY_HOSTNAME_LABEL:-}"
}

# shellcheck source=/dev/null
source "$root/lib/pithead/26a-go-site-names.sh"
generate_caddyfile "$target" "$CADDY_MINT_CERT"
