# shellcheck shell=bash
# The setup container cannot discover the host LAN address from its accepted socket.
# Read addressed host interfaces without consulting the engine; a failed inventory supplies
# no addresses, so the wizard uses the documented mDNS name rather than bridge plumbing.
wizard_host_addresses() {
    local bridges addresses
    bridges=$(ip -j link show type bridge 2>/dev/null) || return 1
    addresses=$(ip -j addr show scope global 2>/dev/null) || return 1
    jq -r --argjson bridges "$bridges" '
        [$bridges[].ifname] as $excluded |
        [.[] | select(.ifname as $name | $excluded | index($name) | not) |
            .addr_info[] | select(.scope == "global") | .local] | join(" ")
    ' <<<"$addresses"
}

wizard_url_host() {
    case "$1" in
    *:*) printf '[%s]' "$1" ;;
    *) printf '%s' "$1" ;;
    esac
}
