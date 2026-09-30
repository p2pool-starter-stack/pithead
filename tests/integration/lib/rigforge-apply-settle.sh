# shellcheck shell=bash
#
# Settle a dashboard-mediated RigForge worker-apply intent past its dial-time "accepted" (#1309).
#
# RigForge #344: the rig now answers "accepted" immediately and applies async. pithead's own host
# runner (control_worker_apply in the `pithead` CLI) caps its post-dial /status poll at 20s and,
# past that, writes an "accepted … outcome not yet observed" result verbatim — its own words: "the
# container can keep polling the rig via the next read." That next read is the dashboard's regular
# per-rig poll (data_service.py's run loop), which on the SAME poll tick both:
#   (a) refreshes the enriched feed's live watchdog value (served at /api/state, read by
#       _pred_feed_maxt in run.sh), and
#   (b) reconciles a still-"accepted" #185 worker-config history row to its real terminal status
#       (worker_config_store.py:reconcile_worker_config_status, #579/#604) — step 3a in that poll,
#       strictly BEFORE the enriched-feed merge at step 3b.
# So observing the feed converge to the requested max_temp_c is proof the requested key (the only
# key in a max_temp_c change) is what changed — no direct rig dial needed (IT_RIG_TOKEN/RIG_HOST
# bench flags aren't always set: the live-box case uses the baseline's own workers.list[]
# descriptor without them), and no reliance on the dial-time result ever changing.
#
# ⛔ WHAT IT DOES NOT PROVE, AND THIS MODULE USED TO CLAIM IT DID (#1471): that the #185 history
# row for that change_id is terminal by the time a caller reads it back. The (a)/(b) ordering
# above is real — 3a does run before 3b, and both surfaces come off one poll — but both are
# downstream of a rig file written BEFORE the rig has decided the outcome at all. RigForge commits
# the new config at the START of a control-apply (_control_commit's `mv -f`) and writes the
# terminal status.json only at the END, after the apply, an xmrig restart and a `_wait_miner_live`
# bounded at 20 tries x 3s; the reconciler cannot move the row off "accepted" until it has read
# that second file, which costs up to one further UPDATE_INTERVAL. A settle on the readback
# surface therefore ends at the START of that gap, not after it. The claim survived because two of
# the three keys that reach the row, max_temp_c and watchdog_interval_min, are on RigForge's
# restart-free fast path (CONTROL_FAST_PATH_KEYS, rigforge.sh:4203 at v1.16.0), where the gap is
# too small to see. DONATION and pools take the full path; their config readback is not proof
# that the rig has published a terminal outcome or that the dashboard has consumed it.
# Callers asserting on the row go through _settle_history_row below, which waits for it.
# Fails loudly (leaves status/ckeys at their dial-time "accepted"/empty) on a real
# rejected/failed/timeout, exactly like a "the change never actually happened" bug would.
#
# Sourced by run.sh, which supplies wait_for (lib.sh) and the readback predicates. Fields are
# '|'-joined, not tab — `read` with IFS=tab (an IFS-whitespace character) SQUASHES an empty
# middle field instead of preserving it, misaligning every field after it; '|' can't appear in
# any of the three values, so it splits correctly even when ckeys/change_id come back empty.

# The settle itself, generic over WHAT is watched. The wrapper is identical for every writable key
# — parse the dial result, and if it is the non-terminal "accepted", wait for the rig to actually
# report the change before calling it applied. Only the readback surface differs, so that arrives as
# a predicate: max_temp_c has live telemetry in the enriched feed's watchdog stats (the only
# writable key that does), while the keys added by #1236 read the rig's own reported config. Both
# ride the same per-rig poll tick, so the readback half of the reasoning above holds either way —
# and neither of them says anything about the history row, which is why that has its own settle.
_settle_worker_apply() { # <ckeys-on-success> <wait-desc> <dial-result-json> <predicate-cmd...>
    local key="$1" desc="$2" res="$3" status ckeys change_id
    shift 3
    status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null)"
    ckeys="$(printf '%s' "$res" | jq -r '(.changed_keys // []) | join(",")' 2>/dev/null)"
    change_id="$(printf '%s' "$res" | jq -r '.change_id // empty' 2>/dev/null)"
    # `>&2` is load-bearing (#1454). This function's stdout IS its return value — every call site
    # captures it with `$(...)` and splits it with `IFS='|' read` — and wait_for opens with an
    # it_step banner, which goes to STDOUT. Without the redirection that banner is the FIRST line of
    # the capture, `read` takes it as $status, ckeys and change_id come back empty, and all three
    # of the caller's assertions red whatever the rig did. It fires only on a settle that actually
    # waits, i.e. exactly the RigForge #344 path this module exists for. stderr is where wait_for's
    # own "timed out after Ns" warning already goes, and e2e.sh merges both into the harness log.
    if [ "$status" = "accepted" ] && wait_for 90 5 "$desc (change_id=$change_id)" "$@" >&2; then
        status="applied"
        ckeys="$key"
    fi
    printf '%s|%s|%s' "$status" "$ckeys" "$change_id"
}

_settle_worker_apply_maxt() { # <rig> <want-max_temp_c> <dial-result-json> -> "<status>|<ckeys>|<change_id>"
    _settle_worker_apply max_temp_c \
        "the rig to report max_temp_c=$2 applied (RigForge #344 async apply, #1309)" \
        "$3" _pred_feed_maxt "$1" "$2"
}

# One #185 history row, by change_id and never "the newest row" (#579/#604's reconciler keys on
# the id, and a concurrent change would otherwise be read as this one's outcome).
#
# `_worker_detail` is the caller's, exactly like the readback predicates above: it is defined in
# rigforge-writable-keys.sh and is in scope for every caller by the time these run, because run.sh
# sources both modules before any leg executes.
_history_row_status() { # <rig> <change_id> -> that row's status, or empty when there is no row
    _worker_detail "$1" | jq -r --arg c "$2" \
        'first(.history[]? | select(.change_id == $c)) | .status // empty' 2>/dev/null
}

# Terminal is stated as the COMPLEMENT of the non-terminal pair, not as an allowlist of #1009's
# six names, and the direction matters: a status this harness has never seen must read as terminal
# and let the caller's assert_eq name it. An allowlist would turn a newly added rig status into a
# 90s timeout reported as "the row never settled" — the wrong diagnosis, and one that costs the
# full bound to reach. Empty is non-terminal because there is no row yet, not because it is stuck.
# Bounded scalar-only observations support tracing a stale publication/consumption hop (#2761).
# Never print config, reasons, host names or arbitrary producer strings: pools carry credentials.
_history_handoff_sample() { # <change_id> <detail-json> [rig]
    local id="$1" detail="$2" feed='{}' outcome='{}' direct_poll=unavailable status_poll=unavailable auth fields collector
    [[ "$id" =~ ^[0-9a-f]{16}$ ]] || return 0
    if [ -n "${IT_RIG_TOKEN:-}" ] && [ -n "${RIG_HOST:-}" ]; then
        auth="$(printf 'Authorization: Bearer %s' "$IT_RIG_TOKEN" | jq -Rs .)"
        direct_poll=failed
        if feed="$(printf 'header = %s\n' "$auth" | rx "curl -q -fsS --max-time 3 -K - $(quote_arg "http://$RIG_HOST:8081/1/summary")" --stdin 2>/dev/null)"; then
            direct_poll=ok
        fi
        status_poll=failed
        if outcome="$(printf 'header = %s\n' "$auth" | rx "curl -q -fsS --max-time 3 -K - $(quote_arg "http://$RIG_HOST:$RIG_CONTROL_PORT/status?change_id=$id")" --stdin 2>/dev/null)"; then
            status_poll=ok
        fi
    fi
    # Parse separately so a failed/malformed response cannot hide the other side's observation.
    fields='def stamp: if type != "string" then "invalid_or_absent" elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then . else "invalid_or_absent" end;
        def status: if . == null then "absent" elif IN("accepted","pending","started","running","applied","rejected","rolled_back","failed","noop","throttled") then . else "unrecognized" end;
        def exact($rows): (first($rows[]? | select(.change_id == $id) | .status) // null) | status;
        if length == 1 and (.[0] | type) == "object" then .[0] else error("invalid response") end |'
    detail="$(printf '%s' "$detail" | jq -sc --arg id "$id" "$fields"'
        {history:exact(.history),feed_at:(.rigforge.generated_at | stamp),
         stale:(if (.rigforge.stale | type) == "boolean" then .rigforge.stale else "invalid_or_absent" end),
         snapshot_at:(if (.snapshot_at | type) == "number" then .snapshot_at else null end),
         worker_status:(if (.status | IN("online","offline","down")) then .status else "unrecognized" end)}' 2>/dev/null)" || detail='{"poll":"invalid_or_failed"}'
    feed="$(printf '%s' "$feed" | jq -sc --arg id "$id" "$fields"'
        {feed_at:(.generated_at | stamp),history:exact(.rigforge.control_history),
         current:(if .rigforge.control.change_id == $id then .rigforge.control.status | status else "absent" end)}' 2>/dev/null)" || feed='{"poll":"invalid_or_failed"}'
    collector="$(api_state | jq -sc --arg id "$id" --arg rig "${3:-}" "$fields"'
        first(.workers[]? | select(.name == $rig)) // {} |
        {api_ok:(if (.api_ok | type) == "boolean" then .api_ok else "unavailable" end),
         feed_at:(.rigforge.generated_at | stamp)}' 2>/dev/null)" || collector='{"poll":"invalid_or_failed"}'
    [ -n "$collector" ] || collector='{"poll":"invalid_or_failed"}'
    outcome="$(printf '%s' "$outcome" | jq -sc --arg id "$id" "$fields"'
        {status:(if .change_id == $id then .status | status else "absent" end)}' 2>/dev/null)" || outcome='{"poll":"invalid_or_failed"}'
    [ -n "$detail" ] || detail='{"poll":"invalid_or_failed"}'
    [ -n "$feed" ] || feed='{"poll":"invalid_or_failed"}'
    [ -n "$outcome" ] || outcome='{"poll":"invalid_or_failed"}'
    jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg id "$id" \
        --arg direct_poll "$direct_poll" --arg status_poll "$status_poll" \
        --argjson dashboard "$detail" --argjson direct "$feed" --argjson outcome "$outcome" --argjson collector "$collector" \
        '{history_handoff:{at:$at,change_id:$id,dashboard:$dashboard,direct_poll:$direct_poll,direct:$direct,status_poll:$status_poll,outcome:$outcome,collector:$collector}}' >&2
}

_pred_history_row_terminal() { # <rig> <change_id>
    local detail status
    if [ -n "${_HISTORY_DEADLINE:-}" ] && [ "$(now_s)" -gt "$_HISTORY_DEADLINE" ]; then return 1; fi
    detail="$(_worker_detail "$1")"
    if [ -n "${_HISTORY_DEADLINE:-}" ] && [ "$(now_s)" -gt "$_HISTORY_DEADLINE" ]; then return 1; fi
    status="$(printf '%s' "$detail" | jq -r --arg c "$2" 'first(.history[]? | select(.change_id == $c)) | .status // empty' 2>/dev/null)"
    _HISTORY_ROW_STATUS="$status"
    if [ "${_HISTORY_SAMPLE_COUNT:-20}" -lt 20 ]; then
        _HISTORY_SAMPLE_COUNT=$((_HISTORY_SAMPLE_COUNT + 1))
        _history_handoff_sample "$2" "$detail" "$1"
    fi
    case "$status" in
    "" | accepted) return 1 ;;
    *) return 0 ;;
    esac
}

# Wait that row to terminal, then report it (#1471). Waiting for TERMINAL rather than for
# "applied" is what keeps the caller's assertion honest in both directions: a rig that genuinely
# rejected or failed the change publishes a terminal row at once, so this returns that status and
# the caller reds immediately instead of burning the bound on a verdict already known; a row that
# never settles stays "accepted" and reds too. The one answer it must never invent is "applied"
# for a row nobody has confirmed — which is what reading the row unwaited did, across a window of
# the rig apply and the next dashboard poll. The 90s assertion remains a bounded check;
# exact-ID samples correlate publication/consumption delays from an unfinished rig apply.
#
# The `>&2` is this module's #1454 discipline, for the same reason: stdout is the return value and
# wait_for opens with an it_step banner on stdout. Cache the history observation before the
# diagnostic reads: those may finish after the deadline, but cannot change the verdict. Never
# perform a fresh result read after timeout, which could falsely pass a later convergence.
_settle_history_row() { # <rig> <change_id> -> the last status observed within the 90s budget
    local _HISTORY_SAMPLE_COUNT=0 _HISTORY_ROW_STATUS="" _HISTORY_DEADLINE
    _HISTORY_DEADLINE=$(($(now_s) + 90))
    wait_for 90 5 "the #185 history row for $2 to reach a terminal status (#1471)" \
        _pred_history_row_terminal "$1" "$2" >&2
    printf '%s' "$_HISTORY_ROW_STATUS"
}
