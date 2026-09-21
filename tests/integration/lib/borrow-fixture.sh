# shellcheck shell=bash

# Reapply the temporary pool fixture without minting another restore anchor. RigForge correctly
# regenerates xmrig's rendered config after bootstrap/control applies; e2e.sh's original backup
# remains the one and only restore source (#1994).
repoint_miner() {
    # Inject a bench pool if needed, then keep it primary with the rig's original pools as failover.
    # ponytail: :3333 is the seeded canonical stratum port the bench runs.
    on_miner "
        jq --arg b '$BENCH_HOST' '
            (if any(.pools[]?; .url | ascii_downcase | contains(\$b)) then .
             else .pools = ([ (.pools[0]) + {url: (\$b + \":3333\"), tls: false, daemon: false, \"rig-id\": \"pithead-e2e\"} ] + .pools) end)
            | .pools |= ([.[] | select(.url | ascii_downcase | contains(\$b))] + [.[] | select(.url | ascii_downcase | contains(\$b) | not)])' \
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

# The e2e controller alone holds the miner SSH connection and the original restore anchor. The
# phase asks it to replace the temporary test-pool password; stdin keeps that credential out of
# command lines and the short-lived file is readable only by the rig owner.
rotate_borrowed_stratum_password() { # stdin: new password
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
    on_miner "cp -a '$MINER_ROTATE_CFG_BACKUP' '$MINER_XMRIG_CONFIG' && chmod 600 '$MINER_XMRIG_CONFIG' && cmp -s '$MINER_ROTATE_CFG_BACKUP' '$MINER_XMRIG_CONFIG' && rm -f '$MINER_ROTATE_CFG_BACKUP'" || return 1
    MINER_ROTATE_CFG_BACKUP=""
    miner_reload
}

handle_borrow_rearm() { # <request> <ack> <run-id>
    local request="$1" ack="$2" run_id="$3" action
    action="$(on_bench "cat '$request'")"
    case "$action" in
    "$run_id rotate-stratum")
        step "rotating the reserved miner's temporary stratum credential…"
        MINER_ROTATE_CFG_BACKUP="$MINER_XMRIG_CONFIG.e2e-rotate.$run_id"
        on_bench "sed -n 's/^PROXY_STRATUM_PASSWORD=//p' '$E2E_DIR/.env'" | rotate_borrowed_stratum_password || return 1
        ;;
    "$run_id restore-stratum")
        step "restoring the reserved miner's temporary stratum credential…"
        restore_borrowed_stratum_password || return 1
        printf '%s' "$action" | on_bench "cat > '$ack'"
        return
        ;;
    "$run_id rearm")
        step "RigForge changed rendered miner state; reapplying the borrowed-pool fixture (#1994)…"
        repoint_miner || return 1
        ;;
    *) return 1 ;;
    esac
    wait_workers "$WORKERS" 180 && printf '%s' "$action" | on_bench "cat > '$ack'"
}
