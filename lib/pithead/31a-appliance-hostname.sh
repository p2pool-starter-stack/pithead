# A bare dashboard.host label names the appliance. Existing DNS/IP pins remain certificate
# addresses; Docker hosts never change identity. config.json on /data is the persistent source:
# boot's render restores the kernel hostname after each reboot or A/B update, without /etc writes.
appliance_hostname_label() {
    is_appliance || return 0
    local name="${DASHBOARD_HOST:-}"
    [[ "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 0
    [ "$name" != auto ] || return 0
    printf '%s' "${name,,}"
}

# The interfaces Avahi may publish this machine's name on: its real NICs, comma-separated, empty
# when none carries a global address yet. Avahi publishes on EVERY interface that has one, and each
# container bridge the engine creates has one too, so <name>.local resolved to a bridge gateway
# rather than the LAN address the certificate and the dashboard header carry. The answer even moved
# between boots, following whichever bridge won the race.
#
# A positive list, not a deny-list, because of WHEN this runs: the boot render reconciles identity
# BEFORE `up` creates either bridge, so a deny-list built here would come out empty and Avahi would
# pick the bridges up the moment they appeared. A bridge added afterwards is excluded by construction.
#
# Engine-free for the same reason appliance_site_names() is: `ip link ... type bridge` names every
# container bridge without asking podman, so an engine that is slow or down at the wrong moment
# can never change what this machine announces itself as.
appliance_mdns_interfaces() {
    local bridges
    bridges=" $(ip -o link show type bridge 2>/dev/null | sed 's/^[0-9]*: *//; s/[:@].*//' | tr '\n' ' ') "
    ip -4 -o addr show scope global 2>/dev/null |
        awk -v b="$bridges" '!index(b, " " $2 " ") && !seen[$2]++ { printf "%s%s", (n++ ? "," : ""), $2 }'
}

# Write that list into Avahi's config. Exits 0 ONLY when the file changed, so the caller refreshes
# the daemon exactly when there is something new to announce.
#
# Nothing to write — no addressed NIC yet, or no config file at all off the appliance — leaves the
# daemon alone: publishing on every interface is wrong, publishing on none is worse. The read-back
# is not decoration; a config whose commented `allow-interfaces=` line ever stopped shipping would
# otherwise leave the sed a silent no-op with this function claiming a change it never made
# (tests/os/verify-image.sh asserts the line).
appliance_reconcile_mdns_interfaces() {
    is_appliance || return 1
    local conf="${PITHEAD_AVAHI_CONF:-/etc/avahi/avahi-daemon.conf}" ifaces
    ifaces=$(appliance_mdns_interfaces)
    [ -n "$ifaces" ] && [ -f "$conf" ] || return 1
    ! grep -qx "allow-interfaces=$ifaces" "$conf" || return 1
    ensure_etc_overlay &&
        sudo_sed "s/^#\{0,1\}allow-interfaces=.*/allow-interfaces=$ifaces/" "$conf" &&
        grep -qx "allow-interfaces=$ifaces" "$conf" || {
        warn "Could not restrict the local network name to this machine's LAN interfaces."
        return 1
    }
}

# Only call after validation/confirmation, in setup, boot render or a successful apply.
# Resolution and preview use the pure label helper above, never this privileged step.
reconcile_appliance_hostname() {
    [ "${PITHEAD_DRY_RUN:-0}" != 1 ] || return 0
    local name refresh=0
    # Independent of the label: an appliance left on the default "auto" name has no label to
    # reconcile and still published itself on every container bridge.
    if appliance_reconcile_mdns_interfaces; then refresh=1; fi
    name=$(appliance_hostname_label)
    if [ -n "$name" ]; then
        if [ "$(hostname)" != "$name" ]; then
            sudo hostname "$name" || error "Could not set this appliance's hostname. Retry apply."
        fi
        # Avahi may already be running under the old name. try-restart leaves a not-yet-started
        # boot unit alone, and also retries a previous failed announcement on an unchanged apply.
        refresh=1
    fi
    [ "$refresh" -eq 1 ] || return 0
    sudo systemctl try-restart avahi-daemon.service || error "Could not refresh this machine's local network name. Retry apply."
}
