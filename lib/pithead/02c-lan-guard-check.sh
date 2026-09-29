# Take the mutation lock only if free. A long apply/upgrade must not delay an emergency stop.
lan_guard_check() {
    local rc
    if command -v flock >/dev/null 2>&1 && exec 8>>"$(mutation_lock_path)" 2>/dev/null && flock -n 8; then
        lan_guard_check_now
        rc=$?
        exec 8>&-
        return "$rc"
    fi
    exec 8>&-
    lan_guard_check_now
}

# Invalidate the marker first so a concurrent explicit start fails its entrypoint gate.
lan_guard_check_now() {
    local p c name seen=" " names rc=0
    local ports=() fixed_ports=()
    for p in $(lan_guard_watched_ports); do ports+=("$p"); done
    [ "${#ports[@]}" -gt 0 ] || return 0
    if lan_guard_enforced "${ports[@]}" && cmp -s "$BOOT_ID_FILE" "$LAN_GUARD_MARKER"; then return 0; fi
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
            seen+="$name "
            # A concurrent up may have restored the rule and marker while the lock was busy.
            if lan_guard_enforced "${ports[@]}" && cmp -s "$BOOT_ID_FILE" "$LAN_GUARD_MARKER"; then return 0; fi
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
