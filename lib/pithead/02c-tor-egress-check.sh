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

EGRESS_AUDIT_STATE_FILE=".egress-audit-prev"

egress_status() {
    local rc=0 dir tmp verdict arc=0 audit_state=absent audit_json='' audit_cj wd now
    local state_file state_tmp prev_wd='' first_seen='' prev_al='' prev_ch='' al='' ch='' al_v
    local delta=0 d_al=0 d_ch=0 watchdog=not-observed
    tor_egress_enforced || rc=$?
    case "$rc" in
    0) verdict=enforced ;;
    1) verdict=absent ;;
    2) verdict=no-tool ;;
    4) verdict=jump-missing ;;
    5) verdict=shadowed ;;
    *) verdict=unreadable ;;
    esac
    audit_cj=$(host_egress_audit_counters) || arc=$?
    case "$arc" in
    0) audit_state=present ;;
    2) audit_state=no-tool ;;
    3) audit_state=unreadable ;;
    *) audit_state=absent ;;
    esac
    dir=$(env_get CONTROL_DIR 2>/dev/null) || true
    dir="${dir:-$PWD/data/control}/results"
    mkdir -p "$dir"
    state_file="$dir/$EGRESS_AUDIT_STATE_FILE"
    now=$(date +%s)
    if [ "$audit_state" = present ]; then
        { read -r wd al ch < <(printf '%s' "$audit_cj" | jq -r '[.outside, .allowlisted, .choice] | @tsv'); } 2>/dev/null || wd=
        for al_v in "$wd" "$al" "$ch"; do
            case "$al_v" in '' | *[!0-9]*) audit_state=unreadable ;; esac
        done
    fi
    if [ "$audit_state" = present ]; then
        { read -r prev_wd first_seen prev_al prev_ch <"$state_file"; } 2>/dev/null || true
        case "$prev_wd" in '' | *[!0-9]*) prev_wd=$wd ;; esac
        case "$prev_al" in '' | *[!0-9]*) prev_al=$al ;; esac
        case "$prev_ch" in '' | *[!0-9]*) prev_ch=$ch ;; esac
        case "$first_seen" in *[!0-9]*) first_seen= ;; esac
        [ -z "$first_seen" ] || first_seen=$((10#$first_seen))
        delta=$((10#$wd - 10#$prev_wd))
        d_al=$((10#$al - 10#$prev_al))
        d_ch=$((10#$ch - 10#$prev_ch))
        if [ "$delta" -gt 0 ]; then
            watchdog=leaking
            first_seen=${first_seen:-$now}
        else
            first_seen=
            if [ "$d_ch" -gt 0 ]; then
                watchdog=operator-choice
            elif [ "$d_al" -gt 0 ]; then
                watchdog=allowlisted
            else
                watchdog=clean
            fi
        fi
        audit_json=$(printf '%s' "$audit_cj" | jq -c --arg w "$watchdog" --argjson d "$delta" \
            --argjson f "${first_seen:-null}" \
            '. + {verdict: "present", watchdog: $w, watchdog_delta: $d, first_seen: $f}') || audit_json=
        [ -n "$audit_json" ] || {
            audit_state=unreadable
            watchdog=not-observed
        }
    fi
    [ -n "$audit_json" ] ||
        audit_json="{\"verdict\":\"$audit_state\",\"counters\":[],\"would_drop\":null,\"watchdog\":\"not-observed\"}"
    tmp=$(mktemp "$dir/.egress-status.XXXXXX")
    printf '{"rc":%d,"verdict":"%s","checked_at":%d,"host_audit":%s}\n' \
        "$rc" "$verdict" "$now" "$audit_json" >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dir/egress-status.json"
    printf '%s\n' "$verdict"
    if [ "$watchdog" = not-observed ]; then
        printf 'host-audit: %s watchdog=not-observed\n' "$audit_state"
        return 0
    fi
    state_tmp=$(mktemp "$dir/.egress-audit-prev.XXXXXX")
    printf '%s %s %s %s\n' "$wd" "${first_seen:--}" "$al" "$ch" >"$state_tmp"
    chmod 0644 "$state_tmp"
    mv -f "$state_tmp" "$state_file"
    printf 'host-audit: present (outside the allowlist %s packets) watchdog=%s (rise %d since the last check)\n' \
        "$wd" "$watchdog" "$delta"
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
        # Only a removal that finished may say so; a failed step has already warned what is left.
        if remove_egress_check_units; then
            [ "${EGRESS_CHECK_REMOVED:-0}" = 1 ] && log "Removed $EGRESS_CHECK_TIMER: network.tor_egress_firewall is off."
        else
            warn "egress-check:removal-incomplete — $EGRESS_CHECK_TIMER is off in config but not fully removed; see the step above."
        fi
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

# Only this checkout's pair, as with the control runner's removal. Every step is attempted even when
# an earlier one fails, each failure is named, and the return is non-zero if any step failed, so a
# caller cannot report the pair gone while a unit file or a live timer remains.
# EGRESS_CHECK_REMOVED=1 on return means this call removed a pair (0: there was none of ours).
remove_egress_check_units() {
    local unit_dir rc=0
    EGRESS_CHECK_REMOVED=0
    unit_dir=$(control_unit_dir)
    [ -e "$unit_dir/$EGRESS_CHECK_SERVICE" ] || [ -e "$unit_dir/$EGRESS_CHECK_TIMER" ] || return 0
    if [ -e "$unit_dir/$EGRESS_CHECK_SERVICE" ] &&
        [ "$(control_units_owner_dir "$EGRESS_CHECK_SERVICE" egress-status)" != "$(pwd -P)" ]; then
        return 0
    fi
    if [ -e "$unit_dir/$EGRESS_CHECK_TIMER" ] &&
        ! sudo systemctl disable --now "$EGRESS_CHECK_TIMER" >/dev/null 2>&1; then
        warn "egress-check:disable-failed — could not stop and disable $EGRESS_CHECK_TIMER; it may still run. Run: sudo systemctl disable --now $EGRESS_CHECK_TIMER"
        rc=1
    fi
    if ! sudo rm -f "$unit_dir/$EGRESS_CHECK_TIMER" "$unit_dir/$EGRESS_CHECK_SERVICE" ||
        [ -e "$unit_dir/$EGRESS_CHECK_TIMER" ] || [ -e "$unit_dir/$EGRESS_CHECK_SERVICE" ]; then
        warn "egress-check:delete-failed — could not delete $unit_dir/$EGRESS_CHECK_TIMER and $unit_dir/$EGRESS_CHECK_SERVICE. Delete them with sudo rm -f, then run: sudo systemctl daemon-reload"
        rc=1
    fi
    if ! sudo systemctl daemon-reload >/dev/null 2>&1; then
        warn "egress-check:reload-failed — systemd did not reload after the removal. Run: sudo systemctl daemon-reload"
        rc=1
    fi
    [ "$rc" -ne 0 ] || EGRESS_CHECK_REMOVED=1
    return "$rc"
}
