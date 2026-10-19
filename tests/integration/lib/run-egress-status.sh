# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# The Tor-egress firewall fault legs (#2460 boot restore, #2599 status alert), split from
# run-faults.sh, which calls them from run_fault_injection, to keep that module under the file
# budget. Sourced by tests/integration/run.sh after run-faults.sh.
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

# DIY reboot restore (#2460), without rebooting the bench: a reboot empties DOCKER-USER while the
# containers restart, and pithead-egress.service is what refills it. Check docker.service pulls the
# unit in and waits for it, strip the rules exactly as a reboot does, run the installed unit
# itself against the real kernel, and prove the result is LIVE (the direct dial dropped, the Tor
# one through), not merely present. DESTRUCTIVE-then-restored, like the rollback fault in run-faults.sh.
fault_firewall_boot_restore() {
    if [ "$(env_on_box TOR_EGRESS_FIREWALL)" = "false" ]; then
        it_skip_leg "firewall boot-restore fault" "network.tor_egress_firewall=false"
        return 0
    fi
    it_step "fault: strip the Tor-egress rules as a reboot does, then run the boot unit…"
    assert_eq "up installed and enabled the boot unit (#2460)" \
        "$(rx 'systemctl is-enabled pithead-egress.service 2>/dev/null')" "enabled"
    assert_contains "docker.service pulls the boot unit in (#2460)" \
        "$(rx 'systemctl show -p Wants --value docker.service')" "pithead-egress.service"
    assert_contains "docker.service starts only after it (#2460)" \
        "$(rx 'systemctl show -p After --value docker.service')" "pithead-egress.service"
    rx 'bash -c "source ./pithead && remove_tor_egress_firewall" >/dev/null 2>&1' || true
    assert_eq "the rules are gone, as after a reboot" \
        "$(rx 'sudo iptables-save 2>/dev/null | grep -c pithead-tor-egress')" "0"
    local rc=0
    rx 'sudo systemctl restart pithead-egress.service' >/dev/null 2>&1 || rc=$?
    assert_rc "the boot unit starts cleanly on the real kernel (#2460)" "$rc" "0"
    rc=0
    rx 'bash -c "source ./pithead && tor_egress_enforced"' >/dev/null 2>&1 || rc=$?
    assert_rc "the rules it restored read as enforced: DROP reachable, nothing foreign above it (#2460)" "$rc" "0"
    assert_egress_dial_pair
}
