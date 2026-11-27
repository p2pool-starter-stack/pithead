# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
_pred_rig_present() { # <rig-name>
    local s rc=0
    s="$(api_state)" || rc=$?
    # Correlate normalized warning identities in memory only; never persist this raw poll.
    _RIG_SETUP_STATE="$s"
    # Keep only typed, allowlisted observations from this exact poll, never a raw worker/name.
    _RIG_SETUP_SAMPLE="$(printf '%s' "$s" | jq -Rsc --arg n "$1" --argjson rc "$rc" \
        --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        def bool: if type == "boolean" then . else null end;
        (try fromjson catch null) as $s |
        (if ($s | type) == "object" and ($s.workers | type) == "array"
         then first($s.workers[] | objects | select(.name == $n)) // null else null end) as $w |
        {sampled_utc:$utc, state_transport_exit:$rc,
         state_valid:(($s | type) == "object" and ($s.workers | type) == "array"),
         worker_found:($w != null),
         status:($w.status | if . == "online" or . == "offline" then . else null end),
         api_ok:($w.api_ok | bool), adopted:($w.adopted | bool),
         rigforge_present:(($w.rigforge | type) == "object"),
         version_present:($w.rigforge.version != null), stale:($w.rigforge.stale | bool),
         generated_at:($w.rigforge.generated_at | if type == "string" then
             if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then . else null end
             else null end)}' 2>/dev/null)" || _RIG_SETUP_SAMPLE='{"state_valid":false}'
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
    rig_key_mark rig "$rig" max_temp_c "$orig_maxt" || { # abort-safe unwind, rig route (#1379)
        it_skip_leg "enriched-feed reflection (#516)" "the original max_temp_c cannot be recorded for the abort-safe unwind, so no write is sent (#2668)"
        return 0
    }
    change_id="$(_rig_control_apply "{\"max_temp_c\":$reflect}")"
    if [ -z "$change_id" ]; then
        it_fail "direct rig control apply accepted (#516)" "the rig's /apply did not return a change_id"
    else
        _rig_control_await "$change_id" applied || it_warn "rig didn't report the direct change applied in time (#516)"
        if wait_for 90 5 "dashboard feed to reflect the rig-side max_temp_c=$reflect (#516)" _pred_feed_maxt "$rig" "$reflect"; then
            it_pass "rig-side edit reflected in the dashboard's enriched feed (#516)"
        else
            it_fail "rig-side edit reflected in the dashboard's enriched feed (#516)" "$(_reverse_feed_failure_detail "$reflect")"
        fi
        # Revert the rig to its original ceiling.
        change_id="$(_rig_control_apply "{\"max_temp_c\":$orig_maxt}")"
        { [ -n "$change_id" ] && _rig_control_await "$change_id" applied &&
            rig_key_clear rig "$rig" max_temp_c; } || true # retire only on a confirmed revert (#1379)
    fi
}

# POST straight to the rig's control API from the bench (the host runner's dial, minus the dashboard); used only by #516.
_rig_control_apply() { # <changes-json> -> only a validated change_id on stdout
    local config script result id diagnostic started
    config="$(printf '%s' "$1" | jq -er 'if type == "object" then tojson | @json else error("changes") end')" || return 1
    printf -v config 'header = %s\ndata-binary = %s' "$(printf 'Authorization: Bearer %s' "${IT_RIG_TOKEN:-}" | jq -Rs .)" "$config"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Execute capture where curl runs. Only the constrained envelope crosses rx;
    # credentials stay on stdin, and raw response bytes never enter the transcript.
    script="$(
        cat <<'CAPTURE'
set -uo pipefail
umask 077
d="$(mktemp -d)" || exit 1
trap 'rm -rf "$d"' EXIT
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The file-size limit also bounds chunked responses on older curl versions.
# No retry: even a transport error may follow a staged POST.
http="$( (ulimit -c 0; ulimit -f 16 || exit 1
    curl -q -sS --max-time 15 --max-filesize 16384 -K - -X POST \
        -H 'Content-Type: application/json' -o "$d/body" -w '%{http_code}' "$1"
) 2>/dev/null)"
rc=$?
[[ "$http" =~ ^[0-9]{3}$ ]] || http=000
id='' status=absent
if [ "$rc" -ne 0 ]; then
    classification=transport-failure
elif [[ ! "$http" =~ ^2[0-9]{2}$ ]]; then
    classification=http-refusal
elif [ ! -s "$d/body" ]; then
    classification=empty-body
elif ! jq -cs . "$d/body" >"$d/json" 2>/dev/null; then
    classification=invalid-json
elif [ "$(jq 'length' "$d/json")" = 0 ]; then
    classification=empty-body
else
    # Exactly one object; no coercion, multiline IDs or arbitrary response text.
    id="$(jq -r 'if length == 1 and (.[0] | type) == "object" then
        .[0].change_id | select(type == "string") |
        select(length == 16 and test("^[0-9a-f]{16}$")) else empty end' "$d/json" 2>/dev/null)"
    status="$(jq -r 'if length == 1 and (.[0] | type) == "object" then
        .[0].status | select(. == "accepted" or . == "applied" or . == "rejected" or
        . == "failed" or . == "rolled_back" or . == "noop") else empty end' "$d/json" 2>/dev/null)"
    status="${status:-absent}"
    classification=missing-valid-id
    [ -z "$id" ] || classification=success
fi
jq -cn --arg request_utc "$stamp" --arg http_status "$http" --arg curl_exit "$rc" \
    --arg classification "$classification" --arg change_id "$id" --arg response_status "$status" \
    '$ARGS.named'
CAPTURE
    )"
    result="$(printf '%s\n' "$config" | rx "bash -c $(quote_arg "$script") -- $(quote_arg "http://$RIG_HOST:$RIG_CONTROL_PORT/apply")" --stdin 2>/dev/null)" || result=''
    id="$(printf '%s' "$result" | jq -er 'select(.classification == "success" and .curl_exit == "0") |
        select(.http_status | test("^2[0-9]{2}$")) | .change_id |
        select(type == "string") | select(length == 16 and test("^[0-9a-f]{16}$"))' 2>/dev/null)" || id=''
    if [ -n "$id" ]; then
        printf '%s\n' "$id"
        return 0
    fi
    diagnostic="$(printf '%s' "$result" | jq -er '
        select(.request_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) |
        select(.http_status | test("^[0-9]{3}$")) |
        select(.curl_exit | test("^[0-9]{1,3}$")) |
        select(.classification == "http-refusal" or .classification == "transport-failure" or
            .classification == "empty-body" or .classification == "invalid-json" or .classification == "missing-valid-id") |
        select(.response_status == "absent" or .response_status == "accepted" or .response_status == "applied" or
            .response_status == "rejected" or .response_status == "failed" or .response_status == "rolled_back" or .response_status == "noop") |
        "request_utc=\(.request_utc) http_status=\(.http_status) curl_exit=\(.curl_exit) classification=\(.classification) response_status=\(.response_status)"' 2>/dev/null)" || diagnostic="request_utc=$started http_status=000 curl_exit=unknown classification=transport-failure response_status=absent"
    it_log "direct rig control apply diagnostic: $diagnostic" >&2
    # Preserve the caller's direct acceptance assertion even under errexit.
    return 0
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
# _FEED_MAXT_SEEN keeps the rig's status, report freshness and temperature rows from the last poll so a
# timeout names what the feed showed: a stale report, a missing temperature, or the old ceiling (#2741).
_pred_feed_maxt() { # <rig-name> <want-max_temp_c>
    local s v
    _FEED_MAXT_SEEN="no response from /api/state"
    s="$(api_state)"
    [ -n "$s" ] || return 1
    _FEED_MAXT_SEEN="$(printf '%s' "$s" | jq -r --arg n "$1" '[.workers[]? | select(.name==$n)][0] | if . == null then "rig not in the feed" else "status=\(.status // "?"), stats: " + ([.rigforge.stats[]? | select(.label == "Agent report" or .label == "Temp / max") | "\(.label)=\(.value)"] | join("; ")) end' 2>/dev/null)" ||
        _FEED_MAXT_SEEN=""
    [ -n "$_FEED_MAXT_SEEN" ] || _FEED_MAXT_SEEN="unparseable /api/state"
    v="$(printf '%s' "$s" | jq -r --arg n "$1" 'first(.workers[]? | select(.name==$n) | .rigforge.stats[]? | select(.label=="Temp / max") | .value) // empty' 2>/dev/null | sed -n 's#.*/ *\([0-9][0-9]*\).*#\1#p')"
    [ "$v" = "$2" ]
}

# The rig's own enriched feed, read straight from the bench (the dashboard bypassed): its generation stamp
# and watchdog ceiling, or why the read failed. No curl stderr is kept: it names the rig's address (#2741).
_rig_direct_summary() {
    local body
    body="$(printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "${IT_RIG_TOKEN:-}" | jq -Rs .)" | rx "curl -fsS --max-time 10 -K - $(quote_arg "http://$RIG_HOST:8081/1/summary")" --stdin 2>/dev/null)" ||
        {
            echo "direct /1/summary read failed"
            return 0
        }
    [ -n "$body" ] || {
        echo "direct /1/summary returned an empty body"
        return 0
    }
    printf '%s' "$body" | jq -r '"generated_at=\(.generated_at // "absent"), watchdog max_temp_c=\(.rigforge.watchdog.max_temp_c // "absent")"' 2>/dev/null ||
        echo "direct /1/summary unparseable"
}

# The #516 failure detail, taken before the rig is reverted.
_reverse_feed_failure_detail() { # <wanted-max_temp_c>
    printf 'feed never showed max_temp_c=%s; last poll: %s; rig direct: %s' "$1" "${_FEED_MAXT_SEEN:-}" "$(_rig_direct_summary)"
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
        it_fail "IT_RIG_ROLLBACK_CHANGES is a JSON changes object (#517)" "the operator-supplied rollback changes are malformed"
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
