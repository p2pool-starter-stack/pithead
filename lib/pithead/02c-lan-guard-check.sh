# Guard old container publishes and newly requested binds before apply commits a staged .env.
lan_guard_transition_ports() { # <newenv>
    local kp p ports=()
    for p in $(lan_guard_watched_ports); do ports+=("$p"); done
    for kp in $LAN_GUARD_BINDS; do
        p=${kp#*:}
        case "$(env_get_file "$1" "${kp%%:*}")" in
        '' | 127.0.0.1) ;;
        *) [[ " ${ports[*]} " == *" $p "* ]] || ports+=("$p") ;;
        esac
    done
    printf '%s\n' "${ports[@]}"
}

lan_guard_arm_transition() { # <newenv>: before apply commits it
    local p rc=0 containers networks ports=()
    for p in $(lan_guard_transition_ports "$1"); do ports+=("$p"); done
    [ "${#ports[@]}" -gt 0 ] || return 0
    apply_lan_guard "${ports[@]}"
    lan_guard_enforced "${ports[@]}" || rc=$?
    if [ "$rc" = 4 ]; then
        # Only the first network creation can supply a missing FORWARD jump. A stopped
        # container or an existing network could still start with the port exposed.
        if containers=$(docker ps -a --filter label=com.docker.compose.project=pithead --format '{{.Names}}' 2>/dev/null) &&
            networks=$(docker network ls --format '{{.Name}}' 2>/dev/null); then
            [ -n "$containers" ] || grep -qxF mining_net <<<"$networks" || rc=0
        fi
    fi
    if [ "$rc" -ne 0 ] || ! lan_guard_marker_current; then
        if [ "$rc" -ne 0 ]; then
            warn "lan-guard:transition-not-armed — $(lan_guard_reason "$rc")."
        else
            warn "lan-guard:transition-not-armed — the boot marker does not match this boot."
        fi
        lan_guard_unmark || warn "lan-guard:marker-kept — could not delete $LAN_GUARD_MARKER."
        lan_guard_check_now || true
        return 1
    fi
}

# The rule is installed and this boot's marker is current for every watched port.
lan_guard_holds() {
    local p ports=()
    for p in $(lan_guard_watched_ports); do ports+=("$p"); done
    [ "${#ports[@]}" -eq 0 ] || { lan_guard_enforced "${ports[@]}" && lan_guard_marker_current; }
}

# Take the mutation lock only if free. A long apply/upgrade must not delay an emergency stop, but
# it rewrites the rule and marker itself: a tick that lands mid-rewrite must not stop the nodes
# that up is about to start (they would refuse with 78), so a lock-busy tick rechecks briefly first.
lan_guard_check() {
    local rc
    if command -v flock >/dev/null 2>&1 && exec 8>>"$(mutation_lock_path)" 2>/dev/null && flock -n 8; then
        lan_guard_check_now
        rc=$?
        exec 8>&-
        return "$rc"
    fi
    exec 8>&-
    for _ in 1 2 3; do
        lan_guard_holds && return 0
        sleep "${LAN_GUARD_SETTLE:-2}"
    done
    lan_guard_check_now
}

# Invalidate the marker first so a concurrent explicit start fails its entrypoint gate.
lan_guard_check_now() {
    local p c name seen=" " names published rc=0
    local ports=() fixed_ports=()
    for p in $(lan_guard_watched_ports); do ports+=("$p"); done
    [ "${#ports[@]}" -gt 0 ] || return 0
    if lan_guard_enforced "${ports[@]}" && lan_guard_marker_current; then return 0; fi
    lan_guard_unmark || {
        warn "lan-guard:marker-kept — could not delete $LAN_GUARD_MARKER."
        rc=1
    }
    for p in "${ports[@]}"; do
        c=$(lan_guard_container "$p")
        names=$(docker ps --filter label=com.docker.compose.project=pithead --filter "label=com.docker.compose.service=$c" --format '{{.Names}}') || {
            names="$c"
            rc=1
        }
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            [[ "$seen" == *" $name "* ]] && continue
            if published=$(docker port "$name" "$p/tcp" 2>/dev/null); then
                [ -n "$published" ] || continue
                grep -qv '^127\.0\.0\.1:' <<<"$published" || continue
            fi
            seen+="$name "
            # A concurrent up may have restored the rule and marker while the lock was busy.
            if lan_guard_enforced "${ports[@]}" && lan_guard_marker_current; then return 0; fi
            docker stop "$name" >/dev/null || rc=1
        done <<<"$names"
    done
    for c in monerod tari; do
        names=$(docker ps --filter label=com.docker.compose.project=pithead --filter "label=com.docker.compose.service=$c" --format '{{.Names}}') || rc=1
        for name in $seen; do grep -qxF "$name" <<<"$names" && rc=1; done
    done
    if [ "$rc" -ne 0 ]; then
        # Restore the rule for NEW connections, but an already-established session survives it.
        # A concurrent up may change the port set: replacing its rule with this check's old
        # snapshot could expose its new port. Guard every fixed node port in this emergency.
        for p in $LAN_GUARD_BINDS; do fixed_ports+=("${p#*:}"); done
        apply_lan_guard "${fixed_ports[@]}" || true
        lan_guard_unmark || warn "lan-guard:marker-kept — could not delete $LAN_GUARD_MARKER."
    fi
    warn "lan-guard:rule-or-marker-lost — LAN-publishing nodes were stopped or a stop could not be verified. Run './pithead up' after fixing the firewall."
    [ "$rc" = 0 ] || return "$rc"
    return 1
}
