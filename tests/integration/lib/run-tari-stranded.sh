# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# --- Tari stranded leg (--tari-stranded, #2464) -----------------------------
# A live Tari node that cannot reach a peer must stop reading healthy. A host DOCKER-USER rule drops
# the tari container's traffic to the tor container, so the process, its gRPC and P2Pool's merge-mine
# channel all stay up while its peers vanish and its tip freezes: the #2465 shape. Asserts, on the
# real clocks (tari_health.py): amber within OFFLINE (10 min) + one poll; red and doctor non-zero
# within TIP_STALE (30 min) + one poll; the automatic restart withheld while the node's gRPC does not
# answer (SIGSTOP stands in for a migration, #2593); then, with the rule gone, the restart fires and the
# verdict returns to green after catch-up. Opt-in, about an hour: never part of a preset.
#
# The rule carries a fixed comment so the bench's baseline restore and the drift audit can find a
# leftover; it is removed by an EXIT trap as well as the leg's own cleanup, and the leg asserts it is
# gone before it reports.

TARI_STRAND_TAG="pithead-e2e-fault-tari-stranded"
TARI_POLL_SLACK=120 # one dashboard poll plus the harness's own 10 s sampling, with margin

tari_ip_of() { rx "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $1" 2>/dev/null | head -n1; }

tari_strand_rule() { # <-I|-D> <tari-ip> <tor-ip>
    rx "sudo -n iptables $1 DOCKER-USER -s $2 -d $3 -m comment --comment $TARI_STRAND_TAG -j DROP" >/dev/null 2>&1
}

# Every rule carrying the tag, whatever addresses it was written with. Idempotent; never fails.
tari_strand_remove_all() {
    rx "while sudo -n iptables -S DOCKER-USER 2>/dev/null | grep -q -- '$TARI_STRAND_TAG'; do r=\$(sudo -n iptables -S DOCKER-USER | grep -m1 -- '$TARI_STRAND_TAG' | sed 's/^-A /-D /'); eval \"sudo -n iptables \$r\" || break; done" >/dev/null 2>&1 || true
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

run_tari_stranded() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="tari-stranded"
    echo ""
    it_log "── tari-stranded phase (#2464) ─────────────────────"
    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_tari; then
        it_skip_phase "tari-stranded" "no local Tari node to strand" "by-design"
        return 0
    fi
    local tari tor t0 fails_before="$IT_FAIL"
    tari="$(tari_ip_of tari)"
    tor="$(tari_ip_of tor)"
    if [ -z "$tari" ] || [ -z "$tor" ]; then
        it_fail "tari-stranded: container addresses" "tari='$tari' tor='$tor' — fault not injected"
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

    it_step "fault: drop tari -> tor at DOCKER-USER ($TARI_STRAND_TAG)…"
    tari_strand_rule -I "$tari" "$tor"
    t0=$(now_s)
    if wait_for $((600 + TARI_POLL_SLACK)) 10 "Tari verdict amber" _pred_tari_level amber; then
        it_pass "tari-stranded: amber after $(($(now_s) - t0)) s: $(tari_health_field reasons)"
    else
        it_fail "tari-stranded: amber within 10 min + one poll" "verdict '$(tari_health_field level)'"
    fi
    if wait_for $((1800 + TARI_POLL_SLACK - ($(now_s) - t0))) 10 "Tari verdict red" _pred_tari_level red; then
        it_pass "tari-stranded: red after $(($(now_s) - t0)) s: $(tari_health_field reasons)"
    else
        it_fail "tari-stranded: red within 30 min + one poll" "verdict '$(tari_health_field level)'"
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
    assert_eq "tari-stranded: no $TARI_STRAND_TAG rule left behind" \
        "$(rx "sudo -n iptables -S DOCKER-USER 2>/dev/null | grep -c -- '$TARI_STRAND_TAG'" 2>/dev/null)" "0"
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "tari-stranded" "$OUT_DIR"
    return 0
}
