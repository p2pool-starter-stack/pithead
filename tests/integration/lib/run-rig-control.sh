# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
_worker_apply() { # <worker> <changes-json>  -> echoes the dashboard result JSON
    local body
    body="$(printf '%s' "$2" | jq -ce --arg w "$1" 'if type == "object" then {worker:$w,changes:.} else error("changes") end')" || return 1
    printf '%s' "$body" | rx "curl -fsS --max-time 60 -X POST -H 'Content-Type: application/json' -H 'X-Pithead-Control: 1' --data-binary @- http://127.0.0.1:8000/api/control/worker-apply" --stdin 2>/dev/null
}

_restore_rig_control_baseline() {
    if ! push_config "$BASELINE_CONFIG"; then
        it_fail "write baseline after RigForge control" "could not restore config.json"
        return 1
    fi
    if ! pithead apply -y >"$OUT_DIR/rigforge-control.restore.log" 2>&1; then
        it_fail "restore baseline after RigForge control" "see $OUT_DIR/rigforge-control.restore.log"
        return 1
    fi
    if ! wait_status_ok 240; then
        it_fail "baseline healthy after RigForge control restore" "status did not recover"
        return 1
    fi
}
# Real RigForge write coverage (#513/#514/#516/#517), destructive then restored. The only descriptor
# shape is workers.list[]; explicit borrowed-rig inputs make missing setup a failure.
run_rigforge_control() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="rigforge-control"
    echo ""
    it_log "── RigForge control phase (#513/#514/#516/#517) ────"

    if [ "$IT_MODE" != "local" ]; then
        it_skip_phase "rigforge-control" "needs local mode: it edits config.json + dials the rig on the mining LAN" "by-design"
        return 0
    fi
    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_skip_phase "rigforge-control" "remote mode: no local dashboard container to drive" "by-design"
        return 0
    fi

    local st rig supplied=0 control_rc
    st="$(api_state)"
    rig="$RIG_NAME"
    if [ -n "$rig" ]; then
        supplied=1
    else
        rig="$(printf '%s' "$st" | jq -r 'first(.workers[]? | select(.rigforge != null and .rigforge.version != null) | .name) // empty' 2>/dev/null)"
    fi
    if [ -z "$rig" ]; then
        it_skip_phase "rigforge-control" "no worker exposes a RigForge enriched feed — the write paths need a real rig with its :8081 API on (#513/#514/#516/#517)"
        return 0
    fi

    local have_host inject=0
    have_host="$(printf '%s' "$BASELINE_CONFIG" | jq -r --arg n "$rig" 'first((.workers.list // [])[] | select(.name==$n) | .host) // empty' 2>/dev/null)"
    if [ -z "$have_host" ]; then
        if [ -n "$RIG_HOST" ] && [ -n "${IT_RIG_TOKEN:-}" ]; then
            inject=1
        else
            if [ "$supplied" = 1 ]; then
                it_fail "supplied rig has host/token descriptor inputs" "'$rig' lacks a descriptor and --rig-host + IT_RIG_TOKEN"
            else
                it_skip_phase "rigforge-control" "rig '$rig' has no workers.list[] descriptor and no --rig-host + IT_RIG_TOKEN to inject one (#513/#514/#516/#517)"
            fi
            return "$supplied"
        fi
    fi

    # Enable control while preserving any existing login.
    local ctrl_config
    ctrl_config="$(printf '%s' "$BASELINE_CONFIG" | jq '.dashboard.control.enabled = true')"
    if [ -z "$(env_on_box DASHBOARD_AUTH_HASH_B64)" ]; then
        ctrl_config="$(printf '%s' "$ctrl_config" | jq '.dashboard.auth = {username:"admin",password:"a tier4 rigforge-control passphrase"}')"
    fi
    if [ "$inject" = "1" ]; then
        if ! printf '%s' "$RIG_CONTROL_PORT" | grep -qE '^[0-9]{1,5}$'; then
            it_fail "--rig-control-port is a port number" "got [$RIG_CONTROL_PORT]"
            return 0
        fi
        ctrl_config="$(printf '%s' "$ctrl_config" | IT_RIG_TOKEN="${IT_RIG_TOKEN:-}" jq \
            --arg n "$rig" --arg h "$RIG_HOST" --argjson cp "$RIG_CONTROL_PORT" '
            del(.dashboard.workers)
            | .workers.list = ((.workers.list // []) | map(select(.name != $n)) + [{name:$n, host:$h, port:8081, control_port:$cp, token:env.IT_RIG_TOKEN}])')"
        it_step "injecting a workers.list[] descriptor for '$rig' at $RIG_HOST:$RIG_CONTROL_PORT (token masked in-container)"
    fi

    local fails_before="$IT_FAIL"
    push_config "$ctrl_config"
    it_step "apply with dashboard.control on + the rig pinned in workers.list[]…"
    if ! pithead apply -y >"$OUT_DIR/rigforge-control.apply.log" 2>&1; then
        it_fail "apply (control on + rig descriptor) succeeded" "see $OUT_DIR/rigforge-control.apply.log"
        _restore_rig_control_baseline || true
        return 1
    fi
    wait_status_ok 240 || true
    if [ -n "$RIGFORGE_BOOTSTRAP_VERSION" ]; then
        if ! rigforge_bootstrap "$rig" "$RIGFORGE_BOOTSTRAP_VERSION"; then
            _restore_rig_control_baseline || true
            return 1
        fi
    fi
    if ! wait_for 120 5 "dashboard to re-read the selected rig after control setup" _pred_rig_present "$rig"; then
        if [ "$supplied" = 1 ]; then
            it_fail "supplied rig exposes its enriched feed after control setup" "worker '$rig' never appeared"
        else
            it_skip_phase "rigforge-control" "worker '$rig' no longer exposes an enriched feed"
        fi
        _restore_rig_control_baseline || true
        return 1
    fi

    if [ "$RUN_RIGFORGE" = 1 ]; then
        local read_fails="$IT_FAIL"
        run_rigforge_integration "$rig"
        # shellcheck disable=SC2034  # read by lib.sh:it_fail after the nested phase changes it
        IT_CURRENT_SCENARIO="rigforge-control"
        if [ "$IT_FAIL" -gt "$read_fails" ]; then
            _restore_rig_control_baseline || true
            return 1
        fi
    fi

    # A populated masked descriptor must preserve the enriched read path (#514).
    st="$(api_state)"
    assert_eq "rig api_ok true with a populated masked descriptor (#514, v1.5.2 regression)" \
        "$(printf '%s' "$st" | jq -r --arg n "$rig" 'first(.workers[]? | select(.name==$n) | .api_ok) // empty' 2>/dev/null)" "true"
    assert_ne "rigforge feed still resolves with the token masked (#514)" \
        "$(printf '%s' "$st" | jq -r --arg n "$rig" 'first(.workers[]? | select(.name==$n) | .rigforge.version) // empty' 2>/dev/null)" ""

    local detail
    detail="$(_worker_detail "$rig" || true)"
    assert_eq "Worker Inspect reports the rig editable with a descriptor (#508/#513)" \
        "$(printf '%s' "$detail" | jq -r '.editable // false' 2>/dev/null)" "true"
    assert_eq "Worker Inspect control_enabled (#513)" \
        "$(printf '%s' "$detail" | jq -r '.control_enabled // false' 2>/dev/null)" "true"

    # A reversible, benign writable change: nudge max_temp_c by +1. It is the one writable key the
    # enriched feed echoes (watchdog Temp/max), so read the current ceiling from the feed FIRST — if
    # the rig's watchdog isn't reporting it we can't safely restore it, so skip the write rather than
    # leave the rig mis-tuned.
    local orig_maxt new_maxt res status ckeys change_id
    orig_maxt="$(printf '%s' "$st" | jq -r --arg n "$rig" 'first(.workers[]? | select(.name==$n) | .rigforge.stats[]? | select(.label=="Temp / max") | .value) // empty' 2>/dev/null | sed -n 's#.*/ *\([0-9][0-9]*\).*#\1#p')"
    if [ -z "$orig_maxt" ]; then
        it_skip_leg "reversible write, max_temp_c (#513)" "rig '$rig' watchdog isn't reporting a max_temp_c in the feed — can't read the original to restore it"
    else
        new_maxt=$((orig_maxt + 1))
        it_step "Worker Inspect edit: max_temp_c $orig_maxt -> $new_maxt via /api/control/worker-apply…"
        rig_key_mark dash "$rig" max_temp_c "$orig_maxt" # abort-safe unwind (#1379)
        res="$(_worker_apply "$rig" "{\"max_temp_c\":$new_maxt}")"
        IFS='|' read -r status ckeys change_id <<<"$(_settle_worker_apply_maxt "$rig" "$new_maxt" "$res")"
        assert_eq "Worker Inspect edit applied on the rig (#513)" "$status" "applied"
        assert_contains "the rig's /status confirms max_temp_c changed (#513)" "$ckeys" "max_temp_c"
        # By change_id, not "the newest row", and WAITED to terminal: the rig publishes its config
        # before it decides the outcome, so reading the row straight after the settle raced it (#1471).
        assert_eq "worker-apply recorded in the per-worker history (#185/#1471)" "$(_settle_history_row "$rig" "$change_id")" "applied"
        it_step "reverting max_temp_c $new_maxt -> ${orig_maxt}…"
        res="$(_worker_apply "$rig" "{\"max_temp_c\":$orig_maxt}")"
        IFS='|' read -r status _ _ <<<"$(_settle_worker_apply_maxt "$rig" "$orig_maxt" "$res")"
        assert_eq "reversible edit reverted on the rig (#513)" "$status" "applied"
        [ "$status" = "applied" ] && rig_key_clear dash "$rig" max_temp_c # (#1379)
    fi

    # Lives in rigforge-writable-keys.sh: the legs read each original from the rig's OWN reported
    # config (.rig_config, #1235/rigforge#253) rather than from a record of what we last pushed, and
    # the three keys not driven there carry their reasons with them.
    run_rigforge_writable_keys "$rig"
    run_rigforge_pools "$rig"

    run_rigforge_reverse "$rig" "$orig_maxt"

    run_rigforge_rollback "$rig"

    [ -n "$RIGFORGE_BOOTSTRAP_VERSION" ] || run_rigforge_upgrade "$rig"

    control_rc=$((IT_FAIL > fails_before))
    [ "$control_rc" = 0 ] || capture_artifacts "rigforge-control" "$OUT_DIR"
    # Restore: baseline config drops the injected descriptor + turns control back off (the end-of-run
    # restore_baseline would too; doing it here keeps the box clean even if a later phase is added).
    it_step "restoring baseline (control off, descriptor dropped)…"
    _restore_rig_control_baseline && return "$control_rc"
}

# Predicate: the rig is present in the live feed with its enriched block parsed.
