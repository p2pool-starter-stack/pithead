#!/usr/bin/env bash
#
# Self-test for _settle_worker_apply_maxt (#1309): the worker-apply "accepted" (RigForge #344
# async apply) settle-to-terminal logic run.sh's #513 reversible-edit legs use. Standalone (not
# sourced by selftest.sh) so it never touches selftest.sh's own file-budget ceiling — same
# reasoning as selftest-compose-profiles.sh (#1301). Run directly, or via
# `make test-integration-selftest` (which runs this after selftest.sh). No server needed.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/rigforge-apply-settle.sh
source "$HERE/../lib/rigforge-apply-settle.sh"

echo "== _settle_worker_apply_maxt: fast path (already terminal) =="
res='{"status":"applied","changed_keys":["max_temp_c"],"change_id":"c1"}'
out="$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "an immediate 'applied' passes through untouched" "$out" "applied|max_temp_c|c1"

echo "== _settle_worker_apply: wait_for's banner must not reach the RESULT (#1454) =="
# The one case in this file that does NOT stub wait_for, and that is the whole point. Every other
# case replaces it with a silent `return 0` / `return 1`, and that silence is what let #1454 ship:
# the real wait_for opens with an it_step banner on stdout, and this function's stdout is its
# return value. Drop the `>&2` in rigforge-apply-settle.sh and the capture becomes two lines, so
# `read` takes the banner as $status — the exact four reds the 2026-08-28 gate run printed.
# Driven through the generic _settle_worker_apply with a trivially-true predicate so it stays
# hermetic (no dashboard, no rig) while still running the genuine lib.sh wait_for.
_pred_settles_now() { return 0; }
res='{"status":"accepted","change_id":"c-banner"}'
out="$(_settle_worker_apply max_temp_c "the rig to report max_temp_c=101 applied" "$res" _pred_settles_now)"
assert_eq "the settle's stdout is the result and nothing else" "$out" "applied|max_temp_c|c-banner"
# Second conjunct, and a DIFFERENT mechanism on purpose: the wrong fix for the above is to delete
# the banner from wait_for, which would silence progress reporting for every other wait in the
# harness. Assert it is still emitted — on stderr, where wait_for's own timeout warning goes.
err="$(_settle_worker_apply max_temp_c "the rig to report max_temp_c=101 applied" "$res" _pred_settles_now 2>&1 >/dev/null)"
assert_contains "the progress banner is redirected, not deleted" "$err" "waiting for the rig to report max_temp_c=101 applied"
assert_contains "the accepted request's ID is in the wait banner for bench-ci #913" "$err" "change_id=c-banner"

echo "== _history_row_status: the row is read by change_id, never 'the newest' (#1471) =="
# _worker_detail is the CALLER's, injected exactly like the readback predicates this module already
# takes as arguments; these cases supply it directly rather than through a rig or a server.
# The wanted row is deliberately NOT first, and the ordering is the whole case: with c-mine first
# a `first(.history[]?)` mutation — matching the newest row instead of the change_id — returns it
# anyway, and this assertion goes green against the very defect it names. The status values differ
# too, so the mutation is caught on the VALUE and not only on the row's absence.
STUB_HIST='[{"change_id":"c-newer","status":"failed"},{"change_id":"c-mine","status":"applied"}]'
_worker_detail() { printf '{"history":%s}' "$STUB_HIST"; }
assert_eq "the row for THIS change_id is read, not the newest one" \
    "$(_history_row_status r c-mine)" "applied"
assert_eq "a change_id with no row of its own reads back empty" \
    "$(_history_row_status r c-absent)" ""
STUB_HIST='null'
assert_eq "a detail body carrying no history at all reads back empty, not an error" \
    "$(_history_row_status r c-mine)" ""

echo "== _pred_history_row_terminal: terminal is the COMPLEMENT of accepted/absent (#1471) =="
STUB_HIST='[{"change_id":"c1","status":"accepted"}]'
_pred_history_row_terminal r c1
assert_eq "a still-'accepted' row is NOT terminal — that is the whole point of waiting" "$?" "1"
STUB_HIST='[]'
_pred_history_row_terminal r c1
assert_eq "no row yet is NOT terminal" "$?" "1"
STUB_HIST='[{"change_id":"c1","status":"applied"}]'
_pred_history_row_terminal r c1
assert_eq "'applied' is terminal" "$?" "0"
STUB_HIST='[{"change_id":"c1","status":"rejected"}]'
_pred_history_row_terminal r c1
assert_eq "'rejected' is terminal — a real refusal must not burn the 90s bound" "$?" "0"
# The complement form, asserted rather than assumed. #1009's vocabulary is six names TODAY, and the
# allowlist spelling of this predicate passes every case above while turning a newly added rig
# status into a 90s timeout reported as "the row never settled" — the wrong diagnosis, reached at
# the most expensive possible price. This is the case that kills that spelling.
STUB_HIST='[{"change_id":"c1","status":"quarantined"}]'
_pred_history_row_terminal r c1
assert_eq "a status this harness has never seen reads as terminal, not as 'keep waiting'" "$?" "0"

echo "== _settle_history_row: wait_for's banner must not reach the RESULT (#1454, #1471) =="
# The same trap as the settle above and for the same reason — this function's stdout is its return
# value, and the real wait_for opens with an it_step banner on stdout. Run with the GENUINE wait_for
# against a row that is already terminal, so it costs nothing: drop the `>&2` in
# rigforge-apply-settle.sh and this capture gains the banner as its first line.
STUB_HIST='[{"change_id":"c-t","status":"applied"}]'
assert_eq "the settle's stdout is the row status and nothing else" \
    "$(_settle_history_row r c-t)" "applied"

echo "== _settle_history_row: a row that goes terminal LATE is waited for (#1471) =="
# THE mutation-kill for #1471, and it drives the genuine lib.sh wait_for. Delete the wait from
# _settle_history_row and this reads "accepted" — which is exactly the race the issue documents:
# RigForge commits the new config at the START of a control-apply and writes the terminal status
# only at the END, after the miner restart, so the row is still "accepted" when the config settle
# that precedes this returns.
#
# The read counter is a FILE, not a shell variable, and that is load-bearing rather than a style
# choice: the call under test is captured with `$(...)`, so a stub counting into a variable would
# lose every increment to the command-substitution subshell and report "converged on the first
# read" — passing against BOTH the waited and the unwaited form, proving nothing. (The same lesson
# APPLY_LOG carries in selftest-rigforge-writable-keys.sh.)
TICKS="$(mktemp)"
trap 'rm -f "$TICKS"' EXIT
printf '1' >"$TICKS"
_worker_detail() { # "accepted" on the first read, "applied" from the second onwards
    local n
    n="$(cat "$TICKS")"
    printf '%s' $((n + 1)) >"$TICKS"
    if [ "$n" -ge 2 ]; then
        printf '{"history":[{"change_id":"c-late","status":"applied"}]}'
    else
        printf '{"history":[{"change_id":"c-late","status":"accepted"}]}'
    fi
}
assert_eq "a row still 'accepted' at settle time is waited to its terminal status" \
    "$(_settle_history_row r c-late)" "applied"
# Two distinct reads must observe accepted, then applied. The file counter starts at one,
# so reaching three proves the wait performed both reads; the result uses the cached second read.
assert_num_ge "the wait re-read the row rather than settling on one look" "$(cat "$TICKS")" "3"
# Treating accepted as terminal is separately rejected by the predicate tests above.

echo "== _settle_history_row: a row that never settles must not read as 'applied' (#1471) =="
# The other half, stubbed rather than real so it costs nothing — the 90s bound is the function's
# point, not something to spend here. What must hold is that a timeout reports what the row is
# STUCK at: not empty, which would report a missing row for what is really an unsettled one, and
# never "applied", which would be #1471's false pass with extra steps. The section below re-stubs
# wait_for for its own case, so this stub does not reach it.
STUB_HIST='[{"change_id":"c-stuck","status":"accepted"}]'
_worker_detail() { printf '{"history":%s}' "$STUB_HIST"; }
wait_for() {
    shift 3
    "$@"
    return 1
}
assert_eq "a timed-out settle reports the status the row is stuck at, so the caller can name it" \
    "$(_settle_history_row r c-stuck)" "accepted"

echo "== _settle_worker_apply_maxt: RigForge #344 async apply (#1309) =="
# This is the load-bearing mutation-kill: if the "accepted is terminal" bug (#1309) were
# reintroduced — treating status verbatim instead of polling for it to settle — this would still
# read "accepted|" with no changed_keys, exactly the 4 reds the issue documents.
res='{"status":"accepted","change_id":"c2"}'
wait_for() { return 0; }
out="$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "'accepted' that converges settles to 'applied' + the requested key" "$out" "applied|max_temp_c|c2"

echo "== _settle_worker_apply_maxt: timeout / real failure must NOT read as success =="
# Mutation proof, the other half: a change that genuinely never lands (broken apply path, or the
# #579 feed/reconciler regressed) must fail loudly, not silently pass as "applied" because we saw
# a "the change is at least accepted" event once.
res='{"status":"accepted","change_id":"c3"}'
wait_for() { return 1; }
out="$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "'accepted' that never converges stays 'accepted' (fails the caller's assert_eq)" "$out" "accepted||c3"

echo "== _settle_worker_apply_maxt: a pre-dial reject carries no change_id/changed_keys =="
res='{"status":"rejected","error":"nope"}'
out="$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "rejected passes through with both trailing fields genuinely empty" "$out" "rejected||"

echo "== _settle_worker_apply_maxt: '|'-joined output survives an empty MIDDLE field =="
# The regression this delimiter choice guards: IFS=tab is bash's IFS-WHITESPACE class, so `read`
# SQUASHES a run of tabs instead of treating an empty middle field as a real field — a change_id
# with no changed_keys (exactly the "accepted"/"rejected" shapes above) would shift change_id into
# the ckeys variable instead of leaving it empty. Splits the REAL function's output with the SAME
# `IFS='|' read` run.sh's call sites use, so reverting the function to a tab-joined output (no '|'
# to split on at all) fails this: the whole string lands in rstatus instead of just "rejected".
IFS='|' read -r rstatus rckeys rchange_id <<<"$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "empty middle field (ckeys) does not shift change_id left" "$rstatus,$rckeys,$rchange_id" "rejected,,"

echo "== exact-ID history handoff samples (#2761) =="
log="$(mktemp)"
bound_log="$(mktemp)"
trap 'rm -f "$log" "$bound_log"' EXIT
RIG_HOST=example.test
RIG_CONTROL_PORT=8082
IT_RIG_TOKEN=fixture-secret
STUB_DETAIL='{"snapshot_at":1790760000.25,"status":"online","history":[{"change_id":"ffffffffffffffff","status":"failed"},{"change_id":"0123456789abcdef","status":"accepted"}],"rigforge":{"generated_at":"2026-09-30T13:15:30Z","stale":false},"rig_config":{"pools":[{"pass":"fixture-secret"}]}}'
api_state() { printf '%s' '{"workers":[{"name":"other","api_ok":true},{"name":"r","api_ok":false,"rigforge":{"generated_at":"2026-09-30T13:15:30Z"}}]}'; }
STUB_FEED='{"generated_at":"2026-09-30T13:16:00Z","rigforge":{"control":{"change_id":"ffffffffffffffff","status":"failed"},"control_history":[{"change_id":"0123456789abcdef","status":"applied","reason":"fixture-secret"}],"config":{"pools":[{"pass":"fixture-secret"}]}}}'
_worker_detail() { printf '%s' "$STUB_DETAIL"; }
rx() {
    cat >/dev/null
    case "$1" in
    *'/1/summary'*) printf '%s' "$STUB_FEED" ;;
    *status*change_id*) printf '%s' '{"change_id":"0123456789abcdef","status":"applied","reason":"fixture-secret"}' ;;
    esac
}
wait_for() {
    printf '%s' "$1" >"$bound_log"
    shift 3
    local i
    for ((i = 0; i < 22; i++)); do "$@"; done
    return 1
}
out="$(_settle_history_row r 0123456789abcdef 2>"$log")"
assert_eq "history assertion retains its 90-second bound" "$(cat "$bound_log")" 90
assert_eq "samples never promote accepted to applied" "$out" accepted
assert_eq "diagnostics retain at most 20 samples per wait" "$(grep -c '^{' "$log")" 20
sample="$(grep '^{' "$log" | tail -1)"
assert_eq "exact ID is compared across dashboard, direct ring and status despite a newer current slot" \
    "$(printf '%s' "$sample" | jq -c '[.history_handoff.change_id,.history_handoff.dashboard.history,.history_handoff.direct.history,.history_handoff.direct.current,.history_handoff.outcome.status]')" \
    '["0123456789abcdef","accepted","applied","absent","applied"]'
assert_eq "collector result is matched by worker and retains failed probe plus feed stamp" \
    "$(printf '%s' "$sample" | jq -c '[.history_handoff.collector.api_ok,.history_handoff.collector.feed_at]')" \
    '[false,"2026-09-30T13:15:30Z"]'
assert_eq "snapshot and both feed generation times survive" \
    "$(printf '%s' "$sample" | jq -c '[.history_handoff.dashboard.snapshot_at,.history_handoff.dashboard.feed_at,.history_handoff.direct.feed_at]')" \
    '[1790760000.25,"2026-09-30T13:15:30Z","2026-09-30T13:16:00Z"]'
if grep -Eq 'fixture-secret|example\.test|pass|reason' "$log"; then
    it_fail "samples exclude credentials, reasons, config and topology" "unsafe output"
else
    it_pass "samples exclude credentials, reasons, config and topology"
fi
STUB_DETAIL='{"history":[{"change_id":"0123456789abcdef","status":"fixture-secret"}],"rigforge":{"generated_at":"fixture-secret","stale":"fixture-secret"}}'
STUB_FEED='{"generated_at":"fixture-secret","rigforge":{"control_history":[{"change_id":"0123456789abcdef","status":"fixture-secret"}]}}'
_history_handoff_sample 0123456789abcdef "$STUB_DETAIL" 2>"$log"
assert_eq "malicious reflected scalars are replaced" \
    "$(jq -c '[.history_handoff.dashboard.history,.history_handoff.dashboard.feed_at,.history_handoff.direct.history]' "$log")" \
    '["unrecognized","invalid_or_absent","unrecognized"]'
if grep -q 'fixture-secret' "$log"; then it_fail "no reflected credential" "unsafe output"; else it_pass "no reflected credential"; fi
rx() {
    cat >/dev/null
    return 1
}
_history_handoff_sample 0123456789abcdef '' 2>"$log"
assert_eq "failed polls are named without hiding either failed surface" \
    "$(jq -c '[.history_handoff.dashboard.poll,.history_handoff.direct_poll,.history_handoff.direct.poll,.history_handoff.status_poll]' "$log")" \
    '["invalid_or_failed","failed","invalid_or_failed","failed"]'
_history_handoff_sample 0123456789abcdef '{}{}' 2>"$log"
assert_eq "multiple JSON responses are invalid rather than breaking the combined sample" \
    "$(jq -r '.history_handoff.dashboard.poll' "$log")" invalid_or_failed
IT_RIG_TOKEN=''
_history_handoff_sample 0123456789abcdef '{}' 2>"$log"
assert_eq "missing credentials are explicitly unavailable" "$(jq -r '.history_handoff.direct_poll' "$log")" unavailable
_history_handoff_sample 'fixture-secret' '{}' 2>"$log"
assert_eq "malformed IDs never reach output or a dial" "$(wc -c <"$log" | tr -d ' ')" 0

echo "== slow diagnostics cannot accept history observed after the deadline =="
# Use the genuine wait loop with a file-backed clock, so command substitutions share time.
# Failed reads consume their HTTP limits without a real 90-second sleep or a server.
(
    source "$HERE/../lib.sh"
    IT_RIG_TOKEN=fixture-secret
    clock_file="$(mktemp)"
    warning_file="$(mktemp)"
    trap 'rm -f "$clock_file" "$warning_file"' EXIT
    advance() { printf '%s\n' "$(($(cat "$clock_file") + $1))" >"$clock_file"; }
    now_s() { cat "$clock_file"; }
    sleep() { advance "$1"; }
    _worker_detail() {
        advance "$read_delay"
        local status=accepted
        [ "$(now_s)" -lt "$applied_at" ] || status=applied
        printf '{"history":[{"change_id":"0123456789abcdef","status":"%s"}]}' "$status"
    }
    rx() {
        cat >/dev/null
        advance "$probe_delay"
        return 1
    }
    api_state() {
        advance "$collector_delay"
        return 1
    }
    read_delay=0 probe_delay=3 collector_delay=10 applied_at=95
    printf '0\n' >"$clock_file"
    out="$(_settle_history_row r 0123456789abcdef 2>"$warning_file")"
    assert_eq "slow failed probes cannot turn 95-second convergence into a pass" "$out" accepted
    assert_contains "deadline failure is reported" "$(cat "$warning_file")" "timed out after 90s"
    assert_num_ge "the proof actually consumes the diagnostic limits" "$(now_s)" 95
    printf '0\n' >"$clock_file"
    applied_at=84
    out="$(_settle_history_row r 0123456789abcdef 2>"$warning_file")"
    assert_eq "a terminal history read before the deadline passes even when diagnostics finish later" "$out" applied
    printf '0\n' >"$clock_file"
    read_delay=10 probe_delay=0 collector_delay=0 applied_at=95
    out="$(_settle_history_row r 0123456789abcdef 2>"$warning_file")"
    assert_eq "a dashboard read that finishes after the deadline cannot pass" "$out" accepted
    [ "$IT_FAIL" -eq 0 ]
) && it_pass "deadline regressions reject late convergence" || it_fail "deadline regressions" "late convergence escaped the 90-second boundary"

echo "== failed transport cannot supply an applied history observation =="
(
    source "$HERE/../lib.sh"
    warning_file="$(mktemp)"
    trap 'rm -f "$warning_file"' EXIT
    now_s() { printf '0'; }
    IT_RIG_TOKEN=''
    api_state() { printf '{}'; }
    _worker_detail() {
        printf '{"history":[{"change_id":"0123456789abcdef","status":"applied"}]}'
        return 255
    }
    wait_for() {
        shift 3
        "$@"
    }
    out="$(_settle_history_row r 0123456789abcdef 2>"$warning_file")"
    assert_eq "valid applied JSON from a failed transport cannot pass" "$out" ""
    assert_eq "failed transport has an explicit dashboard observation" \
        "$(jq -r '.history_handoff.dashboard.poll' "$warning_file")" failed
    assert_eq "failed transport body never supplies a history status" \
        "$(jq -r '.history_handoff.dashboard.history // "absent"' "$warning_file")" absent
    _HISTORY_ROW_STATUS=accepted _HISTORY_SAMPLE_COUNT=0
    _pred_history_row_terminal r 0123456789abcdef 2>"$warning_file"
    assert_eq "a failed read remains nonterminal" "$?" 1
    assert_eq "a failed read preserves the last successful accepted observation" "$_HISTORY_ROW_STATUS" accepted
    [ "$IT_FAIL" -eq 0 ]
) && it_pass "failed dashboard transport is rejected" || it_fail "failed dashboard transport" "failed read supplied a verdict or lacked a failure marker"

echo "== partial decoder output cannot supply an applied history observation =="
(
    source "$HERE/../lib.sh"
    warning_file="$(mktemp)"
    trap 'rm -f "$warning_file"' EXIT
    now_s() { printf '0'; }
    IT_RIG_TOKEN=''
    api_state() { printf '{}'; }
    decoder_body='{"history":[{"change_id":"0123456789abcdef","status":"applied"}]}garbage'
    _worker_detail() { printf '%s' "$decoder_body"; }
    wait_for() {
        shift 3
        "$@"
    }
    out="$(_settle_history_row r 0123456789abcdef 2>"$warning_file")"
    assert_eq "applied JSON followed by junk cannot pass" "$out" ""
    assert_eq "failed JSON decoding has an explicit invalid observation" \
        "$(jq -r '.history_handoff.dashboard.poll' "$warning_file")" invalid_or_failed
    assert_eq "partial decoder output never supplies a diagnostic history status" \
        "$(jq -r '.history_handoff.dashboard.history // "absent"' "$warning_file")" absent
    _HISTORY_ROW_STATUS='' _HISTORY_SAMPLE_COUNT=0
    decoder_body='{"history":[{"change_id":"0123456789abcdef","status":"accepted"}]}'
    _pred_history_row_terminal r 0123456789abcdef 2>"$warning_file"
    assert_eq "the successful accepted observation remains nonterminal" "$?" 1
    assert_eq "the successful accepted observation is cached" "$_HISTORY_ROW_STATUS" accepted
    decoder_body='{"history":[{"change_id":"0123456789abcdef","status":"applied"}]}garbage'
    _pred_history_row_terminal r 0123456789abcdef 2>"$warning_file"
    assert_eq "a failed decode remains nonterminal" "$?" 1
    assert_eq "a failed decode preserves the last successfully decoded observation" "$_HISTORY_ROW_STATUS" accepted
    assert_eq "the failed decode remains explicit after a successful observation" \
        "$(jq -r '.history_handoff.dashboard.poll' "$warning_file")" invalid_or_failed
    decoder_body='{"history":[{"change_id":"0123456789abcdef","status":"applied"}]}{}'
    _pred_history_row_terminal r 0123456789abcdef 2>"$warning_file"
    assert_eq "multiple JSON documents cannot supply a terminal observation" "$?" 1
    assert_eq "multiple JSON documents preserve the last valid observation" "$_HISTORY_ROW_STATUS" accepted
    assert_eq "multiple JSON documents have an explicit invalid observation" \
        "$(jq -r '.history_handoff.dashboard.poll' "$warning_file")" invalid_or_failed
    [ "$IT_FAIL" -eq 0 ]
) && it_pass "partial dashboard decoder output is rejected" || it_fail "partial dashboard decoder output" "invalid JSON supplied a verdict or replaced the last valid observation"

echo ""
echo "selftest-rigforge-apply-settle: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
