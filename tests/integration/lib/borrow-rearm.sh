# shellcheck shell=bash

# e2e.sh owns the miner SSH session and its restore anchor. Ask it to reapply the borrowed-pool
# fixture after RigForge writes; worker-dependent phases stay blocked until it acknowledges success.
wait_borrow_rearm() {
    [ -n "${IT_BORROW_REARM_REQUEST:-}" ] || return 0
    [ -n "${IT_BORROW_REARM_ACK:-}" ] && [ -n "${IT_BORROW_REARM_TOKEN:-}" ] || {
        it_fail "borrowed-pool re-arm handshake configured" "ack path or token is empty"
        return 1
    }
    printf '%s' "$IT_BORROW_REARM_TOKEN" >"$IT_BORROW_REARM_REQUEST" || {
        it_fail "borrowed-pool re-arm requested after RigForge control (#1994)" "could not write request marker"
        return 1
    }
    if wait_for 120 2 "the e2e controller to re-arm the borrowed miner pool" _borrow_rearm_ack_matches; then
        it_pass "borrowed miner points at the test stack after RigForge control (#1994)"
        return 0
    fi
    it_fail "borrowed miner points at the test stack after RigForge control (#1994)" "controller did not acknowledge a verified re-arm"
    return 1
}

_borrow_rearm_ack_matches() {
    [ "$(cat "$IT_BORROW_REARM_ACK" 2>/dev/null)" = "$IT_BORROW_REARM_TOKEN" ]
}
