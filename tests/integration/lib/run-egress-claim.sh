assert_host_claims_spent_sync() { # <state-dir> <monero-on> <tari-on>
    local chain csdir="$1" monero_clearnet="$2" tari_clearnet="$3"
    for chain in monero tari; do
        [ "$chain" = monero ] && [ "$monero_clearnet" != true ] && continue
        [ "$chain" = tari ] && [ "$tari_clearnet" != true ] && continue
        if rx "docker exec dashboard sh -c 'rm -f /clearnet-state/$chain.synced'"; then
            it_fail "dashboard cannot reopen spent $chain clearnet sync (#2678)" "removed host-claimed marker"
        elif rx "test -f $(quote_arg "$csdir/$chain.synced")"; then
            it_pass "dashboard cannot reopen spent $chain clearnet sync (#2678)"
        else
            it_fail "dashboard cannot reopen spent $chain clearnet sync (#2678)" "marker missing"
        fi
    done
}
