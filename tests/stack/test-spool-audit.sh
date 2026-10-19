# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Audit growth, request intake, stale sweeps and result retention remain bounded.
# The shared fixture seeds fresh processes and preserves existing config and spool state.

ensure_control_fixture

echo "== black-box: audit log growth is bounded (#349) =="
# Seed the log past the 512 KiB cap, then let the runner audit one more event: the writer trims
# to the newest 2000 lines BEFORE appending, so the file shrinks instead of growing forever and
# the fresh entry is always the last line.
for _ in $(seq 1 6000); do
    printf '{"ts":"old","id":"","actor":"filler","action":"preview","status":"previewed","keys":""}\n'
done >>"$AUDIT"
[ "$(wc -c <"$AUDIT" | tr -d ' ')" -gt 524288 ] || bad "audit log seeded past the cap" "seed too small"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json" # no staged intent -> rejected, still audited
run_pending >/dev/null
audit_size="$(wc -c <"$AUDIT" | tr -d ' ')"
if [ "$audit_size" -lt 300000 ]; then
    ok "audit log trimmed back under the cap ($audit_size bytes)"
else
    bad "audit log trimmed back under the cap" "$audit_size bytes"
fi
assert_eq "trim keeps the newest entries (fresh entry is the last line)" "$(tail -n 1 "$AUDIT" | jq -r '.action')" "commit"
# Pin the line count too, not just the byte size: control_audit trims to `tail -n 2000` BEFORE
# appending the triggering entry, so the file must land at <= 2001 lines (2000 kept + the new one) —
# the "newest ~2000 lines" behavior the byte-size check above doesn't directly prove.
audit_lines="$(wc -l <"$AUDIT" | tr -d ' ')"
if [ "$audit_lines" -le 2001 ]; then
    ok "audit log trim caps the line count near the newest 2000 entries ($audit_lines lines)"
else
    bad "audit log trim caps the line count near the newest 2000 entries" "$audit_lines lines"
fi

echo "== black-box: spool intake cap + symlink refusal + stale sweep (#33 hardening) =="
UUID4="a4a4a4a4-a4a4-4a4a-8a4a-a4a4a4a4a4a4"
# Oversized intent: refused BEFORE jq parses it (bounded root-runner DoS), no result addressed.
: >"$AUDIT"
{
    printf '{"id":"%s","action":"preview","pad":"' "$UUID4"
    head -c 70000 /dev/zero | tr '\0' a
    printf '"}\n'
} >"$REQS/$UUID4.json"
chmod 666 "$REQS/$UUID4.json"
mkdir -p "$C/mode-bin"
cat >"$C/mode-bin/chmod" <<'EOF'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
600:*/.claim.*)
    /bin/chmod "$@"
    (stat -c %a "$2" 2>/dev/null || stat -f %Lp "$2" 2>/dev/null) >>"${MODE_LOG:?}"
    exit
    ;;
esac
exec /bin/chmod "$@"
EOF
chmod +x "$C/mode-bin/chmod"
old_path="$PATH"
MODE_LOG="$C/mode-bin-output"
export MODE_LOG
PATH="$C/mode-bin:$PATH"
run_pending >/dev/null
PATH="$old_path"
unset MODE_LOG
assert_eq "regular host claim is owner-only before it is parsed" "$(cat "$C/mode-bin-output" 2>/dev/null)" "600"
assert_contains "oversized intent refused before parsing" "$(cat "$AUDIT" 2>/dev/null)" "refused-oversize"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "oversized intent gets no result file" || bad "oversized intent gets no result file" "result written"
[ ! -f "$REQS/$UUID4.json" ] && ok "oversized intent claimed out of requests/" || bad "oversized intent claimed out of requests/" "still present"
# Symlinked request: a symlink dropped in requests/ could point the root runner at any host file —
# refused, never followed (graft #437).
: >"$AUDIT"
ln -s "$C/config.json" "$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "symlinked request refused" "$(cat "$AUDIT" 2>/dev/null)" "refused-nonregular"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "symlinked request gets no result" || bad "symlinked request gets no result" "result written"
rm -f "$REQS/$UUID4.json"
# Stale sweep: staged/ + requests/ files older than an hour are removed at run start.
jq -n '{}' >"$STAGED/stale.json"
touch -t 202001010000 "$STAGED/stale.json"
printf '{}' >"$REQS/stale-req.json"
touch -t 202001010000 "$REQS/stale-req.json"
run_pending >/dev/null
[ ! -f "$STAGED/stale.json" ] && ok "aged staged file swept" || bad "aged staged file swept" "still present"
[ ! -f "$REQS/stale-req.json" ] && ok "aged request file swept" || bad "aged request file swept" "still present"
# Orphaned claim sweep (#548): a `.claim.<pid>` left behind by a runner that died mid-dispatch
# (the errexit gap this issue closes) is swept the same way as stale staged/request files.
touch -t 202001010000 "$C/data/control/.claim.12345"
run_pending >/dev/null
[ ! -f "$C/data/control/.claim.12345" ] && ok "stale orphaned claim swept" || bad "stale orphaned claim swept" "still present"
# Per-run intake cap: 60 pending intents → one run claims exactly 50 and LEAVES the remainder in
# requests/ for the next path-unit fire (deterministic overflow — nothing is dropped). Invalid
# JSON bodies keep each of the 60 on the cheap discard path; they still count against the cap.
for i in $(seq 1 60); do printf 'notjson' >"$REQS/cap-$i.json"; done
out="$(run_pending)"
assert_contains "per-run cap announced after 50 intents" "$out" "per-run cap"
assert_contains "exactly 50 intents processed in one run" "$out" "Processed 50 control request(s)"
assert_eq "overflow intents left for the next run" "$(ls "$REQS" | wc -l | tr -d ' ')" "10"
out="$(run_pending)"
assert_contains "next run drains the remainder" "$out" "Processed 10 control request(s)"
assert_eq "spool empty after the second run" "$(ls "$REQS" | wc -l | tr -d ' ')" "0"

# Retention is applied after every request, not only before the batch: two rejected intents write
# two results, but a one-result cap leaves only the newest once the same drain finishes.
rm -f "$RESULTS"/*.json
UUID6="a6a6a6a6-a6a6-46a6-8a6a-a6a6a6a6a6a6"
UUID7="a7a7a7a7-a7a7-47a7-8a7a-a7a7a7a7a7a7"
printf '{"id":"%s","action":"unknown","actor":"x"}\n' "$UUID6" >"$REQS/$UUID6.json"
printf '{"id":"%s","action":"unknown","actor":"x"}\n' "$UUID7" >"$REQS/$UUID7.json"
export CONTROL_RESULT_MAX_COUNT=1 CONTROL_RESULT_MAX_AGE_S=100000
run_pending >/dev/null
result_count=$(find "$RESULTS" -maxdepth 1 -type f \( -name "$UUID6.json" -o -name "$UUID7.json" \) | wc -l | tr -d ' ')
assert_eq "each request in one drain reapplies the result count cap" "$result_count" "1"
unset CONTROL_RESULT_MAX_COUNT CONTROL_RESULT_MAX_AGE_S UUID6 UUID7 result_count
