# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# The #2599 fault leg, split from run-faults.sh (which calls it from run_fault_injection) to keep that
# module under the file budget. Sourced by tests/integration/run.sh after run-faults.sh.
#
# The dashboard's egress alert (#2599): flush the rules at runtime, wait for pithead-egress.timer's
# OWN next check (no manual run: the timer is what is proven), read the verdict off /api/state, then
# `up` reinstalls the rules and the next check clears it. DESTRUCTIVE-then-restored, like
# the firewall rollback fault in run-faults.sh.
_await_egress_state() { # <want> <not-before epoch> -> the dashboard's firewall_state once fresh
    local want="$1" since="$2" deadline got at
    deadline=$(($(date +%s) + ${IT_EGRESS_CHECK_TIMEOUT:-210}))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        at="$(rx 'd=$(grep -E "^CONTROL_DIR=" .env | cut -d= -f2-); jq -r ".checked_at // 0" "${d:-data/control}/results/egress-status.json" 2>/dev/null')"
        got="$(api_state | jq -r '.egress.summary.firewall_state // ""' 2>/dev/null)"
        [ "${at:-0}" -gt "$since" ] && [ "$got" = "$want" ] && break
        sleep 10
    done
    printf '%s' "$got"
}

fault_firewall_status_alert() {
    if [ "$(env_on_box TOR_EGRESS_FIREWALL)" = "false" ]; then
        it_skip_leg "firewall status-alert fault" "network.tor_egress_firewall=false"
        return 0
    fi
    it_step "fault: flush the Tor-egress rules at runtime; the dashboard must alarm, then clear after up…"
    assert_eq "up installed and started the egress check timer (#2599)" "$(rx 'systemctl is-active pithead-egress.timer 2>/dev/null')" "active"
    assert_eq "the timer fires the read-only check, not the boot unit (#2599)" "$(rx 'systemctl show -p Triggers --value pithead-egress.timer')" "pithead-egress-check.service"
    local t0 rc=0 s
    t0="$(rx 'date +%s')"
    rx 'bash -c "source ./pithead && remove_tor_egress_firewall" >/dev/null 2>&1' || true
    assert_eq "the rules are gone" "$(rx 'sudo iptables-save 2>/dev/null | grep -c pithead-tor-egress')" "0"
    assert_eq "the timer's own check reports the flush and the dashboard shows the firewall missing (#2599)" "$(_await_egress_state missing "$t0")" "missing"
    s="$(api_state | jq -c '.egress.summary | [.level, .blocked_by_firewall, (.label | startswith("Tor-only egress firewall MISSING"))]' 2>/dev/null)"
    assert_eq "the egress summary warns, claims nothing blocked, and leads with the missing firewall (#2599)" "$s" '["warn",0,true]'
    rx './pithead up' >/dev/null 2>&1 || rc=$?
    assert_rc "up reinstalls the rules" "$rc" "0"
    assert_eq "the next check clears the alert (#2599)" "$(_await_egress_state enforced "$(rx 'date +%s')")" "enforced"
    assert_egress_dial_pair
}
