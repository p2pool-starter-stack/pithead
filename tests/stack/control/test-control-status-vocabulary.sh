# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# #1422: the control-status vocabulary lives in three places — xmrig_client._CONTROL_TERMINAL,
# worker_config_store._RECONCILE_TERMINAL (guarded against each other by
# dashboard/tests/service/test_storage_service.py, which asserts them equal verbatim) and this
# script's own two control_worker_* poll loops, whose terminal words are literal `case` arms.
# Nothing guarded the third: a status word RigForge adds and neither loop's `case` matches falls
# through to the loops' "keep polling" arm — deliberately, since that is how `started` and a
# non-matching change_id are handled too — so it is not an error. It polls to the deadline and is
# recorded "accepted": a status the poller does not know about read as a normal in-flight result,
# indefinitely. That is exactly the rigforge#320 noop/throttled history, caught only by someone
# hitting it live.
#
# This is a GREP guard on the pithead script's source, not a behavioural one — the two `case` arms
# are shell literals nowhere else, and grepping them needs no sandbox, no rig, no sourcing $STACK
# (#1422's own tier call: tier 1 is honest here). The invariant is NOT "each site lists all six" —
# noop/throttled are upgrade-only outcomes, rejected is apply-only, so per-site equality would be
# wrong and brittle. It is "the union of the two case arms equals the terminal words RigForge can
# emit" — read off the same vendored fixture tests/integration/fakes/test_contract.py's
# test_every_pinned_control_status_is_classified anchors to, so a word RigForge adds shows up here
# without a second hand-maintained list to keep in sync.
#
# Non-terminal-by-design words are listed, not inferred, and match that tier-2 guard's own
# `non_terminal` set (test_contract.py) so the two guards cannot quietly diverge on the meaning of
# "non-terminal": the rig has begun a change and not yet said how it ended.
echo "== unit: the control-status vocabulary is guarded at its third site too — the pithead script's two control_worker_* poll loops (#1422) =="

_CSV_FIXTURE="$ROOT/tests/integration/fakes/contract/v1/control-status.json"
_CSV_NON_TERMINAL='^(pending|started)$'

_csv_fixture_terminal=$(jq -r '.statuses[]' "$_CSV_FIXTURE" 2>/dev/null | grep -vE "$_CSV_NON_TERMINAL" | sort -u)
_csv_fixture_terminal=$(printf '%s\nbusy\n' "$_csv_fixture_terminal" | sort -u)
assert_contains "the vendored fixture actually lists terminal words to check against" "$_csv_fixture_terminal" "applied"

# Each function's `case "$status" in` arm list sits on the line right after the line that opens
# it — pull it from the function's own byte range so a `case` added to a LATER function (there is
# none today) can never be mistaken for either poll loop's.
_csv_arms_between() { # <start-pattern> <end-pattern>
    awk "/$1/,/$2/" "$STACK" | grep -A1 'case "\$status" in' | tail -1 | tr -d ' \t)' | tr '|' '\n' | sort -u
}

_csv_apply_arms=$(_csv_arms_between '^control_worker_apply\(\)' '^control_worker_upgrade\(\)')
_csv_upgrade_arms=$(_csv_arms_between '^control_worker_upgrade\(\)' '^os_update_staging_dir\(\)')
_csv_union_arms=$(printf '%s\n%s\n' "$_csv_apply_arms" "$_csv_upgrade_arms" | sort -u)

assert_contains "control_worker_apply's terminal case arm was actually found" "$_csv_apply_arms" "applied"
assert_contains "control_worker_upgrade's terminal case arm was actually found" "$_csv_upgrade_arms" "applied"
assert_eq "control_worker_apply + control_worker_upgrade terminal arms union to exactly the fixture's terminal words" \
    "$_csv_union_arms" "$_csv_fixture_terminal"

echo "== a rig's busy refusal is a terminal status with its reason in both poll loops (#3985) =="
_csv_busy_run() { # <action> <uuid> <request-extra-json>
    local dir="$SANDBOX/csv-busy-$1"
    mkdir -p "$dir/staged" "$dir/results" "$dir/audit" "$dir/bin"
    printf '%s' "v9.9.9" >"$dir/staged/.rigforge-latest-tag"
    printf '%s\n' '{ "workers": { "list": [ { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" } ] } }' >"$dir/config.json"
    cat >"$dir/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="$(cat >/dev/null)" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/apply | */upgrade) printf '{"change_id":"b0b0b0b0b0b0b0b0"}' >"$out"; printf '202' ;;
*/status) printf '{"change_id":"b0b0b0b0b0b0b0b0","status":"busy","reason":"rig is lent to a bench job; retry after it is returned"}' >"$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
STUB
    chmod +x "$dir/bin/curl"
    printf '{"id":"%s","action":"worker-%s","actor":"admin","worker":"rig1",%s}\n' "$2" "$1" "$3" >"$dir/req.json"
    PATH="$dir/bin:$PATH" CONTROL_WA_BUDGET=1 CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$dir/config.json" \
        run_sourced_e "$SANDBOX" control_process_request "$dir/req.json" "$dir" >/dev/null 2>&1
}
_csv_busy_run apply b1b1b1b1-b1b1-4b1b-8b1b-b1b1b1b1b1b1 '"changes":{"pools":["pool.example:3333"]}'
_csv_busy_run upgrade b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2 '"version":"v9.9.9"'
_csv_busy_field() { # <action> <uuid> <field>
    jq -r --arg f "$3" '.[$f]' "$SANDBOX/csv-busy-$1/results/$2.json" 2>/dev/null
}
assert_eq "worker-apply lands the rig's busy refusal as a terminal status (#3985)" \
    "$(_csv_busy_field apply b1b1b1b1-b1b1-4b1b-8b1b-b1b1b1b1b1b1 status)" "busy"
assert_contains "worker-apply busy result carries the rig's reason (#3985)" \
    "$(_csv_busy_field apply b1b1b1b1-b1b1-4b1b-8b1b-b1b1b1b1b1b1 reason)" "lent to a bench job"
assert_eq "worker-upgrade lands the rig's busy refusal as a terminal status (#3985)" \
    "$(_csv_busy_field upgrade b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2 status)" "busy"
assert_contains "worker-upgrade busy result carries the rig's reason (#3985)" \
    "$(_csv_busy_field upgrade b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2 reason)" "lent to a bench job"
