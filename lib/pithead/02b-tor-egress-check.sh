# --- Tor-only egress status for the dashboard (#2599) --------------------------------------------
# The dashboard runs in a container and cannot read host netfilter, so on its own it could only
# repeat network.tor_egress_firewall: "blocked by the egress firewall" over an open egress, the
# green-dashboard state production ran in for 17 days (#2460). A timer on the host runs the same
# tor_egress_enforced() doctor uses every two minutes and writes the verdict into the control
# results dir, which the dashboard mounts read-only whether or not dashboard control is on.
#
# Read-only by design: the check never touches the rules. A flush stays visible until `up`
# restores it (an unchanged `apply` does not reinstall them), which is what the alert is for.
# Restoring at boot is pithead-egress.service's job (02a); this pair is separate because that
# unit is CLI-free and stays active after one run.
EGRESS_CHECK_SERVICE="pithead-egress-check.service"
EGRESS_CHECK_TIMER="pithead-egress.timer"

# Write {rc, verdict, checked_at} atomically; the rc is tor_egress_enforced's, 0 to 5.
egress_status() {
    local rc=0 dir tmp verdict
    tor_egress_enforced || rc=$?
    case "$rc" in
    0) verdict=enforced ;;
    1) verdict=absent ;;
    2) verdict=no-tool ;;
    4) verdict=jump-missing ;;
    5) verdict=shadowed ;;
    *) verdict=unreadable ;;
    esac
    dir=$(env_get CONTROL_DIR 2>/dev/null) || true
    dir="${dir:-$PWD/data/control}/results"
    mkdir -p "$dir"
    tmp=$(mktemp "$dir/.egress-status.XXXXXX")
    printf '{"rc":%d,"verdict":"%s","checked_at":%d}\n' "$rc" "$verdict" "$(date +%s)" >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dir/egress-status.json"
    printf '%s\n' "$verdict"
}

render_egress_check_service() { # <install dir> <engine>
    cat <<EOF
[Unit]
Description=pithead Tor-only egress firewall check for the dashboard

[Service]
Type=oneshot
User=root
WorkingDirectory=$1
# Pinned for the same reason as pithead-control.service: a unit does not read
# /etc/environment, and an unpinned probe on the appliance takes podman-docker's shim for Docker.
Environment=PITHEAD_ENGINE=$2
ExecStart=$1/pithead egress-status
EOF
}

# Unit= names the check: without it the timer would start pithead-egress.service, the boot unit.
render_egress_check_timer() {
    cat <<EOF
[Unit]
Description=Check the pithead Tor-only egress firewall every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=$EGRESS_CHECK_SERVICE

[Install]
WantedBy=timers.target
EOF
}

# Install and start the pair (or remove it when the firewall is opted out). Box-global units that
# name a checkout, so the control runner's ownership rule applies: a pair naming another install
# that still exists is left alone unless `steal` (upgrade) or PITHEAD_STEAL_CONTROL_UNITS=1.
provision_egress_check_units() { # [steal]
    [ "$OS_TYPE" == "Linux" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local enabled unit_dir owner svc timer
    enabled=$(env_get TOR_EGRESS_FIREWALL 2>/dev/null) || true
    if [ "$(normalize_bool "${enabled:-true}")" != "true" ]; then
        remove_egress_check_units
        return 0
    fi
    unit_dir=$(control_unit_dir)
    if [ -e "$unit_dir/$EGRESS_CHECK_SERVICE" ] && [ "${1:-}" != "steal" ] &&
        [ "${PITHEAD_STEAL_CONTROL_UNITS:-0}" != "1" ]; then
        owner=$(control_units_owner_dir "$EGRESS_CHECK_SERVICE" egress-status)
        if [ -z "$owner" ] || { [ "$owner" != "$(pwd -P)" ] && [ -d "$owner" ]; }; then
            warn "egress-check:foreign-units — not installing $EGRESS_CHECK_SERVICE: it belongs to ${owner:-an ExecStart this tool did not write}. Re-run with PITHEAD_STEAL_CONTROL_UNITS=1 to take it over; until then this install's dashboard shows the egress firewall as unverified."
            return 0
        fi
    fi
    svc=$(render_egress_check_service "$PWD" "$(container_engine)")
    timer=$(render_egress_check_timer)
    if [ "$(cat "$unit_dir/$EGRESS_CHECK_SERVICE" 2>/dev/null)" = "$svc" ] &&
        [ "$(cat "$unit_dir/$EGRESS_CHECK_TIMER" 2>/dev/null)" = "$timer" ] &&
        systemctl is-active "$EGRESS_CHECK_TIMER" >/dev/null 2>&1; then
        return 0
    fi
    local -a enable_args=(enable --now)
    case "$unit_dir" in /run/*) enable_args=(enable --runtime --now) ;; esac
    if printf '%s\n' "$svc" | sudo tee "$unit_dir/$EGRESS_CHECK_SERVICE" >/dev/null &&
        printf '%s\n' "$timer" | sudo tee "$unit_dir/$EGRESS_CHECK_TIMER" >/dev/null &&
        sudo systemctl daemon-reload && sudo systemctl "${enable_args[@]}" "$EGRESS_CHECK_TIMER" >/dev/null 2>&1; then
        log "The dashboard will check the Tor-only egress firewall every 2 minutes ($EGRESS_CHECK_TIMER)."
    else
        warn "egress-check:unit-install-failed — could not install $EGRESS_CHECK_TIMER; the dashboard shows the egress firewall as unverified."
    fi
}

# Only this checkout's pair, as with the control runner's removal.
remove_egress_check_units() {
    local unit_dir
    unit_dir=$(control_unit_dir)
    [ -e "$unit_dir/$EGRESS_CHECK_SERVICE" ] || [ -e "$unit_dir/$EGRESS_CHECK_TIMER" ] || return 0
    if [ -e "$unit_dir/$EGRESS_CHECK_SERVICE" ] &&
        [ "$(control_units_owner_dir "$EGRESS_CHECK_SERVICE" egress-status)" != "$(pwd -P)" ]; then
        return 0
    fi
    sudo systemctl disable --now "$EGRESS_CHECK_TIMER" >/dev/null 2>&1 || true
    sudo rm -f "$unit_dir/$EGRESS_CHECK_TIMER" "$unit_dir/$EGRESS_CHECK_SERVICE" || true
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
}
