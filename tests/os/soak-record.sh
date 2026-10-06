# shellcheck shell=bash
# Local derivations and bounded summary; sourced by soak-probe.sh after its baseline exists.
soak_record_derived() {
    : "${line:?caller must supply the read number}"
    local total available used='?' peak='?' chain current previous elapsed growth rate epoch
    total=$(kv mem_total_kib)
    available=$(kv mem_available_kib)
    if [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] && ((total >= available)); then used=$((total - available)); fi
    if [ "$MODE" != --start ] && [ -f "$LOGDIR/memory-sampled-max" ]; then peak=$(cat "$LOGDIR/memory-sampled-max"); fi
    [[ "$peak" =~ ^[0-9]+$ ]] || peak='?'
    if [[ "$used" =~ ^[0-9]+$ ]] && { [ "$peak" = '?' ] || ((used > peak)); }; then peak=$used; fi
    printf '%s\n' "$peak" >"$LOGDIR/memory-sampled-max"
    today+=$(printf '\nmem_used_kib=%s\nmem_sampled_max_kib=%s' "$used" "$peak")
    epoch=$(date -u +%s)
    today+=$(printf '\nsample_epoch=%s' "$epoch")
    for chain in monero tari; do
        current=$(kv "${chain}_chain_mib")
        previous='?'
        elapsed=0
        growth='?'
        rate='?'
        if [ "$MODE" = --start ]; then
            previous=$(sed -n "s/^${chain}_chain_mib=//p" "$LOGDIR/day0.env" | head -1)
        elif [ -f "$LOGDIR/read$((line - 1)).env" ]; then
            previous=$(sed -n "s/^${chain}_chain_mib=//p" "$LOGDIR/read$((line - 1)).env" | head -1)
            elapsed=$(sed -n 's/^sample_epoch=//p' "$LOGDIR/read$((line - 1)).env" | head -1)
            [[ "$elapsed" =~ ^[0-9]+$ ]] && elapsed=$((epoch - elapsed)) || elapsed=0
        fi
        if [[ "$current" =~ ^[0-9]+$ && "$previous" =~ ^[0-9]+$ ]]; then
            growth=$((current - previous))
            if ((elapsed > 0)); then rate=$(awk -v g="$growth" -v e="$elapsed" 'BEGIN{printf "%.3f",g*86400/e}'); fi
        fi
        today+=$(printf '\n%s_growth_mib=%s\n%s_growth_mib_per_day=%s' "$chain" "$growth" "$chain" "$rate")
    done
}
soak_record_summary() {
    local key value
    for key in mem_total_kib mem_available_kib swap_total_kib swap_free_kib mem_used_kib mem_sampled_max_kib \
        monero_chain_mib monero_growth_mib monero_growth_mib_per_day tari_chain_mib tari_growth_mib tari_growth_mib_per_day \
        tari_height p2pool_hashrate p2pool_shares_found p2pool_shares_failed p2pool_sidechain_height \
        proxy_workers proxy_accepted proxy_rejected tor_bootstrap_pct firewall_present firewall_hash first_sync_exemption; do
        value=$(kv "$key")
        printf '%s=%s ' "$key" "${value:-?}"
    done
    value=$(printf '%s\n' "$today" | sed -n 's/^container_stats=//p' | tr '\n' ';' | tr ' ' '_')
    printf 'container_stats=%s' "${value:-?}"
}
soak_live_read_verdict() { # <read.env>; validates collector wiring, not a soak verdict
    local file="$1" key value total available
    for key in mem_total_kib mem_available_kib; do
        value=$(sed -n "s/^$key=//p" "$file")
        [[ "$value" =~ ^[0-9]+$ ]] || return 1
    done
    total=$(sed -n 's/^mem_total_kib=//p' "$file")
    available=$(sed -n 's/^mem_available_kib=//p' "$file")
    ((total > 0 && total >= available)) || return 1
    [ "$(sed -n 's/^firewall_present=//p' "$file")" = 1 ] || return 1
    value=$(sed -n 's/^firewall_hash=//p' "$file")
    [[ "$value" =~ ^[a-f0-9]{64}$ ]] || return 1
    for key in swap_total_kib swap_free_kib monero_chain_mib tari_chain_mib tari_height \
        p2pool_hashrate p2pool_shares_found p2pool_shares_failed p2pool_sidechain_height \
        proxy_workers proxy_accepted proxy_rejected tor_bootstrap_pct; do
        value=$(sed -n "s/^$key=//p" "$file")
        [[ "$value" == '?' || "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    done
    [ -n "$(sed -n 's/^container_stats=//p' "$file")" ]
}
