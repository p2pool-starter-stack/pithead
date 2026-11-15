# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

P2POOL_PEER_LOSS_TAG="pithead-e2e-fault-p2pool-peers"
P2POOL_PEER_LOSS_DISCONNECT_MAX=1500
P2POOL_PEER_LOSS_RESTART_MAX=2400
P2POOL_PEER_LOSS_REJOIN_MAX=1800

p2pool_ns_ipt() {
    rx "p=\$(docker inspect -f '{{.State.Pid}}' p2pool 2>/dev/null); [ \"\${p:-0}\" -gt 0 ] && sudo -n nsenter -t \"\$p\" -n iptables $*" 2>/dev/null
}
p2pool_peer_loss_rules() {
    printf '%s\n' \
        "OUTPUT -d $1 -m comment --comment $P2POOL_PEER_LOSS_TAG -j DROP" \
        "OUTPUT -p tcp --dport 37888:37890 -m comment --comment $P2POOL_PEER_LOSS_TAG -j DROP" \
        "OUTPUT -p tcp --sport 37888:37890 -m comment --comment $P2POOL_PEER_LOSS_TAG -j DROP" \
        "INPUT -p tcp --dport 37888:37890 -m comment --comment $P2POOL_PEER_LOSS_TAG -j DROP"
}
p2pool_peer_loss_count() {
    local chain total=0 n
    for chain in INPUT OUTPUT; do
        n=$(p2pool_ns_ipt "-S $chain" | grep -c -- "$P2POOL_PEER_LOSS_TAG")
        total=$((total + n))
    done
    printf '%s\n' "$total"
}
p2pool_peer_total() {
    local pdir
    pdir=$(env_on_box P2POOL_DATA_DIR)
    rx "sudo -n cat $(quote_arg "$pdir/stats/local/p2p") 2>/dev/null | jq -r '(.connections // 0) + (.incoming_connections // 0)'" 2>/dev/null
}
p2pool_started_at() { rx "docker inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null; }
_pred_p2pool_peerless() { [ "$(p2pool_peer_total)" = 0 ]; }
_pred_p2pool_restarted() { [ "$(p2pool_started_at)" != "$1" ]; }
_pred_p2pool_has_peers() { [ "$(p2pool_peer_total)" -gt 0 ] 2>/dev/null; }
_pred_p2pool_rejoin_logged() {
    rx "docker logs --since $1 dashboard 2>&1 | grep -q 'P2Pool rejoined the sidechain'" >/dev/null 2>&1
}

fault_p2pool_peer_loss() {
    local tor pdir started epoch t0 t_zero logs rule restarts
    pdir=$(env_on_box P2POOL_DATA_DIR)
    if [ -z "$pdir" ]; then
        it_fail "p2pool peer-loss leg has a data dir (#4077)" "no P2POOL_DATA_DIR in .env"
        return
    fi
    fault_rules_clear_all
    tor=$(rx "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' tor" 2>/dev/null | head -n1)
    if [ -z "$tor" ]; then
        it_fail "p2pool peer-loss leg finds the tor address (#4077)" "empty, fault not injected"
        return
    fi
    if ! wait_for 900 10 "p2pool holding peers before the fault" _pred_p2pool_has_peers; then
        it_skip_leg "p2pool peer-loss: cut a P2Pool that holds peers (#4077)" "p2pool had no peer for 15 minutes before any fault" "missing"
        return
    fi
    started=$(p2pool_started_at)
    epoch=$(rx 'date +%s')
    fault_rules_trap_arm
    it_step "fault: cut every P2Pool peer path inside p2pool's network namespace ($P2POOL_PEER_LOSS_TAG)…"
    while IFS= read -r rule; do
        p2pool_ns_ipt "-I $rule" >/dev/null
    done < <(p2pool_peer_loss_rules "$tor")
    t0=$(now_s)
    if [ "$(p2pool_peer_loss_count)" -ge 4 ] 2>/dev/null; then
        it_pass "p2pool peer-loss: the four DROP rules are in p2pool's namespace (#4077)"
    else
        it_fail "p2pool peer-loss: the four DROP rules are in p2pool's namespace (#4077)" "not found, fault not injected"
        fault_rules_clear_all
        fault_rules_trap_disarm
        return
    fi
    if wait_for "$P2POOL_PEER_LOSS_DISCONNECT_MAX" 15 "p2pool reporting zero peers" _pred_p2pool_peerless; then
        t_zero=$(now_s)
        it_pass "p2pool peer-loss: P2Pool reported zero peers $((t_zero - t0)) s after the cut (#4077)"
    else
        it_fail "p2pool peer-loss: P2Pool reports zero peers within ${P2POOL_PEER_LOSS_DISCONNECT_MAX} s of the cut (#4077)" "still holding peers"
        fault_rules_clear_all
        fault_rules_trap_disarm
        return
    fi
    if wait_for "$P2POOL_PEER_LOSS_RESTART_MAX" 30 "dashboard restarts the peerless p2pool" _pred_p2pool_restarted "$started"; then
        it_pass "p2pool peer-loss: the dashboard restarted the peerless P2Pool unattended $(($(now_s) - t_zero)) s after the first zero reading (#4077)"
    else
        it_fail "p2pool peer-loss: the dashboard restarts a P2Pool peerless for 15 minutes (#4077)" "container start time unchanged after ${P2POOL_PEER_LOSS_RESTART_MAX} s"
    fi
    logs=$(rx "docker logs --since $epoch dashboard 2>&1")
    assert_contains "p2pool peer-loss: the restart is named in the dashboard log (#4077)" "$logs" "P2Pool has had no peers for"
    if wait_for "$P2POOL_PEER_LOSS_REJOIN_MAX" 30 "p2pool peers and sidechain tip resume" _pred_p2pool_rejoin_logged "$epoch"; then
        it_pass "p2pool peer-loss: peers returned and the sidechain tip resumed unattended (#4077)"
    else
        it_fail "p2pool peer-loss: peers return and the sidechain tip resumes unattended (#4077)" "no tip progress within ${P2POOL_PEER_LOSS_REJOIN_MAX} s of the restart"
    fi
    restarts=$(rx "docker logs --since $epoch dashboard 2>&1 | grep -c 'P2Pool has had no peers for'")
    assert_eq "p2pool peer-loss: exactly one restart for the one outage (#4077)" "$restarts" "1"
    fault_rules_clear_all
    fault_rules_trap_disarm
    assert_eq "p2pool peer-loss: no $P2POOL_PEER_LOSS_TAG rule left behind (#4077)" "$(p2pool_peer_loss_count)" "0"
}
