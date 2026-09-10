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
