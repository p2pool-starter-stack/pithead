# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
_pred_rig_present() { # <rig-name>
    local s
    s="$(api_state)"
    [ -n "$s" ] || return 1
    [ -n "$(printf '%s' "$s" | jq -r --arg n "$1" 'first(.workers[]? | select(.name==$n and .rigforge.version != null) | .name) // empty' 2>/dev/null)" ]
}

# #516: a rig-side config edit (made OUTSIDE the dashboard) must reflect in the dashboard's enriched
# feed, and render_masked_config's claim — that config.json hand-edits show up in the editor prefill —
# must hold with the per-worker token masked. The feed leg dials the rig's control API DIRECTLY from
# the bench (bypassing the dashboard's worker-apply), which needs the raw token, so it self-skips
# without IT_RIG_TOKEN; the prefill leg is bench-only and always runs.
run_rigforge_reverse() { # <rig-name> <orig-max_temp_c-or-empty>
    local rig="$1" orig_maxt="$2" cdir masked
    it_log "   #516: rig-side edit reflects in the dashboard"

    # Prefill leg (always runs): the masked prefill copy (#440) must carry the descriptor host and
    # mask the token to the sentinel — the exact surface #508 broke. render_masked_config re-runs on
    # every apply, so a hand-edit to config.json shows up in the editor form. Reads and the watts
    # write below resolve workers.list[] alone: the dashboard.workers[] fallback was removed in 2.0.0
    # (#1832), and the apply above has already migrated a pre-2.0 baseline into workers.list[].
    cdir="$(env_on_box CONTROL_DIR)"
    if [ -n "$cdir" ]; then
        masked="$(rx "cat $(quote_arg "$cdir/masked/config.json") 2>/dev/null")"
        assert_ne "masked prefill carries the rig descriptor host (#516/#440)" \
            "$(printf '%s' "$masked" | jq -r --arg n "$rig" 'first((.workers.list // [])[] | select(.name==$n) | .host) // empty' 2>/dev/null)" ""
        assert_eq "masked prefill masks the per-worker token to the sentinel (#516/#440)" \
            "$(printf '%s' "$masked" | jq -r --arg n "$rig" 'first((.workers.list // [])[] | select(.name==$n) | .token."__secret__") // empty' 2>/dev/null)" "true"
        # A benign hand-edit to config.json must surface in the freshly re-rendered prefill (#516).
        local probe_watts=123
        push_config "$(printf '%s' "$(rx 'cat config.json')" | jq --arg n "$rig" --argjson w "$probe_watts" \
            '(.workers.list[] | select(.name==$n) | .watts) = $w')"
        pithead apply -y >/dev/null 2>&1 || true
        assert_eq "config.json hand-edit shows up in the masked prefill (#516 render_masked_config claim)" \
            "$(rx "cat $(quote_arg "$cdir/masked/config.json") 2>/dev/null" | jq -r --arg n "$rig" 'first((.workers.list // [])[] | select(.name==$n) | .watts) // empty' 2>/dev/null)" "$probe_watts"
    else
        it_skip_leg "masked prefill (#516)" "CONTROL_DIR not set"
    fi

    # Feed leg (needs the raw token to dial the rig directly): change max_temp_c ON the rig via its
    # own control API, then assert the dashboard's enriched feed reflects it — the rig->dashboard
    # direction, independent of the dashboard write path.
    if [ -z "${IT_RIG_TOKEN:-}" ] || [ -z "$RIG_HOST" ]; then
        it_skip_leg "enriched-feed reflection (#516)" "no IT_RIG_TOKEN + --rig-host to dial the rig directly"
        return 0
    fi
    if [ -z "$orig_maxt" ]; then
        it_skip_leg "enriched-feed reflection (#516)" "rig watchdog max_temp_c not visible in the feed"
        return 0
    fi
    local reflect=$((orig_maxt + 2)) change_id
    it_step "rig-side edit (direct control API): max_temp_c -> $reflect on $RIG_HOST:${RIG_CONTROL_PORT}…"
    rig_key_mark rig "$rig" max_temp_c "$orig_maxt" # abort-safe unwind, rig route (#1379)
    change_id="$(_rig_control_apply "{\"max_temp_c\":$reflect}")"
    if [ -z "$change_id" ]; then
        it_fail "direct rig control apply accepted (#516)" "the rig's /apply did not return a change_id"
    else
        _rig_control_await "$change_id" applied || it_warn "rig didn't report the direct change applied in time (#516)"
        if wait_for 90 5 "dashboard feed to reflect the rig-side max_temp_c=$reflect (#516)" _pred_feed_maxt "$rig" "$reflect"; then
            it_pass "rig-side edit reflected in the dashboard's enriched feed (#516)"
        else
            it_fail "rig-side edit reflected in the dashboard's enriched feed (#516)" "feed never showed max_temp_c=$reflect"
        fi
        # Revert the rig to its original ceiling.
        change_id="$(_rig_control_apply "{\"max_temp_c\":$orig_maxt}")"
        { [ -n "$change_id" ] && _rig_control_await "$change_id" applied &&
            rig_key_clear rig "$rig" max_temp_c; } || true # retire only on a confirmed revert (#1379)
    fi
}

# POST a change straight to the rig's control API from the bench (the same dial the host runner makes,
# minus the dashboard) and echo the rig's change_id. Needs IT_RIG_TOKEN + RIG_HOST. Used only by #516.
_rig_control_apply() { # <changes-json> -> echoes change_id
    printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "${IT_RIG_TOKEN:-}" | jq -Rs .)" | rx "curl -fsS --max-time 15 -K - -X POST -H 'Content-Type: application/json' --data $(quote_arg "$1") $(quote_arg "http://$RIG_HOST:$RIG_CONTROL_PORT/apply")" --stdin 2>/dev/null | jq -r '.change_id // empty' 2>/dev/null
}

# Poll the rig's /status for <change_id> reaching <want-status>. Returns 0 on match within the window.
_rig_control_await() { # <change_id> <want-status> [timeout-s=30]
    local id="$1" want="$2" deadline=$((SECONDS + ${3:-30})) sbody
    while [ "$SECONDS" -lt "$deadline" ]; do
        sbody="$(printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "${IT_RIG_TOKEN:-}" | jq -Rs .)" | rx "curl -fsS --max-time 10 -K - $(quote_arg "http://$RIG_HOST:$RIG_CONTROL_PORT/status")" --stdin 2>/dev/null)"
        if [ "$(printf '%s' "$sbody" | jq -r '.change_id // empty' 2>/dev/null)" = "$id" ] &&
            [ "$(printf '%s' "$sbody" | jq -r '.status // empty' 2>/dev/null)" = "$want" ]; then
            return 0
        fi
        sleep 3
    done
    return 1
}

# Predicate: the dashboard feed's watchdog Temp/max stat shows <want> as the ceiling for <rig>.
_pred_feed_maxt() { # <rig-name> <want-max_temp_c>
    local s v
    s="$(api_state)"
    [ -n "$s" ] || return 1
    v="$(printf '%s' "$s" | jq -r --arg n "$1" 'first(.workers[]? | select(.name==$n) | .rigforge.stats[]? | select(.label=="Temp / max") | .value) // empty' 2>/dev/null | sed -n 's#.*/ *\([0-9][0-9]*\).*#\1#p')"
    [ "$v" = "$2" ]
}

# #517: an auto-rollback (rigforge#236) recorded end-to-end from the dashboard. A change that tanks the
# rig's hashrate makes the rig revert and report `rolled_back`; the dashboard's worker-apply result +
# per-worker history must show it (not `applied`). Inducing a real hashrate drop is rig-specific and
# risky to guess, so the operator supplies the known-rolls-back change as IT_RIG_ROLLBACK_CHANGES (a
# JSON `changes` object their rig / fault-injection reverts). Without it, this self-skips loudly.
run_rigforge_rollback() { # <rig-name>
    local rig="$1" res status
    it_log "   #517: control-apply auto-rollback (rigforge#236)"
    if [ -z "${IT_RIG_ROLLBACK_CHANGES:-}" ]; then
        it_skip_leg "control-apply auto-rollback (#517)" "no IT_RIG_ROLLBACK_CHANGES (a writable-key change the rig's fault-injection rolls back)"
        return 0
    fi
    if ! printf '%s' "$IT_RIG_ROLLBACK_CHANGES" | jq -e 'type == "object"' >/dev/null 2>&1; then
        it_fail "IT_RIG_ROLLBACK_CHANGES is a JSON changes object (#517)" "got [$IT_RIG_ROLLBACK_CHANGES]"
        return 0
    fi
    it_step "applying the rollback-inducing change via /api/control/worker-apply…"
    res="$(_worker_apply "$rig" "$IT_RIG_ROLLBACK_CHANGES")"
    status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null)"
    # The rig's rollback (miner restart + up to CONTROL_LIVE_TRIES health polls) can outrun the host
    # runner's 20s status-poll deadline on a slow rig, so worker-apply honestly returns the non-terminal
    # "accepted" ("queued on the rig; outcome not yet observed") with the change_id — not a failure.
    # Poll the rig directly for THAT change_id's terminal rollback (same direct-dial creds as #516;
    # without them, keep the strict synchronous check).
    if [ "$status" = "accepted" ] && [ -n "$RIG_HOST" ] && [ -n "${IT_RIG_TOKEN:-}" ]; then
        local cid
        cid="$(printf '%s' "$res" | jq -r '.change_id // empty' 2>/dev/null)"
        if [ -n "$cid" ]; then
            it_step "worker-apply returned accepted (runner deadline < rollback time) — polling the rig for change $cid to reach rolled_back…"
            _rig_control_await "$cid" rolled_back 240 && status=rolled_back
        fi
    fi
    assert_eq "rig auto-rolled-back the bad change (rigforge#236, #517)" "$status" "rolled_back"
    # The dashboard records the worker-apply outcome (#185): "rolled_back" when the runner caught the
    # terminal, or the honest "accepted (pending)" when the rollback outran its poll deadline — either
    # confirms the change was driven end-to-end from the dashboard (the rig-side terminal is asserted
    # above). ponytail: accept both rather than force a product change to the runner's poll budget.
    local histstatus
    histstatus="$(_worker_detail "$rig" | jq -r 'first(.history[]?) | .status // empty' 2>/dev/null)"
    case "$histstatus" in
    rolled_back | accepted) it_pass "the dashboard's per-worker history records the change (#517: $histstatus)" ;;
    *) it_fail "the dashboard's per-worker history records the change (#517)" "expected rolled_back|accepted, got [$histstatus]" ;;
    esac
}
