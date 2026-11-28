# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${SB:?is unset: this fragment runs after test-control-support-bundle.sh}"

echo "== window times come from one fixed instant (#4187) =="
sb_iso_first=$(sb_iso -3600)
sleep 1
assert_eq "sb_iso returns the same time across a second boundary" "$(sb_iso -3600)" "$sb_iso_first"

echo "== control channel: the applied result carries the manifest's effective window (#4129) =="
eid1="c412c412-0000-4000-8000-000000000001"
sb_run "$(sb_req "$eid1" support-bundle ",\"since\":\"$(sb_iso -7200)\",\"until\":\"$(sb_iso -60)\"")"
assert_eq "an in-range window is applied" "$(jq -r .status "$SB/results/$eid1.json")" "applied"
assert_eq "the effective start equals the requested start" \
    "$(jq -r '.effective_since == .since' "$SB/results/$eid1.json")" "true"
assert_eq "an in-range window is not journal_short" "$(jq -r .journal_short "$SB/results/$eid1.json")" "false"
eid2="c412c412-0000-4000-8000-000000000002"
sb_run "$(sb_req "$eid2" support-bundle ",\"since\":\"$(sb_iso -864000)\",\"until\":\"$(sb_iso -60)\"")"
assert_eq "a window older than the journal is journal_short" "$(jq -r .journal_short "$SB/results/$eid2.json")" "true"
assert_eq "the effective start is the oldest retained entry, not the requested start" \
    "$(jq -r '.effective_since != .since and (.effective_since | test("^[0-9]{4}-"))' "$SB/results/$eid2.json")" "true"

echo "== control channel: support-bundle-range reports the oldest retained entry (#4129) =="
rid1="c412c412-0000-4000-8000-000000000003"
sb_run "$(sb_req "$rid1" support-bundle-range)"
assert_eq "the range verb applies" "$(jq -r .status "$SB/results/$rid1.json")" "applied"
assert_eq "the range names the oldest entry as an RFC 3339 UTC time" \
    "$(jq -r '.oldest | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$SB/results/$rid1.json")" "true"
assert_not_contains "the read-only range verb writes no audit row" "$(cat "$SB/audit/control.log")" "support-bundle-range"

echo "== control channel: with the switch off the runner serves only the export (#4129) =="
oid1="c412c412-0000-4000-8000-000000000004"
CONTROL_EXPORT_ONLY=1 sb_run "$(sb_req "$oid1" restart)"
assert_eq "export-only rejects a restart" "$(jq -r .status "$SB/results/$oid1.json")" "rejected"
assert_contains "the rejection says the control channel is off" "$(jq -r .error "$SB/results/$oid1.json")" "control channel is off"
assert_contains "the rejection is audited" "$(cat "$SB/audit/control.log")" '"action":"restart","status":"rejected"'
oid2="c412c412-0000-4000-8000-000000000005"
CONTROL_EXPORT_ONLY=1 sb_run "$(sb_req "$oid2" commit)"
assert_eq "export-only rejects a commit" "$(jq -r .status "$SB/results/$oid2.json")" "rejected"
oid3="c412c412-0000-4000-8000-000000000006"
CONTROL_EXPORT_ONLY=1 sb_run "$(sb_req "$oid3" support-bundle)"
assert_eq "export-only still collects a bundle" "$(jq -r .status "$SB/results/$oid3.json")" "applied"
assert_rc "export-only leaves the zip on the download leg" "$(
    ls "$SB/results/$oid3.zip" >/dev/null 2>&1
    echo $?
)" "0"
oid4="c412c412-0000-4000-8000-000000000007"
CONTROL_EXPORT_ONLY=1 sb_run "$(sb_req "$oid4" support-bundle-range)"
assert_eq "export-only still answers the range ask" "$(jq -r .status "$SB/results/$oid4.json")" "applied"
