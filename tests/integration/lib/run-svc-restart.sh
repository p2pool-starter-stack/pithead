# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

_svc_restart_request() {
    local cdir="$1" service="$2" id
    id="$(_uuid4)"
    _spool_write "$cdir/requests/$id.json" \
        "$(jq -nc --arg id "$id" --arg s "$service" '{id:$id,action:"svc-restart",actor:"itest",container:$s}')"
    SVC_RESTART_ID="$id"
    SVC_RESTART_STATUS="$(_wait_control_status "$cdir" "$id" "" "${3:-120}" || echo timeout)"
}

run_svc_restart() {
    # shellcheck disable=SC2034
    IT_CURRENT_SCENARIO="svc-restart"
    echo ""
    it_log "── per-service restart phase (#4062) ────────────"

    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_skip_phase "svc-restart" "remote mode: no local containers/systemd to exercise" "by-design"
        return 0
    fi

    local ctrl_config cdir
    ctrl_config="$(printf '%s' "$BASELINE_CONFIG" | jq '.dashboard.secure=true | .dashboard.auth={username:"admin",password:"a tier4 control passphrase"} | .dashboard.control={enabled:true}')"
    push_config "$ctrl_config"
    it_step "apply with dashboard.control enabled (installs the systemd path unit)…"
    pithead apply -y >"$OUT_DIR/svc-restart.apply.log" 2>&1 || true
    wait_status_ok 180 || true
    cdir="$(env_on_box CONTROL_DIR)"

    if [ -z "$cdir" ] || ! rx "systemctl is-enabled pithead-control.path >/dev/null 2>&1"; then
        it_fail "control runner is installed for the svc-restart phase (#4062)" "CONTROL_DIR unset or pithead-control.path not enabled; see $OUT_DIR/svc-restart.apply.log"
    else
        local started_before started_after
        started_before="$(rx 'docker inspect xmrig-proxy --format "{{.State.StartedAt}}"' 2>/dev/null)"
        it_step "svc-restart xmrig-proxy through the control spool…"
        _svc_restart_request "$cdir" xmrig-proxy
        assert_eq "svc-restart of xmrig-proxy applied by the host runner (#4062)" "$SVC_RESTART_STATUS" "applied"
        wait_status_ok 240 || true
        pithead status >/dev/null 2>&1
        assert_rc "stack healthy after a svc-restart of xmrig-proxy (#4062)" "$?" "0"
        started_after="$(rx 'docker inspect xmrig-proxy --format "{{.State.StartedAt}}"' 2>/dev/null)"
        if [ -n "$started_before" ] && [ -n "$started_after" ] && [ "$started_before" != "$started_after" ]; then
            it_pass "xmrig-proxy was really restarted: its container start time moved (#4062)"
        else
            it_fail "xmrig-proxy was really restarted: its container start time moved (#4062)" "StartedAt before=[$started_before] after=[$started_after]"
        fi
        assert_contains "svc-restart is audited with the service (#4062)" \
            "$(rx "cat $(quote_arg "$cdir/audit/control.log") 2>/dev/null")" '"action":"svc-restart","status":"applied","keys":"xmrig-proxy"'

        _svc_restart_request "$cdir" xmrig-proxy
        assert_eq "a repeat svc-restart inside the cooldown is rejected (#4062)" "$SVC_RESTART_STATUS" "rejected"
        assert_contains "the cooldown refusal says why (#4062)" \
            "$(rx "jq -r '.error // empty' $(quote_arg "$cdir/results/$SVC_RESTART_ID.json") 2>/dev/null")" "wait before restarting it again"

        _svc_restart_request "$cdir" caddy
        assert_eq "svc-restart of a service outside the allowlist is rejected (#4062)" "$SVC_RESTART_STATUS" "rejected"

        local monerod_before
        monerod_before="$(_container_started_ns monerod)"
        it_step "svc-restart tor through the control spool: monerod must be re-dialled once Tor is bootstrapped (#4063)…"
        _svc_restart_request "$cdir" tor 600
        assert_eq "svc-restart of tor applied after the monerod re-dial (#4063)" "$SVC_RESTART_STATUS" "applied"
        wait_status_ok 240 || true
        assert_eq "svc-restart of tor restarted monerod (#4063)" \
            "$([ "$(_container_started_ns monerod)" -gt "$monerod_before" ] 2>/dev/null && echo yes || echo no)" "yes"
        _monerod_started_after_tor "monerod re-dialled after the dashboard's svc-restart of tor: started after tor (#4063)"
    fi

    it_step "restoring baseline (disables control, removes the path unit)…"
    push_config "$BASELINE_CONFIG"
    pithead apply -y >/dev/null 2>&1
    wait_status_ok 240 || true
    if _remove_control_units; then
        it_pass "control systemd units removed after the svc-restart phase (#4062)"
    else
        it_warn "pithead-control units survived teardown — remove them by hand on the box (sudo unavailable?)"
    fi
}
