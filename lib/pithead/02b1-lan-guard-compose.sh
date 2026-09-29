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
    if lan_guard_scoped_up "$@"; then up_args+=("${LAN_GUARD_STOPPED_SERVICES[@]}"); fi
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
    local kp check_rc=0 ports=()
    for kp in $(lan_guard_published); do ports+=("${kp#*:}"); done
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
    if PITHEAD_LOCK_FILE="$(mutation_lock_path)" docker compose up "$@"; then
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
