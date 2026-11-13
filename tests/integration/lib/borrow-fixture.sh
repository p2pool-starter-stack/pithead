# shellcheck shell=bash

MINER_WORKER_NAME=pithead-e2e

# Reapply the temporary pool fixture without minting another restore anchor. RigForge correctly
# regenerates xmrig's rendered config after bootstrap/control applies; e2e.sh's original backup
# remains the one and only restore source (#1994).
repoint_miner() {
    on_miner "
        jq --arg b '$BENCH_HOST' '
            (if any(.pools[]?; .url | ascii_downcase | contains(\$b)) then .
             else .pools = ([ (.pools[0]) + {url: (\$b + \":3333\"), tls: false, daemon: false, \"rig-id\": \"pithead-e2e\"} ] + .pools) end)
            | .pools |= ([.[] | select(.url | ascii_downcase | contains(\$b)) | . + {\"rig-id\": \"$MINER_WORKER_NAME\"}] + [.[] | select(.url | ascii_downcase | contains(\$b) | not)])' \
            '$MINER_XMRIG_CONFIG' > '$MINER_XMRIG_CONFIG.e2e.tmp' \
        && mv '$MINER_XMRIG_CONFIG.e2e.tmp' '$MINER_XMRIG_CONFIG' && chmod 600 '$MINER_XMRIG_CONFIG'
    " || return 1
    local primary
    primary="$(on_miner "jq -r '.pools[0].url' '$MINER_XMRIG_CONFIG'")"
    [ -n "$primary" ] && step "miner primary pool is now: $primary"
    case "$primary" in
    "$BENCH_HOST":* | *"://$BENCH_HOST":*) ;;
    *)
        warn "primary pool ($primary) is not the test bench — refusing to arm worker-dependent phases"
        return 1
        ;;
    esac
    miner_reload
}

# Stdin keeps the credential out of command lines.
rotate_borrowed_stratum_password() { # stdin: new password
    [ "${CI_RIG_RECOVERY_HOLD:-0}" = 1 ] || return 1
    [ -n "${MINER_ROTATE_CFG_BACKUP:-}" ] || return 1
    on_miner "
        umask 077; secret=\$(mktemp) || exit 1; trap 'rm -f \"\$secret\"' EXIT
        IFS= read -r pass || test -n \"\$pass\" || exit 1; printf '%s' \"\$pass\" >\"\$secret\" || exit 1
        test -e '$MINER_ROTATE_CFG_BACKUP' || cp -a '$MINER_XMRIG_CONFIG' '$MINER_ROTATE_CFG_BACKUP' || exit 1
        jq --arg b '$BENCH_HOST' --rawfile p \"\$secret\" '
            .pools |= map(if (.url | ascii_downcase | contains(\$b)) then .pass = \$p else . end)' \
            '$MINER_XMRIG_CONFIG' > '$MINER_XMRIG_CONFIG.e2e.tmp' \
        && mv '$MINER_XMRIG_CONFIG.e2e.tmp' '$MINER_XMRIG_CONFIG' && chmod 600 '$MINER_XMRIG_CONFIG'
    " || return 1
    miner_reload
}

restore_borrowed_stratum_password() {
    [ -n "${MINER_ROTATE_CFG_BACKUP:-}" ] || return 1
    restore_miner_config "$MINER_ROTATE_CFG_BACKUP" || return 1
    MINER_ROTATE_CFG_BACKUP=""
}

# Keep the recovery anchor until both the exact bytes and the miner service verify.
restore_miner_config() { # <backup>
    on_miner "cp -a '$1' '$MINER_XMRIG_CONFIG' && chmod 600 '$MINER_XMRIG_CONFIG' && cmp -s '$1' '$MINER_XMRIG_CONFIG'" || return 1
    miner_reload && wait_for 60 2 "the restored miner service" miner_service_active || return 1
    on_miner "cmp -s '$1' '$MINER_XMRIG_CONFIG' && rm -f '$1'"
}

miner_service_active() {
    on_miner 'sudo -n systemctl is-active --quiet xmrig || systemctl --user is-active --quiet xmrig'
}

handle_borrow_rearm() {
    local request="$1" ack="$2" run_id="$3" action record owner sequence extra
    record="$(on_bench "cat '$request'")" || return 1
    read -r owner action sequence extra <<<"$record"
    [ "$owner" = "$run_id" ] && [[ "$sequence" =~ ^[0-9]+$ ]] && [ -z "$extra" ] || return 1
    case "$action" in
    rotate-stratum | scenario-stratum)
        step "rotating the reserved miner's temporary stratum credential…"
        MINER_ROTATE_CFG_BACKUP="$MINER_XMRIG_CONFIG.e2e-rotate.$run_id"
        on_bench "sed -n 's/^PROXY_STRATUM_PASSWORD=//p' '$E2E_DIR/.env'" | rotate_borrowed_stratum_password || return 1
        if [ "$action" = scenario-stratum ]; then
            printf '%s' "$record" | on_bench "cat > '$ack.tmp' && mv '$ack.tmp' '$ack'"
            return
        fi
        ;;
    restore-stratum)
        step "restoring the reserved miner's temporary stratum credential…"
        restore_borrowed_stratum_password || return 1
        printf '%s' "$record" | on_bench "cat > '$ack.tmp' && mv '$ack.tmp' '$ack'"
        return
        ;;
    rearm)
        step "RigForge changed rendered miner state; reapplying the borrowed-pool fixture (#1994)…"
        local attempt
        for attempt in 1 2 3 4; do
            repoint_miner || return 1
            wait_workers "$WORKERS" 60 && break
            [ "$attempt" = 4 ] && return 1
            warn "re-arm attempt $attempt: the borrowed rig did not reach the test bench; restarting it again"
        done
        printf '%s' "$record" | on_bench "cat > '$ack.tmp' && mv '$ack.tmp' '$ack'"
        return
        ;;
    *) return 1 ;;
    esac
    wait_workers "$WORKERS" 180 "$MINER_WORKER_NAME" && printf '%s' "$record" | on_bench "cat > '$ack.tmp' && mv '$ack.tmp' '$ack'"
}

# shellcheck disable=SC2016
miner_reload() {
    on_miner '
        mainpid() { systemctl "$1" show -p MainPID --value xmrig 2>/dev/null; }
        moved() {
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                now=$(mainpid "$1")
                [ -n "$now" ] && [ "$now" != 0 ] && [ "$now" != "$2" ] && return 0
                sleep 1
            done
            return 1
        }
        reload() {
            old=$(mainpid --system)
            if sudo -n systemctl restart xmrig >/dev/null 2>&1; then
                moved --system "$old"
                return
            fi
            if sudo -n systemctl stop xmrig >/dev/null 2>&1; then
                sudo -n systemctl start xmrig >/dev/null 2>&1 || sudo -n systemctl start xmrig >/dev/null 2>&1 && moved --system "$old"
                return
            fi
            old=$(mainpid --user)
            systemctl --user restart xmrig >/dev/null 2>&1 && moved --user "$old"
        }
        reload
    '
}

wait_workers() { # <n> <timeout_s> [worker-name]
    local want="$1" deadline=$(($(date +%s) + ${2:-180})) name="${3:-}" got
    [ -z "$name" ] || want=1
    while :; do
        got="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r --arg n '$name' 'if \$n == \"\" then .proxy_workers // 0 else [.workers[]? | select(.name == \$n and .status == \"online\")] | length end' 2>/dev/null" || echo 0)"
        [ -n "$got" ] && [ "$got" -ge "$want" ] 2>/dev/null && {
            ok "$got worker(s) mining through the test bench${name:+ ($name)}"
            return 0
        }
        [ "$(date +%s)" -ge "$deadline" ] && {
            warn "only $got worker(s)${name:+ named $name} connected after $((${2:-180}))s (wanted $want)"
            return 1
        }
        sleep 8
    done
}
