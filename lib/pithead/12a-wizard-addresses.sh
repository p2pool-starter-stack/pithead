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

wizard_issue_file() {
    printf '/run/issue.d/pithead-setup.issue'
}

wizard_clear_announcement() {
    rm -f "$(wizard_issue_file)" || return 1
    agetty --reload >/dev/null 2>&1 || true
}

wizard_setup_banner() {
    local host_addresses=$1 token=$2 cert_fp=$3 mdns_name scheme=http
    mdns_name="$(hostname).local"
    [ -z "$cert_fp" ] || scheme=https
    printf '\n  Pithead setup wizard is ready. From a browser on this network, open:\n'
    printf '      %s://%s\n' "$scheme" "$mdns_name"
    [ -z "$host_addresses" ] ||
        printf '      %s://%s   (if the name above does not resolve)\n' "$scheme" "$(wizard_url_host "${host_addresses%% *}")"
    printf '\n  One-time token: %s\n' "$token"
    printf '  (case does not matter, and the pit- prefix is optional)\n'
    if [ -n "$cert_fp" ]; then
        printf '\n  Your browser will warn that the certificate is not trusted. That is expected:\n'
        printf '  this machine signed its own. Check it matches before continuing --\n'
        printf '  SHA-256: %s\n' "$cert_fp"
    fi
    printf '\n'
}

wizard_announce_setup() {
    local host_addresses=$1 token=$2 cert_fp=$3 arg dev issue pending
    local mdns_name scheme=http
    mdns_name="$(hostname).local"
    [ -z "$cert_fp" ] || scheme=https
    issue=$(wizard_issue_file)
    mkdir -p "$(dirname "$issue")" || return 1
    pending=$(mktemp "${issue}.XXXXXX") || return 1
    if ! wizard_setup_banner "$host_addresses" "$token" "$cert_fp" >"$pending" ||
        ! mv -f "$pending" "$issue"; then
        rm -f "$pending"
        return 1
    fi
    agetty --reload >/dev/null 2>&1 || true
    log "Setup wizard is up. From a browser on this network, open:"
    log "    $scheme://$mdns_name"
    for arg in $host_addresses; do log "    $scheme://$(wizard_url_host "$arg")"; done
    log "One-time token: $token"
    for dev in /dev/tty1 /dev/ttyS0; do
        [ -w "$dev" ] || continue
        cat "$issue" >"$dev" 2>/dev/null || true
    done
}
