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

# Print the same connection details to the journal and every physical console.
wizard_announce_setup() {
    local host_addresses=$1 token=$2 cert_fp=$3 arg dev
    local mdns_name scheme
    mdns_name="$(hostname).local"
    scheme="http"
    [ -n "$cert_fp" ] && scheme="https"
    log "Setup wizard is up. From a browser on this network, open:"
    log "    $scheme://$mdns_name"
    for arg in $host_addresses; do log "    $scheme://$(wizard_url_host "$arg")"; done
    log "One-time token: $token"
    # Announce on every physical console, not just stdout. /dev/console is whichever the
    # kernel cmdline named LAST, so an operator watching the other one (a monitor when the
    # box also has a serial line, or vice versa) would otherwise never see the token.
    # The mDNS name FIRST: it is what the documentation tells operators to use, it survives a
    # DHCP lease change, and it is the only address that still works once the monitor is gone.
    # The IP follows as the fallback for networks where mDNS is filtered.
    for dev in /dev/tty1 /dev/ttyS0; do
        [ -w "$dev" ] || continue
        {
            echo ""
            echo "  Pithead setup wizard is ready. From a browser on this network, open:"
            echo "      $scheme://$mdns_name"
            [ -z "$host_addresses" ] ||
                echo "      $scheme://$(wizard_url_host "${host_addresses%% *}")   (if the name above does not resolve)"
            echo ""
            echo "  One-time token: $token"
            echo "  (case does not matter, and the pit- prefix is optional)"
            if [ -n "$cert_fp" ]; then
                echo ""
                echo "  Your browser will warn that the certificate is not trusted. That is expected:"
                echo "  this machine signed its own. Check it matches before continuing --"
                echo "  SHA-256: $cert_fp"
            fi
            echo ""
        } >"$dev" 2>/dev/null || true
    done
}
