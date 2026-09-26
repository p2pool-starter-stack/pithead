# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# --- Tari stranded leg (--tari-stranded, #2464) -----------------------------
# A live Tari node that cannot reach a peer must stop reading healthy. An iptables rule in the tari
# container's own network namespace drops its traffic to the tor container, so the process, its gRPC
# and P2Pool's merge-mine channel all stay up while its peers vanish and its tip freezes: the #2465
# shape. Asserts, on the real clocks (tari_health.py): amber within OFFLINE (10 min) + one poll; red
# and doctor non-zero within TIP_STALE (30 min) + one poll; the automatic restart withheld while the
# node's gRPC does not answer (SIGSTOP stands in for a migration, #2593); then, with the rule gone, the
# restart fires and the verdict returns to green after catch-up. Opt-in, about an hour: never part of
# a preset.
#
# Why tari's namespace and not the host's DOCKER-USER chain: tari and tor share one Docker bridge, and
# same-bridge traffic only traverses the host's FORWARD/DOCKER-USER when br_netfilter is on. Job 1315
# put the rule in DOCKER-USER and the verdict stayed green for 30 minutes. A rule in tari's own OUTPUT
# chain matches whatever the bridge does. It carries a fixed comment, dies with the namespace (any
# tari restart clears it), is removed by an EXIT trap as well as the leg's own cleanup, and the leg
# proves it is in place before it waits on a verdict and reports its drop counter when a wait fails.

TARI_STRAND_TAG="pithead-e2e-fault-tari-stranded"
TARI_POLL_SLACK=120 # one dashboard poll plus the harness's own 10 s sampling, with margin

tari_ip_of() { rx "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $1" 2>/dev/null | head -n1; }

# iptables inside the running tari container's network namespace; prints nothing when tari has no pid.
tari_ns_ipt() { # <iptables args...>
    rx "p=\$(docker inspect -f '{{.State.Pid}}' tari 2>/dev/null); [ \"\${p:-0}\" -gt 0 ] && sudo -n nsenter -t \"\$p\" -n iptables $*" 2>/dev/null
}

tari_strand_rule() { # <tor-ip>
    tari_ns_ipt "-I OUTPUT -d $1 -m comment --comment $TARI_STRAND_TAG -j DROP" >/dev/null
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
    rx "docker compose kill -s SIGCONT tari" >/dev/null 2>&1 || true
}

tari_strand_abort() {
    local rc=$?
    tari_strand_remove_all
    [ -n "${_TARI_STRAND_FOREIGN_TRAP:-}" ] && eval "$_TARI_STRAND_FOREIGN_TRAP"
    return "$rc"
}

tari_health_field() { jq_get "$(api_state)" ".tari.health.$1"; }
_pred_tari_level() { [ "$(tari_health_field level)" = "$1" ]; }
_pred_tari_restarted() { [ "$(tari_health_field restarts)" -ge 1 ] 2>/dev/null; }
tari_strand_state() { echo "verdict '$(tari_health_field level)', height $(tari_health_field height), $(tari_strand_drops) packets dropped by the fault"; }

run_tari_stranded() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="tari-stranded"
    echo ""
    it_log "── tari-stranded phase (#2464) ─────────────────────"
    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_tari; then
        it_skip_phase "tari-stranded" "no local Tari node to strand" "by-design"
        return 0
    fi
    local tor t0 fails_before="$IT_FAIL"
    tor="$(tari_ip_of tor)"
    if [ -z "$tor" ]; then
        it_fail "tari-stranded: tor address" "empty — fault not injected"
        return
    fi
    wait_for 600 10 "Tari verdict green before the fault" _pred_tari_level green ||
        it_fail "tari-stranded: green baseline" "verdict '$(tari_health_field level)' before any fault — fault not injected"
    [ "$(tari_health_field level)" = green ] || return

    local cur
    cur="$(trap -p EXIT)"
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _TARI_STRAND_FOREIGN_TRAP="${parsed[2]}"
    fi
    trap tari_strand_abort EXIT

    it_step "fault: drop tari -> tor inside tari's network namespace ($TARI_STRAND_TAG)…"
    tari_strand_rule "$tor"
    t0=$(now_s)
    # A fault that is not in place must fail here, not read later as "the verdict stayed green".
    if [ "$(tari_strand_count)" -ge 1 ] 2>/dev/null; then
        it_pass "tari-stranded: DROP rule is in tari's OUTPUT chain"
    else
        it_fail "tari-stranded: DROP rule is in tari's OUTPUT chain" "not found — fault not injected"
        tari_strand_remove_all
        return
    fi
    if wait_for $((600 + TARI_POLL_SLACK)) 10 "Tari verdict amber" _pred_tari_level amber; then
        it_pass "tari-stranded: amber after $(($(now_s) - t0)) s: $(tari_health_field reasons)"
    else
        it_fail "tari-stranded: amber within 10 min + one poll" "$(tari_strand_state)"
    fi
    if wait_for $((1800 + TARI_POLL_SLACK - ($(now_s) - t0))) 10 "Tari verdict red" _pred_tari_level red; then
        it_pass "tari-stranded: red after $(($(now_s) - t0)) s: $(tari_health_field reasons)"
    else
        it_fail "tari-stranded: red within 30 min + one poll" "$(tari_strand_state)"
    fi
    pithead doctor >/dev/null 2>&1
    assert_ne "tari-stranded: doctor exits non-zero on red" "$?" "0"
    assert_contains "tari-stranded: status prints the red verdict" "$(pithead status 2>&1)" "NOT following the chain"

    it_step "sub-case: freeze tari (gRPC silent, as during a migration) — the restart must be withheld…"
    rx "docker compose kill -s SIGSTOP tari" >/dev/null 2>&1
    sleep 420 # past RED_SUSTAIN (5 min) + one poll
    assert_eq "tari-stranded: no restart while the node's gRPC is silent" "$(tari_health_field restarts)" "0"

    it_step "recover: remove the rule, then thaw; the automatic restart and catch-up must bring green…"
    tari_strand_remove_all # rule first, SIGCONT second: a thawed node must not be restarted still stranded
    t0=$(now_s)
    if wait_for $((600 + TARI_POLL_SLACK)) 10 "automatic Tari restart" _pred_tari_restarted; then
        it_pass "tari-stranded: automatic restart fired after $(($(now_s) - t0)) s"
    else
        it_fail "tari-stranded: automatic restart" "restarts=$(tari_health_field restarts)"
    fi
    if wait_for 2400 15 "Tari verdict green after catch-up" _pred_tari_level green; then
        it_pass "tari-stranded: green $(($(now_s) - t0)) s after the rule was removed"
    else
        it_fail "tari-stranded: green after restart and catch-up" "verdict '$(tari_health_field level)': $(tari_health_field reasons)"
    fi

    trap - EXIT
    # shellcheck disable=SC2064  # restore the saved trap text as it was, expanded now on purpose
    [ -n "${_TARI_STRAND_FOREIGN_TRAP:-}" ] && trap "$_TARI_STRAND_FOREIGN_TRAP" EXIT
    assert_eq "tari-stranded: no $TARI_STRAND_TAG rule left behind" "$(tari_strand_count)" "0"
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "tari-stranded" "$OUT_DIR"
    return 0
}
