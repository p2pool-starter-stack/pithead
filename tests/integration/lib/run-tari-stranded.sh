# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# --- Tari stranded leg (--tari-stranded, #2464) -----------------------------
# A live Tari node that cannot reach a peer must stop reading healthy. An iptables rule in the tari
# container's own network namespace drops its traffic to the tor container, so the process, its gRPC
# and P2Pool's merge-mine channel all stay up while its peers vanish and its tip freezes: the #2465
# shape. Asserts, on the real clocks (tari_health.py): the node's first 0-peer reading (latency recorded);
# amber within OFFLINE (10 min) of it + one poll; red,
# doctor non-zero, the panel, status and the alert within TIP_STALE (30 min) + one poll; no automatic
# remediation (neither tari nor p2pool restarts while red: detection only, #2827 has remediation);
# then, the rule removed, the node rejoins on its own, the verdict returns to green without a
# restart, and the recovery note is sent. Opt-in, about an hour: never part of a preset.
#
# Why tari's namespace and not the host's DOCKER-USER chain: tari and tor share one Docker bridge, and
# same-bridge traffic only traverses the host's FORWARD/DOCKER-USER when br_netfilter is on. Job 1315
# put the rule in DOCKER-USER and the verdict stayed green for 30 minutes. A rule in tari's own OUTPUT
# chain matches whatever the bridge does. It carries a fixed comment, dies with the namespace (any
# tari restart clears it), is removed by an EXIT trap as well as the leg's own cleanup, and the leg
# proves it is in place before it waits on a verdict and reports its drop counter when a wait fails.

TARI_STRAND_TAG="pithead-e2e-fault-tari-stranded"
TARI_POLL_SLACK=120 # one dashboard poll plus the harness's own 10 s sampling, with margin
# The node reports its dead peers only once their connections time out, which varies: about 171 s in
# job 1324, about 15.5 min in job 1611. So the leg waits (bounded) for the verdict's first zero-peer
# reading, records that latency on its own row, and measures the 10-minute amber from it.
TARI_DISCONNECT_MAX=1500

# iptables inside the running tari container's network namespace; prints nothing when tari has no pid.
tari_ns_ipt() { # <iptables args...>
    rx "p=\$(docker inspect -f '{{.State.Pid}}' tari 2>/dev/null); [ \"\${p:-0}\" -gt 0 ] && sudo -n nsenter -t \"\$p\" -n iptables $*" 2>/dev/null
}

# Tagged rules in tari's namespace, and the packets they have dropped so far.
tari_strand_count() { tari_ns_ipt "-S OUTPUT" | grep -c -- "$TARI_STRAND_TAG"; }
tari_strand_drops() { tari_ns_ipt "-L OUTPUT -v -n -x" | awk -v t="$TARI_STRAND_TAG" '$0 ~ t {n += $1} END {print n + 0}'; }

# Every rule carrying the tag, whatever address it was written with. Idempotent; never fails.
tari_strand_remove_all() {
    local _ r
    for _ in 1 2 3 4 5; do # bounded: a rule that will not delete must not loop forever
        r="$(tari_ns_ipt "-S OUTPUT" | grep -m1 -- "$TARI_STRAND_TAG" | sed 's/^-A //')"
        [ -n "$r" ] || break
        tari_ns_ipt "-D $r" >/dev/null
    done
}

# A loopback webhook sink (#2464): the dashboard is host-networked, so the one-off alert sender that
# also feeds Telegram posts its text here. The bench has no Telegram credentials; this proves the red
# alert leaves the dashboard with its reasons, through the same sender Telegram rides.
TARI_HOOK_PORT=18199
TARI_HOOK_LOG=/tmp/pithead-e2e-tari-alerts.log
tari_hook_start() {
    rx "rm -f $TARI_HOOK_LOG; nohup python3 -c 'import http.server as h
class R(h.BaseHTTPRequestHandler):
    def do_POST(s):
        n = int(s.headers.get(\"Content-Length\") or 0); open(\"$TARI_HOOK_LOG\", \"ab\").write(s.rfile.read(n) + b\"\\n\"); s.send_response(204); s.end_headers()
h.HTTPServer((\"127.0.0.1\", $TARI_HOOK_PORT), R).serve_forever()' >/dev/null 2>&1 & echo \$! >/tmp/pithead-e2e-tari-hook.pid" >/dev/null 2>&1
}
tari_hook_stop() { rx "kill \$(cat /tmp/pithead-e2e-tari-hook.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/pithead-e2e-tari-hook.pid" >/dev/null 2>&1 || true; }
tari_restore_config() {
    tari_hook_stop
    push_config "$BASELINE_CONFIG"
    pithead apply -y >/dev/null 2>&1
    wait_status_ok 240 || true
}

tari_strand_abort() {
    local rc=$?
    tari_strand_remove_all
    tari_restore_config
    [ -n "${_TARI_STRAND_FOREIGN_TRAP:-}" ] && eval "$_TARI_STRAND_FOREIGN_TRAP"
    return "$rc"
}

tari_health_field() { jq_get "$(api_state)" ".tari.health.$1"; }
_pred_tari_level() { [ "$(tari_health_field level)" = "$1" ]; }
_pred_tari_at_least_amber() {
    case "$(tari_health_field level)" in amber | red) return 0 ;; esac
    return 1
}
_pred_tari_zero_peers() { [ "$(tari_health_field connections)" = 0 ]; }
_pred_tari_alerted() { rx "grep -q 'Tari node is not following the chain' $TARI_HOOK_LOG" >/dev/null 2>&1; }
_pred_tari_recovery_alerted() { rx "grep -q 'Tari node is following the chain again' $TARI_HOOK_LOG" >/dev/null 2>&1; }
# A container's last start: unchanged across the leg means nothing restarted it.
tari_started_at() { rx "docker inspect -f '{{.State.StartedAt}}' $1" 2>/dev/null; }
tari_strand_state() { echo "verdict '$(tari_health_field level)', height $(tari_health_field height), peers $(tari_health_field connections), $(tari_strand_drops) packets dropped by the fault"; }

run_tari_stranded() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="tari-stranded"
    echo ""
    it_log "── tari-stranded phase (#2464) ─────────────────────"
    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_tari; then
        it_skip_phase "tari-stranded" "no local Tari node to strand" "by-design"
        return 0
    fi
    local tor t0 tari_start p2pool_start fails_before="$IT_FAIL"
    tor="$(rx "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' tor" 2>/dev/null | head -n1)"
    if [ -z "$tor" ]; then
        it_fail "tari-stranded: tor address" "empty — fault not injected"
        return
    fi
    if [ -z "${IT_TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${IT_TELEGRAM_CHAT_ID:-}" ]; then
        it_skip_leg "tari-stranded: red alert delivered by Telegram itself (#2464)" "no IT_TELEGRAM_BOT_TOKEN/IT_TELEGRAM_CHAT_ID on the bench; the alert is captured at a loopback webhook fed by the same sender" "missing"
    fi
    tari_hook_start
    if ! push_config "$(printf '%s' "$BASELINE_CONFIG" | jq --arg u "http://127.0.0.1:$TARI_HOOK_PORT/tari" '.notifications.webhooks=[$u] | .notifications.tor=false')" ||
        ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
        it_fail "tari-stranded: loopback alert sink configured" "apply did not converge — fault not injected"
        tari_restore_config
        return
    fi
    wait_for 600 10 "Tari verdict green before the fault" _pred_tari_level green ||
        it_fail "tari-stranded: green baseline" "verdict '$(tari_health_field level)' before any fault — fault not injected"
    if [ "$(tari_health_field level)" != green ]; then
        tari_restore_config
        return
    fi

    local cur
    cur="$(trap -p EXIT)"
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _TARI_STRAND_FOREIGN_TRAP="${parsed[2]}"
    fi
    trap tari_strand_abort EXIT
    tari_start="$(tari_started_at tari)"
    p2pool_start="$(tari_started_at p2pool)"

    it_step "fault: drop tari -> tor inside tari's network namespace ($TARI_STRAND_TAG)…"
    tari_ns_ipt "-I OUTPUT -d $tor -m comment --comment $TARI_STRAND_TAG -j DROP" >/dev/null
    t0=$(now_s)
    # A fault that is not in place must fail here, not read later as "the verdict stayed green".
    if [ "$(tari_strand_count)" -ge 1 ] 2>/dev/null; then
        it_pass "tari-stranded: DROP rule is in tari's OUTPUT chain"
    else
        it_fail "tari-stranded: DROP rule is in tari's OUTPUT chain" "not found — fault not injected"
        tari_strand_abort
        trap - EXIT
        return
    fi
    local t_zero="" red_by
    if wait_for "$TARI_DISCONNECT_MAX" 10 "the node reporting 0 peers" _pred_tari_zero_peers; then
        t_zero=$(now_s)
        it_pass "tari-stranded: disconnect latency: the node reported 0 peers $((t_zero - t0)) s after the fault"
    else
        it_fail "tari-stranded: the node reports 0 peers within ${TARI_DISCONNECT_MAX} s of the fault" "$(tari_strand_state)"
    fi
    if [ -n "$t_zero" ]; then
        # OFFLINE (10 min) of observed zero peers, plus one poll. Red counts: it is amber and more.
        if wait_for $((600 + TARI_POLL_SLACK)) 10 "Tari verdict amber" _pred_tari_at_least_amber; then
            it_pass "tari-stranded: amber $(($(now_s) - t_zero)) s after the first 0-peer reading: $(tari_health_field reasons)"
        else
            it_fail "tari-stranded: amber within 10 min of the first 0-peer reading + one poll" "$(tari_strand_state)"
        fi
    fi
    # Red needs the tip stale 30 min (from the fault) and zero peers 10 min (from their first reading).
    local zero_off=$((${t_zero:-$t0} - t0))
    red_by=$((zero_off + 600 > 1800 ? zero_off + 600 : 1800))
    if wait_for $((red_by + TARI_POLL_SLACK - ($(now_s) - t0))) 10 "Tari verdict red" _pred_tari_level red; then
        it_pass "tari-stranded: red after $(($(now_s) - t0)) s: $(tari_health_field reasons)"
    else
        it_fail "tari-stranded: red within max(30 min, 0-peer reading + 10 min) + one poll" "$(tari_strand_state)"
    fi
    pithead doctor >/dev/null 2>&1
    assert_ne "tari-stranded: doctor exits non-zero on red" "$?" "0"
    # The panel prints .tari.status as it stands, coloured by .tari.health.level (statcards.mjs).
    assert_contains "tari-stranded: the Tari panel reads red with the reasons (live /api/state)" \
        "$(tari_health_field level)|$(jq_get "$(api_state)" '.tari.status')" "red|Not following the chain: tip"
    if wait_for 120 10 "red alert at the sink" _pred_tari_alerted; then
        it_pass "tari-stranded: the red alert left the dashboard with its reasons"
    else
        it_fail "tari-stranded: the red alert left the dashboard with its reasons" "nothing at the loopback sink"
    fi
    assert_contains "tari-stranded: status prints the red verdict" "$(pithead status 2>&1)" "NOT following the chain"

    # Detection only (#2827 has remediation): a red verdict held past the old 5-minute restart
    # trigger must leave both containers alone. Their StartedAt is the proof.
    it_step "hold red for 6 min: no automatic restart of tari or p2pool…"
    sleep 360
    assert_eq "tari-stranded: red for 6+ min, tari not restarted" "$(tari_started_at tari)" "$tari_start"
    assert_eq "tari-stranded: red for 6+ min, p2pool not relaunched" "$(tari_started_at p2pool)" "$p2pool_start"
    assert_eq "tari-stranded: the fault is still in place (nothing cleared it)" "$(tari_strand_count)" "1"

    # Recovery is the operator's; here, the fault going away. The node rejoins its peers on its own
    # (job 1348 measured it), and the verdict must follow it back to green without a restart.
    it_step "recover: remove the rule; the node must rejoin and the verdict return to green…"
    tari_strand_remove_all
    t0=$(now_s)
    if wait_for 2400 15 "Tari verdict green after the fault is removed" _pred_tari_level green; then
        it_pass "tari-stranded: green $(($(now_s) - t0)) s after the fault was removed"
    else
        it_fail "tari-stranded: green after the fault was removed" "verdict '$(tari_health_field level)': $(tari_health_field reasons)"
    fi
    if wait_for 120 10 "recovery note at the sink" _pred_tari_recovery_alerted; then
        it_pass "tari-stranded: the recovery note left the dashboard"
    else
        it_fail "tari-stranded: the recovery note left the dashboard" "nothing at the loopback sink"
    fi
    assert_eq "tari-stranded: recovered without a restart (tari)" "$(tari_started_at tari)" "$tari_start"
    assert_eq "tari-stranded: p2pool never relaunched" "$(tari_started_at p2pool)" "$p2pool_start"
    tari_restore_config
    trap - EXIT
    # shellcheck disable=SC2064  # restore the saved trap text as it was, expanded now on purpose
    [ -n "${_TARI_STRAND_FOREIGN_TRAP:-}" ] && trap "$_TARI_STRAND_FOREIGN_TRAP" EXIT
    assert_eq "tari-stranded: no $TARI_STRAND_TAG rule left behind" "$(tari_strand_count)" "0"
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "tari-stranded" "$OUT_DIR"
    return 0
}
