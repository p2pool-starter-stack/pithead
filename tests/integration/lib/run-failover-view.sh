# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

FAILOVER_POOL_PORT=3399
FAILOVER_VIEW_WINDOW=120

_failover_row_field() {
    printf '%s' "$1" | jq -r --arg n "$2" "first(.workers[]? | select(.name == \$n)) | $3 // empty" 2>/dev/null
}

_failover_snapshot() {
    FAILOVER_STATE="$(api_state)"
    printf '%s' "$FAILOVER_STATE" | jq -e 'type == "object" and (.workers | type) == "array" and (.badges | type) == "array"' >/dev/null 2>&1
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
        | (.hashrate.total | capture("^[0-9.]+ (?<u>[kMG]?)H/s$").u | {"": 1, "k": 1e3, "M": 1e6, "G": 1e9}[.]) as $unit
        | .proxy_workers == ($here | length) and (($total - $expected) | fabs) <= $unit * 0.005 + 1' >/dev/null 2>&1
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
    [[ "$banner" == "Mining paused here: "?*"$suffix" ]]
}

_pred_failover_banner_names_rigs() {
    _failover_snapshot && _failover_banner_matches "$FAILOVER_STATE"
}

_pred_failover_banner_absent() {
    _failover_snapshot && [ -z "$(_failover_banner "$FAILOVER_STATE")" ]
}

_failover_pool_start() {
    local out
    out="$(rx "d=\$(mktemp -d \"\${TMPDIR:-/tmp}/failover-pool.XXXXXX\") && cat >\"\$d/fake_stratum.py\" && : >\"\$d/log\" && { setsid nohup timeout 3600 python3 \"\$d/fake_stratum.py\" 0.0.0.0 $FAILOVER_POOL_PORT \"\$d/log\" </dev/null >\"\$d/out\" 2>&1 & echo \$! >\"\$d/pid\"; } && echo \"\$d\"" --stdin <"$HERE/fakes/fake_stratum.py")" || return 1
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
    rx "kill \$(cat $(quote_arg "$FAILOVER_POOL_DIR/pid") 2>/dev/null) 2>/dev/null; rm -rf $(quote_arg "$FAILOVER_POOL_DIR")" >/dev/null 2>&1 || true
    FAILOVER_POOL_DIR=""
}

_failover_pin_rig() {
    local cfg current
    if [ -z "$RIG_HOST" ] || [ -z "${IT_RIG_TOKEN:-}" ]; then
        it_fail "failover-view has the rig host and token to pin the rig (#4074)" "--rig-host or the rig token is missing"
        return 1
    fi
    current="$(rx 'cat config.json')" && [ -n "$BASELINE_CONFIG" ] && printf '%s' "$current" | jq -e 'type == "object"' >/dev/null 2>&1 || {
        it_fail "failover-view read config.json and has a baseline to restore (#4074)" "config.json is unreadable or not an object, or no baseline was captured"
        return 1
    }
    cfg="$(printf '%s' "$current" | IT_RIG_TOKEN="$IT_RIG_TOKEN" jq --arg n "$RIG_NAME" --arg h "$RIG_HOST" --argjson cp "$RIG_CONTROL_PORT" '
        del(.dashboard.workers)
        | .workers.list = ((.workers.list // []) | map(select(.name != $n)) + [{name:$n, host:$h, port:8081, control_port:$cp, token:env.IT_RIG_TOKEN}])')" || {
        it_fail "failover-view built the pinned-rig config (#4074)" "config.json could not be read or rewritten"
        return 1
    }
    FAILOVER_CONFIG_PUSHED=1
    push_config "$cfg" && pithead apply -y >/dev/null 2>&1 || {
        it_fail "failover-view pinned the rig in workers.list (#4074)" "config push or apply failed"
        return 1
    }
    wait_status_ok 240 || true
    wait_for 120 5 "the dashboard to poll the pinned rig" _pred_failover_row_polled || {
        it_fail "the dashboard polled the pinned rig within 120s (#4074)" "the rig row never reported api_ok"
        return 1
    }
}

_pred_failover_row_polled() {
    _failover_snapshot && [ "$(_failover_row_field "$FAILOVER_STATE" "$RIG_NAME" '.api_ok')" = true ]
}

_failover_view_restore() {
    if [ "${FAILOVER_CONFIG_PUSHED:-0}" = 1 ]; then
        push_config "$BASELINE_CONFIG" && pithead apply -y >/dev/null 2>&1 || it_fail "failover-view restored the baseline config (#4074)" "config push or apply failed"
        wait_status_ok 240 || true
    fi
    if has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        rx "docker compose up -d monerod" >/dev/null 2>&1 || true
        wait_for 240 5 "monerod healthy after the failover view" _pred_monerod_healthy ||
            it_fail "monerod is healthy after the failover view (#4074)" "it did not recover within 240s"
    fi
    wait_for 180 5 "xmrig-proxy readmitted after the failover view" _pred_failover_armed ||
        it_fail "xmrig-proxy is readmitted after the failover view (#4074)" "it was not readmitted within 180s"
    wait_borrow_rearm rearm || true
    _failover_pool_stop
}

_failover_row_diagnostics() {
    printf '%s' "$FAILOVER_STATE" | jq -c --arg n "$RIG_NAME" '
        def host: sub(":[0-9]+$"; "") | if test("^[0-9.]+$") then "ip" elif . == "" then "none" else "name" end;
        {workers: ([.workers[]?] | length), named_row_found: (any(.workers[]?; .name == $n)),
         rows: [.workers[]? | {status, api_ok, adopted, state: .mining.state, pool_host: ((.mining.pool // "") | host),
                pool_port: ((.mining.pool // "") | capture(":(?<p>[0-9]+)$").p? // null), has_telemetry: (.telemetry_h60 != null)}]}' 2>/dev/null |
        while IFS= read -r line; do it_warn "failover-view row diagnostics: $line"; done
}

_failover_view_transition() {
    local desc="$1" pred="$2"
    shift 2
    if wait_for "$FAILOVER_VIEW_WINDOW" 5 "$desc" "$pred" "$@"; then
        it_pass "$desc within ${FAILOVER_VIEW_WINDOW}s (#4074)"
        return 0
    fi
    it_fail "$desc within ${FAILOVER_VIEW_WINDOW}s (#4074)" "the dashboard state did not reach it in time"
    _failover_row_diagnostics
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
        it_pass "the rig's own telemetry hashrate stays on its row (#4074)"
    else
        it_skip_leg "telemetry hashrate shown beside an off-Pithead rig (#4074)" "the rig reported no telemetry hashrate" missing
    fi
    assert_contains "the served Workers table module carries the backup-pool label (#4074)" \
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
    _failover_view_transition "no paused banner after the rig returns" _pred_failover_banner_absent
    if [ "$(jq_get "$FAILOVER_STATE" '.proxy_workers')" -ge "$alive0" ] 2>/dev/null; then
        it_pass "Workers Alive is back to ${alive0} or more (#4074)"
    else
        it_fail "Workers Alive is back to ${alive0} or more (#4074)" "proxy_workers is $(jq_get "$FAILOVER_STATE" '.proxy_workers')"
    fi
}

_failover_view_abort() {
    local rc=$?
    trap - EXIT
    _failover_view_restore
    [ -z "${_FAILOVER_FOREIGN_TRAP:-}" ] || eval "$_FAILOVER_FOREIGN_TRAP"
    return "$rc"
}

_failover_trap_arm() {
    local cur parsed
    cur="$(trap -p EXIT)"
    _FAILOVER_FOREIGN_TRAP=""
    if [ -n "$cur" ]; then
        eval "parsed=($cur)"
        _FAILOVER_FOREIGN_TRAP="${parsed[2]}"
    fi
    trap _failover_view_abort EXIT
}

_failover_trap_disarm() {
    trap - EXIT
    # shellcheck disable=SC2064
    [ -z "${_FAILOVER_FOREIGN_TRAP:-}" ] || trap "$_FAILOVER_FOREIGN_TRAP" EXIT
    _FAILOVER_FOREIGN_TRAP=""
}

run_failover_view() {
    # shellcheck disable=SC2034
    IT_CURRENT_SCENARIO="failover-view"
    echo ""
    it_log "── failover-view phase (#4074) ─────────────────────"
    if [ -z "$RIG_NAME" ] || [ -z "${IT_BORROW_REARM_REQUEST:-}" ]; then
        it_skip_phase "failover-view" "no borrowed rig to move between pools" missing
        return 0
    fi
    FAILOVER_POOL_DIR=""
    FAILOVER_CONFIG_PUSHED=0
    _failover_trap_arm
    _failover_pin_rig && _failover_view_legs
    _failover_view_restore
    _failover_trap_disarm
}
