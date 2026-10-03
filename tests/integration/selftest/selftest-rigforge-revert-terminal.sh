#!/usr/bin/env bash
# Config converges before a revert finishes; later edits must respect its exact terminal row.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/rigforge-apply-settle.sh
source "$HERE/../lib/rigforge-apply-settle.sh"
# shellcheck source=tests/integration/lib/rigforge-writable-keys.sh
source "$HERE/../lib/rigforge-writable-keys.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-rig-control.sh
source "$HERE/../lib/run-rig-control.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rig_key_mark() { echo mark >>"$TMP/ledger"; }
rig_key_clear() { echo clear >>"$TMP/ledger"; }
_worker_apply() {
    echo "$2" >>"$TMP/applies"
    if [ "$(wc -l <"$TMP/applies")" -eq 3 ] && [ ! -e "$TMP/terminal" ]; then
        echo premature >>"$TMP/ledger"
    fi
    printf '{"status":"accepted","change_id":"%016d"}' "$(wc -l <"$TMP/applies")"
}
_worker_detail() {
    local n ticks=0 row=applied config
    n="$(wc -l <"$TMP/applies")"
    config="$(tail -1 "$TMP/applies")"
    if [ "$n" -eq 2 ]; then
        ticks="$(cat "$TMP/ticks")"
        echo "$((ticks + 1))" >"$TMP/ticks"
        row=accepted
        if [ "$ticks" -ge 2 ]; then
            row="$OUTCOME"
            case "$row" in '' | accepted) ;; *) touch "$TMP/terminal" ;; esac
        fi
    fi
    # The newer applied row must not mask the exact revert row's accepted/rollback status.
    jq -nc --argjson config "$config" --arg id "$(printf '%016d' "$n")" --arg row "$row" \
        '{rig_config:$config,history:[{change_id:"unrelated",status:"applied"},{change_id:$id,status:$row}]}'
}
# Bounded deterministic polling: run the real predicates; never depend on wall time or hardware.
wait_for() {
    shift 3
    local i
    for ((i = 0; i < 3; i++)); do "$@" && return 0; done
    return 1
}
_pred_feed_maxt() { return 0; }

echo "== scalar revert config convergence precedes terminal history =="
for key in DONATION watchdog_interval_min max_temp_c; do
    for OUTCOME in applied rolled_back failed accepted ''; do
        : >"$TMP/applies"
        : >"$TMP/ledger"
        echo 0 >"$TMP/ticks"
        rm -f "$TMP/terminal"
        before="$IT_FAIL"
        if [ "$key" = max_temp_c ]; then
            _max_temp_round_trip rig1 100 >"$TMP/drive" 2>&1
        else
            _writable_key_round_trip rig1 "$key" 5 6 >"$TMP/drive" 2>&1
        fi
        rc=$? failures=$((IT_FAIL - before))
        IT_FAIL="$before"
        assert_eq "[$key/$OUTCOME] probe and revert both sent" "$(wc -l <"$TMP/applies" | tr -d ' ')" 2
        assert_eq "[$key/$OUTCOME] waits beyond config convergence" "$([ "$(cat "$TMP/ticks")" -ge 3 ] && echo yes || echo no)" yes
        case "$OUTCOME" in
        applied) want_rc=0 want_fail=0 want_clear=1 ;;
        accepted | '') want_rc=1 want_fail=1 want_clear=0 ;;
        *) want_rc=0 want_fail=1 want_clear=0 ;;
        esac
        assert_eq "[$key/$OUTCOME] preserves outcome and cleanup duty" \
            "$rc,$failures,$(grep -c clear "$TMP/ledger")" "$want_rc,$want_fail,$want_clear"
        assert_contains "[$key/$OUTCOME] assertion names exact revert outcome" "$(cat "$TMP/drive")" \
            "$key revert reached terminal applied in per-worker history"
    done
done

echo "== DONATION revert gates the real watchdog caller =="
# Drive the real DONATION -> watchdog caller, rather than manually ignoring a barrier's rc.
eval "$(declare -f _worker_detail | sed '1s/_worker_detail/_worker_detail_original/')"
_worker_detail() {
    if [ ! -s "$TMP/applies" ]; then
        echo '{"rig_config":{"DONATION":5,"watchdog_interval_min":5}}'
    else
        _worker_detail_original "$@"
    fi
}
for OUTCOME in applied rolled_back accepted ''; do
    : >"$TMP/applies"
    : >"$TMP/ledger"
    echo 0 >"$TMP/ticks"
    rm -f "$TMP/terminal"
    before="$IT_FAIL"
    run_rigforge_writable_keys rig1 >"$TMP/drive" 2>&1
    rc=$?
    IT_FAIL="$before"
    case "$OUTCOME" in accepted | '') want_count=2 want_rc=1 ;; *) want_count=4 want_rc=0 ;; esac
    assert_eq "[$OUTCOME] watchdog sent only after terminal predecessor" \
        "$(wc -l <"$TMP/applies" | tr -d ' '),$rc,$(grep -c premature "$TMP/ledger")" "$want_count,$want_rc,0"
done
echo "== terminal history with stale config retains cleanup =="
# A terminal transaction allows sequencing even if config readback failed; never clear cleanup.
_settle_history_row() { printf '%s' "$OUTCOME"; }
for OUTCOME in applied failed rolled_back; do
    : >"$TMP/ledger"
    before="$IT_FAIL"
    _finish_worker_revert rig1 DONATION accepted '0000000000000002' >"$TMP/drive" 2>&1
    rc=$? failures=$((IT_FAIL - before))
    IT_FAIL="$before"
    want_fail=1
    [ "$OUTCOME" != applied ] || want_fail=0
    assert_eq "[config timeout/$OUTCOME] terminal sequencing keeps cleanup duty" \
        "$rc,$failures,$(grep -c clear "$TMP/ledger")" "0,$want_fail,0"
done

echo "== terminal refusal without an ID never polls history =="
# A terminal pre-dial refusal has no ID: do not wait for a nonexistent history row.
_settle_history_row() { echo unexpected >>"$TMP/polls"; }
for status in rejected failed rolled_back noop throttled applied accepted ''; do
    : >"$TMP/polls"
    : >"$TMP/ledger"
    before="$IT_FAIL"
    _finish_worker_revert rig1 DONATION "$status" '' >"$TMP/drive" 2>&1
    rc=$? failures=$((IT_FAIL - before))
    IT_FAIL="$before"
    case "$status" in applied | accepted | '') want_rc=1 ;; *) want_rc=0 ;; esac
    assert_eq "[no ID/$status] no history poll, no invented success, cleanup retained" \
        "$rc,$failures,$(wc -l <"$TMP/polls" | tr -d ' '),$(grep -c clear "$TMP/ledger")" "$want_rc,1,0,0"
done
printf '\nselftest-rigforge-revert-terminal: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
