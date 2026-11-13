# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
_monerod_started_after_tor() { # <label>
    local tor_at monerod_at
    tor_at="$(rx "docker inspect tor --format '{{.State.StartedAt}}'")"
    monerod_at="$(rx "docker inspect monerod --format '{{.State.StartedAt}}'")"
    if [[ "$monerod_at" > "$tor_at" ]]; then
        it_pass "$1"
    else
        it_fail "$1" "monerod started $monerod_at, tor started $tor_at"
    fi
}

_hardening_stack_action_rows() { # <control-dir>
    local cdir="$1"
    local rst_id tor_started_before tor_reset_id tor_reset_result st
    rst_id="$(_uuid4)"
    _spool_write "$cdir/requests/$rst_id.json" "$(jq -nc --arg id "$rst_id" '{id:$id,action:"restart",actor:"itest"}')"
    st="$(_wait_control_status "$cdir" "$rst_id" "" 600 || echo timeout)"
    assert_eq "dashboard Restart all verb restarts the whole stack through the control runner (#4064)" "$st" "applied"
    wait_status_ok 240 || true
    pithead status >/dev/null 2>&1
    assert_rc "stack healthy after Restart all (#4064)" "$?" "0"
    assert_contains "Restart all audited with actor, action and status (#4064)" \
        "$(rx "cat $(quote_arg "$cdir/audit/control.log") 2>/dev/null")" '"actor":"itest","action":"restart","status":"applied"'
    _monerod_started_after_tor "after Restart all monerod is re-dialled: restarted after tor (#4064)"
    tor_started_before="$(rx "docker inspect tor --format '{{.State.StartedAt}}'")"
    tor_reset_id="$(_uuid4)"
    _spool_write "$cdir/requests/$tor_reset_id.json" "$(jq -nc --arg id "$tor_reset_id" '{id:$id,action:"tor-reset",actor:"itest"}')"
    st="$(_wait_control_status "$cdir" "$tor_reset_id" "" 300 || echo timeout)"
    tor_reset_result="$(rx "cat $(quote_arg "$cdir/results/$tor_reset_id.json") 2>/dev/null")"
    case "$st" in
    rejected | failed) it_pass "a healthy Tor refuses the dashboard Tor state reset (#4063) [$st]" ;;
    *) it_fail "a healthy Tor refuses the dashboard Tor state reset (#4063)" "status=$st (expected rejected or failed)" ;;
    esac
    assert_eq "the refusal carries the gate's reason (#4063)" \
        "$(printf '%s' "$tor_reset_result" | jq -r '(.error // "") | length > 0')" "true"
    assert_eq "a refused reset leaves Tor running untouched (#4063)" \
        "$(rx "docker inspect tor --format '{{.State.StartedAt}}'")" "$tor_started_before"
    assert_contains "Tor reset audited with actor, action and status (#4063)" \
        "$(rx "cat $(quote_arg "$cdir/audit/control.log") 2>/dev/null")" '"actor":"itest","action":"tor-reset"'
}
