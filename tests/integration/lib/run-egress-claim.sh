# shellcheck shell=bash
assert_host_claims_spent_sync() { # <state-dir> <monero-on> <tari-on>
    local chain replay csdir="$1" monero_clearnet="$2" tari_clearnet="$3"
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
        # Only an explicit permission denial is replay proof, not a missing marker or failed exec.
        if replay=$(rx "docker exec dashboard python3 -c '
from pathlib import Path
marker = Path(\"/clearnet-state/$chain.synced\")
value = marker.read_bytes()
try:
    marker.write_bytes(value)
except PermissionError:
    print(\"replay-refused\")
'") && [ "$replay" = replay-refused ]; then
            it_pass "dashboard cannot replay spent $chain marker in place (#3440)"
        else
            it_fail "dashboard cannot replay spent $chain marker in place (#3440)" "same-text write was not refused with PermissionError"
        fi
    done
}
