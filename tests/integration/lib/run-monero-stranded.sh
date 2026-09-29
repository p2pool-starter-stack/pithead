# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# --- Monero stranded leg (--monero-stranded, #2499) --------------------------
# A live monerod with no peers must stop reading healthy on every layer. Like the Tari leg (#2464), an
# iptables rule in monerod's own network namespace drops its traffic to the tor container, so the RPC
# keeps answering and the process stays up while its outgoing peers die. Asserts, on the real clocks
# (monero_health.py, build/monero/healthcheck.sh): the node's first 0-outgoing-peer reading (latency
# recorded); then within the 10-minute bound plus a poll, the verdict red with the numbers, the
# container's docker health unhealthy, doctor non-zero, status naming it, the card's payload red, and
# the alert at a loopback webhook; no automatic restart; then, the rule removed, the node re-peers and
# every layer returns to green, with the recovery note. Opt-in, about 40 minutes: never part of a preset.
# The rule carries a fixed comment, dies with monerod's namespace, and is removed by an EXIT trap too.

MONERO_STRAND_TAG="pithead-e2e-fault-monero-stranded"
MONERO_POLL_SLACK=180 # a dashboard poll, the healthcheck's 30 s x 3 retries, and the harness's sampling
MONERO_DISCONNECT_MAX=1500
MONERO_HOOK_PORT=18198
MONERO_HOOK_LOG=/tmp/pithead-e2e-monero-alerts.log

monero_ns_ipt() { # <iptables args...>
    rx "p=\$(docker inspect -f '{{.State.Pid}}' monerod 2>/dev/null); [ \"\${p:-0}\" -gt 0 ] && sudo -n nsenter -t \"\$p\" -n iptables $*" 2>/dev/null
}
monero_strand_count() { monero_ns_ipt "-S OUTPUT" | grep -c -- "$MONERO_STRAND_TAG"; }
monero_strand_remove_all() {
    local _ r
    for _ in 1 2 3 4 5; do # bounded: a rule that will not delete must not loop forever
        r="$(monero_ns_ipt "-S OUTPUT" | grep -m1 -- "$MONERO_STRAND_TAG" | sed 's/^-A //')"
        [ -n "$r" ] || break
        monero_ns_ipt "-D $r" >/dev/null
    done
}
monero_hook_start() {
    rx "rm -f $MONERO_HOOK_LOG; nohup python3 -c 'import http.server as h
class R(h.BaseHTTPRequestHandler):
    def do_POST(s):
        n = int(s.headers.get(\"Content-Length\") or 0); open(\"$MONERO_HOOK_LOG\", \"ab\").write(s.rfile.read(n) + b\"\\n\"); s.send_response(204); s.end_headers()
h.HTTPServer((\"127.0.0.1\", $MONERO_HOOK_PORT), R).serve_forever()' >/dev/null 2>&1 & echo \$! >/tmp/pithead-e2e-monero-hook.pid" >/dev/null 2>&1
}
monero_hook_stop() { rx "kill \$(cat /tmp/pithead-e2e-monero-hook.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/pithead-e2e-monero-hook.pid" >/dev/null 2>&1 || true; }
monero_restore_config() {
    monero_hook_stop
    push_config "$BASELINE_CONFIG"
    pithead apply -y >/dev/null 2>&1
    wait_status_ok 240 || true
}
monero_strand_abort() {
    local rc=$?
    monero_strand_remove_all
    monero_restore_config
    [ -n "${_MONERO_STRAND_FOREIGN_TRAP:-}" ] && eval "$_MONERO_STRAND_FOREIGN_TRAP"
    return "$rc"
}

monero_health_field() { jq_get "$(api_state)" ".monero.health.$1"; }
_pred_monero_level() { [ "$(monero_health_field level)" = "$1" ]; }
# monerod's own outgoing count, the field the dashboard and healthcheck both read.
monero_out_peers() {
    rx 'u=$(grep -E "^MONERO_NODE_USERNAME=" .env | cut -d= -f2-); p=$(grep -E "^MONERO_NODE_PASSWORD=" .env | cut -d= -f2-);
        curl -fsS --max-time 8 --digest -u "$u:$p" http://127.0.0.1:18081/get_info | jq -r .outgoing_connections_count' 2>/dev/null
}
_pred_monero_zero_out() { [ "$(monero_out_peers)" = 0 ]; }
_pred_monerod_docker_health() { [ "$(rx "docker inspect -f '{{.State.Health.Status}}' monerod" 2>/dev/null)" = "$1" ]; }
_pred_monero_alerted() { rx "grep -q 'Monero node has no outgoing peers' $MONERO_HOOK_LOG" >/dev/null 2>&1; }
_pred_monero_recovery_alerted() { rx "grep -q 'Monero node has outgoing peers again' $MONERO_HOOK_LOG" >/dev/null 2>&1; }
monero_started_at() { rx "docker inspect -f '{{.State.StartedAt}}' monerod" 2>/dev/null; }
monero_strand_state() { echo "verdict '$(monero_health_field level)', peers $(monero_health_field peers_out) out, docker health '$(rx "docker inspect -f '{{.State.Health.Status}}' monerod" 2>/dev/null)'"; }

run_monero_stranded() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="monero-stranded"
    echo ""
    it_log "── monero-stranded phase (#2499) ───────────────────"
    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_skip_phase "monero-stranded" "no local monerod to strand" "by-design"
        return 0
    fi
    local tor t0 started fails_before="$IT_FAIL"
    tor="$(rx "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' tor" 2>/dev/null | head -n1)"
    if [ -z "$tor" ]; then
        it_fail "monero-stranded: tor address" "empty — fault not injected"
        return
    fi
    monero_hook_start
    if ! push_config "$(printf '%s' "$BASELINE_CONFIG" | jq --arg u "http://127.0.0.1:$MONERO_HOOK_PORT/monero" '.notifications.webhooks=[$u] | .notifications.tor=false')" ||
        ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
        it_fail "monero-stranded: loopback alert sink configured" "apply did not converge — fault not injected"
        monero_restore_config
        return
    fi
    wait_for 600 10 "Monero verdict green before the fault" _pred_monero_level green ||
        it_fail "monero-stranded: green baseline" "$(monero_strand_state) before any fault — fault not injected"
    if [ "$(monero_health_field level)" != green ]; then
        monero_restore_config
        return
    fi

    local cur
    cur="$(trap -p EXIT)"
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _MONERO_STRAND_FOREIGN_TRAP="${parsed[2]}"
    fi
    trap monero_strand_abort EXIT
    started="$(monero_started_at)"

    it_step "fault: drop monerod -> tor inside monerod's network namespace ($MONERO_STRAND_TAG)…"
    monero_ns_ipt "-I OUTPUT -d $tor -m comment --comment $MONERO_STRAND_TAG -j DROP" >/dev/null
    t0=$(now_s)
    if [ "$(monero_strand_count)" -ge 1 ] 2>/dev/null; then
        it_pass "monero-stranded: DROP rule is in monerod's OUTPUT chain"
    else
        it_fail "monero-stranded: DROP rule is in monerod's OUTPUT chain" "not found — fault not injected"
        monero_strand_abort
        trap - EXIT
        return
    fi
    local t_zero=""
    if wait_for "$MONERO_DISCONNECT_MAX" 10 "monerod reporting 0 outgoing peers" _pred_monero_zero_out; then
        t_zero=$(now_s)
        it_pass "monero-stranded: disconnect latency: monerod reported 0 outgoing peers $((t_zero - t0)) s after the fault"
    else
        it_fail "monero-stranded: monerod reports 0 outgoing peers within ${MONERO_DISCONNECT_MAX} s of the fault" "$(monero_strand_state)"
    fi
    # The bound (NODE_STALE_AFTER_SEC, 10 min) runs from the first zero reading; one poll of slack.
    if wait_for $((600 + MONERO_POLL_SLACK)) 10 "Monero verdict red" _pred_monero_level red; then
        it_pass "monero-stranded: red $(($(now_s) - ${t_zero:-$t0})) s after the first 0-peer reading: $(monero_health_field reasons)"
    else
        it_fail "monero-stranded: red within 10 min of the first 0-peer reading + one poll" "$(monero_strand_state)"
    fi
    assert_contains "monero-stranded: the card payload reads red with the numbers (live /api/state)" \
        "$(monero_health_field level)|$(jq_get "$(api_state)" '.monero.health.status')" "red|0 outgoing peers for"
    if wait_for 240 10 "monerod docker health unhealthy" _pred_monerod_docker_health unhealthy; then
        it_pass "monero-stranded: docker inspect health is unhealthy (the healthcheck read the same zero)"
    else
        it_fail "monero-stranded: docker inspect health is unhealthy" "$(monero_strand_state)"
    fi
    pithead doctor >/dev/null 2>&1
    assert_ne "monero-stranded: doctor exits non-zero on red" "$?" "0"
    assert_contains "monero-stranded: status names the peerless node" "$(pithead status 2>&1)" "monero chain"
    if wait_for 120 10 "red alert at the sink" _pred_monero_alerted; then
        it_pass "monero-stranded: the peerless alert left the dashboard with the numbers"
    else
        it_fail "monero-stranded: the peerless alert left the dashboard" "nothing at the loopback sink"
    fi
    assert_eq "monero-stranded: detection only, monerod was not restarted" "$(monero_started_at)" "$started"

    it_step "recover: remove the rule; monerod must re-peer and every layer return to green…"
    monero_strand_remove_all
    t0=$(now_s)
    if wait_for 2400 15 "Monero verdict green after the fault is removed" _pred_monero_level green; then
        it_pass "monero-stranded: green $(($(now_s) - t0)) s after the fault was removed"
    else
        it_fail "monero-stranded: green after the fault was removed" "$(monero_strand_state)"
    fi
    if wait_for 300 10 "monerod docker health healthy" _pred_monerod_docker_health healthy; then
        it_pass "monero-stranded: docker inspect health is healthy again"
    else
        it_fail "monero-stranded: docker inspect health is healthy again" "$(monero_strand_state)"
    fi
    if wait_for 120 10 "recovery note at the sink" _pred_monero_recovery_alerted; then
        it_pass "monero-stranded: the recovery note left the dashboard"
    else
        it_fail "monero-stranded: the recovery note left the dashboard" "nothing at the loopback sink"
    fi
    assert_eq "monero-stranded: recovered without a restart" "$(monero_started_at)" "$started"
    monero_restore_config
    trap - EXIT
    # shellcheck disable=SC2064  # restore the saved trap text as it was, expanded now on purpose
    [ -n "${_MONERO_STRAND_FOREIGN_TRAP:-}" ] && trap "$_MONERO_STRAND_FOREIGN_TRAP" EXIT
    assert_eq "monero-stranded: no $MONERO_STRAND_TAG rule left behind" "$(monero_strand_count)" "0"
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "monero-stranded" "$OUT_DIR"
    return 0
}
