# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

FAILOVER_POOL_PORT=3399
FAILOVER_VIEW_WINDOW=120

_failover_row_field() {
    printf '%s' "$1" | jq -r --arg n "$2" "first(.workers[]? | select(.name == \$n)) | $3 // empty" 2>/dev/null
}

_failover_snapshot() {
    FAILOVER_STATE="$(api_state)"
    [ -n "$FAILOVER_STATE" ]
}

_pred_failover_row_state() {
    _failover_snapshot &&
        [ "$(_failover_row_field "$FAILOVER_STATE" "$RIG_NAME" '.mining.state')" = "$1" ]
}

_pred_failover_row_pool() {
    _pred_failover_row_state on_backup &&
        [[ "$(_failover_row_field "$FAILOVER_STATE" "$RIG_NAME" '.mining.pool')" == *":$FAILOVER_POOL_PORT" ]]
}

_failover_aggregates_json() {
    printf '%s' "$1" | jq -e '
        def hs: capture("^(?<v>[0-9.]+) (?<u>[kMG]?)H/s$") | (.v | tonumber) * ({"": 1, "k": 1e3, "M": 1e6, "G": 1e9}[.u]);
        def eff: if (.h15 // 0) != 0 then .h15 else (.h60 // 0) end;
        [.workers[]? | select(.status == "online" and ((.mining.state // "unknown") | IN("on_backup", "not_connected") | not))] as $here
        | (($here | map(eff) | add) // 0) as $expected
        | (.hashrate.total | hs) as $total
        | .proxy_workers == ($here | length) and (($total - $expected) | fabs) <= 10 + $expected * 0.01' >/dev/null 2>&1
}

_pred_failover_aggregates_here() {
    _failover_snapshot && _failover_aggregates_json "$FAILOVER_STATE"
}

_pred_failover_alive_below() {
    _failover_snapshot && [ "$(jq_get "$FAILOVER_STATE" '.proxy_workers')" -lt "$1" ] 2>/dev/null &&
        _failover_aggregates_json "$FAILOVER_STATE"
}

_failover_banner() {
    printf '%s' "$1" | jq -r '[.badges[]?.text | select(startswith("Mining paused here"))] | first // empty' 2>/dev/null
}

_failover_moved_suffix() {
    local moved
    moved="$(printf '%s' "$1" | jq '[.workers[]? | select(.mining.state == "on_backup")] | length' 2>/dev/null)"
    [ "${moved:-0}" -ge 1 ] || return 1
    if [ "$moved" = 1 ]; then printf ', 1 rig on backup pool'; else printf ', %s rigs on backup pool' "$moved"; fi
}

_failover_banner_matches() {
    local banner suffix
    banner="$(_failover_banner "$1")"
    suffix="$(_failover_moved_suffix "$1")" || return 1
    [ -n "$banner" ] && [[ "$banner" == *"$suffix" ]]
}

_pred_failover_banner_names_rigs() {
    _failover_snapshot && _failover_banner_matches "$FAILOVER_STATE"
}

_pred_failover_banner_absent() {
    _failover_snapshot && [ -z "$(_failover_banner "$FAILOVER_STATE")" ]
}

_failover_pool_start() {
    local out
    out="$(rx "d=\$(mktemp -d \"\${TMPDIR:-/tmp}/failover-pool.XXXXXX\") && cat >\"\$d/fake_stratum.py\" && : >\"\$d/log\" && { setsid nohup timeout 3600 python3 \"\$d/fake_stratum.py\" 0.0.0.0 $FAILOVER_POOL_PORT \"\$d/log\" </dev/null >\"\$d/out\" 2>&1 & } && echo \"\$d\"" --stdin <"$HERE/fakes/fake_stratum.py")" || return 1
    FAILOVER_POOL_DIR="$(printf '%s\n' "$out" | tail -n 1)"
    case "$FAILOVER_POOL_DIR" in /*/failover-pool.*) ;; *)
        FAILOVER_POOL_DIR=""
        return 1
        ;;
    esac
    wait_for 20 1 "the harness's second pool to listen" _pred_failover_pool_listening
}

_pred_failover_pool_listening() {
    rx "python3 -c 'import socket; socket.create_connection((\"127.0.0.1\", $FAILOVER_POOL_PORT), 2).close()'" >/dev/null 2>&1
}

_failover_pool_logins() {
    rx "grep -c '^login\$' $(quote_arg "$FAILOVER_POOL_DIR/log")" 2>/dev/null
}

_failover_pool_stop() {
    [ -n "${FAILOVER_POOL_DIR:-}" ] || return 0
    rx "pkill -f $(quote_arg "$FAILOVER_POOL_DIR/fake_stratum.py"); rm -rf $(quote_arg "$FAILOVER_POOL_DIR")" >/dev/null 2>&1 || true
    FAILOVER_POOL_DIR=""
}

_failover_view_restore() {
    rx "docker compose up -d monerod" >/dev/null 2>&1 || true
    wait_for 240 5 "monerod healthy after the failover view" _pred_monerod_healthy || true
    wait_for 180 5 "xmrig-proxy readmitted after the failover view" _pred_failover_armed || true
    wait_borrow_rearm rearm || true
    _failover_pool_stop
}

_failover_view_transition() {
    local desc="$1" pred="$2"
    shift 2
    if wait_for "$FAILOVER_VIEW_WINDOW" 5 "$desc" "$pred" "$@"; then
        it_pass "$desc within ${FAILOVER_VIEW_WINDOW}s (#4074)"
        return 0
    fi
    it_fail "$desc within ${FAILOVER_VIEW_WINDOW}s (#4074)" "the dashboard state did not reach it in time"
    return 1
}

_failover_view_legs() {
    local alive0
    if ! _failover_view_transition "rig row reads mining here before the move" _pred_failover_row_state mining_here; then
        return
    fi
    alive0="$(jq_get "$FAILOVER_STATE" '.proxy_workers')"
    if ! _failover_pool_start; then
        it_fail "harness second pool started (#4074)" "the fake stratum did not listen on port $FAILOVER_POOL_PORT"
        return
    fi
    it_step "move: the borrowed rig fails over to the harness's second pool…"
    if ! wait_borrow_rearm failover-pool; then
        return
    fi
    _failover_view_transition "rig row reads on backup pool" _pred_failover_row_pool
    if [ "$(_failover_pool_logins)" -ge 1 ] 2>/dev/null; then
        it_pass "the second pool saw the rig log in (#4074)"
    else
        it_fail "the second pool saw the rig log in (#4074)" "no login reached the fake stratum"
    fi
    _failover_view_transition "Workers Alive dropped and Total Hashrate counts only this Pithead" _pred_failover_alive_below "$alive0"
    if [ -n "$(_failover_row_field "$FAILOVER_STATE" "$RIG_NAME" '.telemetry_h60')" ]; then
        it_pass "the rig's own telemetry hashrate stays on its row, outside the totals (#4074)"
    else
        it_skip_leg "telemetry hashrate shown beside an off-Pithead rig (#4074)" "the rig reported no telemetry hashrate" missing
    fi
    assert_contains "the served Workers table labels a rig on a backup pool (#4074)" \
        "$(rx 'curl -fsS --max-time 10 http://127.0.0.1:8000/static/app/miningnote.mjs' 2>/dev/null)" "on backup pool"
    _failover_view_transition "no paused banner while this Pithead is serving" _pred_failover_banner_absent
    if has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_step "fault: stop monerod so this Pithead stops serving work…"
        rx "docker compose stop monerod" >/dev/null 2>&1
        FAILOVER_VIEW_WINDOW=180 _failover_view_transition "paused banner names the reason and the rigs on a backup pool" _pred_failover_banner_names_rigs
        it_step "recover: start monerod…"
        rx "docker compose start monerod" >/dev/null 2>&1
        wait_for 240 5 "monerod healthy" _pred_monerod_healthy || true
        wait_for 180 5 "xmrig-proxy readmitted" _pred_failover_armed || true
        _failover_view_transition "paused banner clears after recovery" _pred_failover_banner_absent
    else
        it_skip_leg "paused banner with a rig on a backup pool (#4074)" "remote mode: no local monerod to break" by-design
    fi
    it_step "return: the borrowed rig goes back to this Pithead's stratum…"
    wait_borrow_rearm rearm || return
    _failover_view_transition "rig row reads mining here again" _pred_failover_row_state mining_here
    _failover_view_transition "Workers Alive and Total Hashrate count the returned rig" _pred_failover_aggregates_here
    if [ "$(jq_get "$FAILOVER_STATE" '.proxy_workers')" -ge "$alive0" ] 2>/dev/null; then
        it_pass "Workers Alive is back to ${alive0} or more (#4074)"
    else
        it_fail "Workers Alive is back to ${alive0} or more (#4074)" "proxy_workers is $(jq_get "$FAILOVER_STATE" '.proxy_workers')"
    fi
}

run_failover_view() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="failover-view"
    echo ""
    it_log "── failover-view phase (#4074) ─────────────────────"
    if [ -z "$RIG_NAME" ] || [ -z "${IT_BORROW_REARM_REQUEST:-}" ]; then
        it_skip_phase "failover-view" "no borrowed rig to move between pools" missing
        return 0
    fi
    FAILOVER_POOL_DIR=""
    _failover_view_legs
    _failover_view_restore
}
