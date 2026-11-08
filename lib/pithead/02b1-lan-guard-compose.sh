# Refresh the rule before stopping stale listeners; both safety stop sets participate in scoped up.
lan_guard_prepare_up() {
    # Refresh configured and stale published ports before stopping or starting any node.
    apply_lan_guard || {
        lan_guard_check_now || true
        return 1
    }
    lan_guard_stop_rebound_nodes || {
        lan_guard_check_now || true
        warn "A node with an old published bind could not be stopped; the LAN rule was rechecked."
        return 1
    }
    lan_guard_check_keep_running || return 1
}

# A staged rule has no start marker. Stop any already-running LAN node before even the first
# loopback-bound compose pass; a failed engine query cannot be mistaken for an empty set.
lan_guard_stop_published() {
    local ids kp c id seen=" "
    for kp in $(lan_guard_published); do
        c=$(lan_guard_container "${kp#*:}")
        [[ "$seen" == *" $c "* ]] && continue
        seen+="$c "
        ids=$(docker ps -q --filter label=com.docker.compose.project=pithead --filter "label=com.docker.compose.service=$c" 2>/dev/null) ||
            {
                warn "lan-guard:engine-unreadable — cannot check running LAN nodes."
                return 1
            }
        for id in $ids; do
            if ! docker stop "$id"; then
                warn "lan-guard:stop-failed — could not stop $c; its ports may still be exposed."
                return 1
            fi
            [[ " ${LAN_GUARD_STOPPED_SERVICES[*]} " == *" $c "* ]] || LAN_GUARD_STOPPED_SERVICES+=("$c")
        done
    done
}

# The e2e keep-running promise cannot survive a stopped LAN node. Refuse rather than silently
# recreate one that the harness said must continue uninterrupted.
lan_guard_check_keep_running() {
    local stopped
    [ -n "${PITHEAD_KEEP_RUNNING:-}" ] || return 0
    for stopped in "${LAN_GUARD_STOPPED_SERVICES[@]}" "${LAN_GUARD_REBOUND_SERVICES[@]}"; do
        case " $PITHEAD_KEEP_RUNNING " in
        *" $stopped "*)
            warn "Cannot keep $stopped running: its LAN rule is unavailable; it was stopped for safety."
            return 1
            ;;
        esac
    done
}

# Compose names a scope only when a service is positional. The other bare values are option values.
lan_guard_scoped_up() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --pull | --scale | --timeout | --wait-timeout | --exit-code-from | --attach | --no-attach | -t)
            shift
            [ "$#" -gt 0 ] && shift
            ;;
        -*) shift ;;
        *) return 0 ;;
        esac
    done
    return 1
}

# A failed first up has not completed its requested work, but may have stopped a prior node.
# Retry just those nodes with the loopback binds still exported; report the original failure.
lan_guard_restore_stopped() {
    [ "${#LAN_GUARD_STOPPED_SERVICES[@]}" -gt 0 ] || return 0
    PITHEAD_LOCK_FILE="$(mutation_lock_path)" docker compose up -d "${LAN_GUARD_STOPPED_SERVICES[@]}" ||
        warn "lan-guard:recreate-failed — could not restore the loopback-bound nodes after compose failed."
}

# Recreate stopped LAN nodes even when the caller names only another service.
lan_guard_compose_up() { # <compose up arguments>
    local rc=0 up_args=("$@")
    if lan_guard_scoped_up "$@"; then up_args+=("${LAN_GUARD_STOPPED_SERVICES[@]}" "${LAN_GUARD_REBOUND_SERVICES[@]}"); fi
    # The dashboard bind-mounts this exact lock inode across versioned installs.
    PITHEAD_LOCK_FILE="$(mutation_lock_path)" docker compose up "${up_args[@]}" || rc=$?
    if [ "$rc" = 0 ]; then
        finish_lan_guard_after_up "${up_args[@]}" || rc=1
    else
        lan_guard_restore_stopped
    fi
    return "$rc"
}

# Docker creates the first FORWARD jump during compose up. The first pass stays on loopback; only
# a successful readback gets a marker and a second pass with the configured LAN binds.
finish_lan_guard_after_up() { # <original compose up arguments>
    [ "${LAN_GUARD_STAGED:-0}" = 1 ] || return 0
    local kp p check_rc=0 ports=() up_args=("$@") i
    for p in $(lan_guard_watched_ports); do ports+=("$p"); done
    lan_guard_enforced "${ports[@]}" || check_rc=$?
    if [ "$check_rc" != 0 ]; then
        warn "lan-guard:not-installed — LAN-only rule stayed inactive after compose up ($(lan_guard_reason "$check_rc")); node ports stay on 127.0.0.1."
        return 0
    fi
    lan_guard_mark 2>/dev/null || {
        warn "lan-guard:marker-kept — could not write $LAN_GUARD_MARKER; node ports stay on 127.0.0.1."
        return 0
    }
    for kp in $(lan_guard_published); do export "${kp%%:*}=$(env_get "${kp%%:*}")"; done
    # Images were already pulled by the successful loopback pass; do not fetch them again.
    for ((i = 0; i + 1 < ${#up_args[@]}; i++)); do
        [ "${up_args[$i]}" = --pull ] && up_args[$((i + 1))]=never
    done
    if PITHEAD_LOCK_FILE="$(mutation_lock_path)" docker compose up "${up_args[@]}"; then
        log "LAN-only sources enforced on port(s) ${ports[*]} after Docker created its network."
        return 0
    fi
    lan_guard_unmark || {
        warn "lan-guard:marker-kept — could not delete $LAN_GUARD_MARKER."
        return 1
    }
    lan_guard_stop_published || return 1
    for kp in $(lan_guard_published); do export "${kp%%:*}=127.0.0.1"; done
    PITHEAD_LOCK_FILE="$(mutation_lock_path)" docker compose up "$@" || warn "lan-guard:recreate-failed — could not restore the loopback-bound nodes."
    return 1
}
