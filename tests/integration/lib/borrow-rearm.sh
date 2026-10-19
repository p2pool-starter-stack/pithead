# shellcheck shell=bash

# e2e.sh owns the miner SSH session and its restore anchor. Ask it to reapply the borrowed-pool
# fixture after RigForge writes; worker-dependent phases stay blocked until it acknowledges success.
wait_borrow_rearm() { # [action]
    local action="${1:-rearm}"
    [ -n "${IT_BORROW_REARM_REQUEST:-}" ] || {
        [ "$action" = rearm ] && return 0
        it_fail "borrowed miner $action handshake configured" "request transport is absent"
        return 1
    }
    [ -n "${IT_BORROW_REARM_ACK:-}" ] && [ -n "${IT_BORROW_REARM_TOKEN:-}" ] || {
        it_fail "borrowed-pool re-arm handshake configured" "ack path or token is empty"
        return 1
    }
    _BORROW_REARM_SEQUENCE=$((${_BORROW_REARM_SEQUENCE:-0} + 1))
    IT_BORROW_REARM_EXPECTED="$IT_BORROW_REARM_TOKEN $action $_BORROW_REARM_SEQUENCE"
    rm -f "$IT_BORROW_REARM_REQUEST" "$IT_BORROW_REARM_ACK" &&
        (
            umask 077
            printf '%s' "$IT_BORROW_REARM_EXPECTED" >"$IT_BORROW_REARM_REQUEST.tmp"
        ) &&
        mv "$IT_BORROW_REARM_REQUEST.tmp" "$IT_BORROW_REARM_REQUEST" || {
        it_fail "borrowed-pool re-arm requested after RigForge control (#1994)" "could not write request marker"
        return 1
    }
    if wait_for 120 2 "the e2e controller to re-arm the borrowed miner pool" _borrow_rearm_ack_matches "$action"; then
        it_pass "borrowed miner $action verified by the controller"
        return 0
    fi
    it_fail "borrowed miner $action verified by the controller" "controller did not acknowledge this request"
    return 1
}

_borrow_rearm_ack_matches() {
    [ "$(cat "$IT_BORROW_REARM_ACK" 2>/dev/null)" = "$IT_BORROW_REARM_EXPECTED" ]
}
