# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== black-box: control commits cannot overwrite a newer config preview (#3352) =="
ensure_control_fixture

CCA="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
CCB="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
CCS="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
rm -f "$REQS/$CCA.json" "$REQS/$CCB.json" "$REQS/$CCS.json" \
    "$RESULTS/$CCA.json" "$RESULTS/$CCB.json" "$RESULTS/$CCS.json" \
    "$STAGED/$CCA.json" "$STAGED/$CCB.json" "$STAGED/$CCS.json"

control_config mini
jq '.dashboard.energy={cost_per_kwh:0.17,currency:"USD"}' "$C/config.json" >"$C/config.concurrent" &&
    mv "$C/config.concurrent" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

jq '.dashboard.energy.cost_per_kwh=0.18' "$C/config.json" |
    jq -n --arg id "$CCA" --slurpfile cfg /dev/stdin \
        '{id:$id,action:"preview",actor:"view-a",config:$cfg[0]}' >"$REQS/$CCA.json"
run_pending >/dev/null
assert_eq "view A stages its energy-cost preview" "$(jq -r '.status' "$RESULTS/$CCA.json")" "previewed"

jq '.dashboard.energy.currency="EUR"' "$C/config.json" |
    jq -n --arg id "$CCB" --slurpfile cfg /dev/stdin \
        '{id:$id,action:"preview",actor:"view-b",config:$cfg[0]}' >"$REQS/$CCB.json"
run_pending >/dev/null
assert_eq "view B stages its currency preview from the same baseline" \
    "$(jq -r '.status' "$RESULTS/$CCB.json")" "previewed"

printf '{"id":"%s","action":"commit","actor":"view-b"}\n' "$CCB" >"$REQS/$CCB.json"
run_pending >/dev/null
b_status="$(jq -r '.status' "$RESULTS/$CCB.json")"
assert_eq "the newer view B commit applies" "$b_status" "applied"
if [ "$b_status" = "applied" ]; then
    assert_eq "view B currency lands" "$(jq -r '.dashboard.energy.currency' "$C/config.json")" "EUR"
    cp "$C/config.json" "$C/config.after-view-b"

    printf '{"id":"%s","action":"commit","actor":"view-a"}\n' "$CCA" >"$REQS/$CCA.json"
    run_pending >/dev/null
    assert_eq "the stale view A commit is rejected" "$(jq -r '.status' "$RESULTS/$CCA.json")" "rejected"
    if cmp -s "$C/config.json" "$C/config.after-view-b"; then
        ok "a stale preview leaves the newer config byte-identical"
    else
        bad "a stale preview leaves the newer config byte-identical" "view A overwrote view B"
    fi
else
    printf '  concurrency assertions stopped: view B did not establish the newer config (%s)\n' \
        "$(jq -r '.error // "no error reported"' "$RESULTS/$CCB.json")"
fi

echo "== black-box control: sparse candidates stay sparse when the caller omits default arrays (#3355) =="
control_config mini
jq '.dashboard.energy={cost_per_kwh:0.17,currency:"USD"} | del(.workers,.notifications)' \
    "$C/config.json" >"$C/config.sparse" && mv "$C/config.sparse" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
cp "$C/config.json" "$C/config.sparse-before"

jq '.dashboard.energy.cost_per_kwh=0.18' "$C/config.json" |
    jq -n --arg id "$CCS" --slurpfile cfg /dev/stdin \
        '{id:$id,action:"preview",actor:"admin",config:$cfg[0]}' >"$REQS/$CCS.json"
run_pending >/dev/null
assert_eq "a one-field sparse candidate previews" "$(jq -r '.status' "$RESULTS/$CCS.json")" "previewed"
assert_eq "the sparse staged candidate still omits default worker and webhook arrays" \
    "$(jq -r '[has("workers"),has("notifications")] | @json' "$STAGED/$CCS.json")" "[false,false]"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$CCS" >"$REQS/$CCS.json"
run_pending >/dev/null
assert_eq "the one-field sparse candidate commits" "$(jq -r '.status' "$RESULTS/$CCS.json")" "applied"
assert_eq "the one-field sparse candidate has no gate error" \
    "$(jq -r '.error // ""' "$RESULTS/$CCS.json")" ""
assert_eq "the intended scalar lands" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"
assert_eq "untouched default arrays remain absent after commit" \
    "$(jq -r '[has("workers"),has("notifications")] | @json' "$C/config.json")" "[false,false]"
assert_eq "the scalar is the only structural change" \
    "$(jq -S 'del(.dashboard.energy.cost_per_kwh)' "$C/config.json")" \
    "$(jq -S 'del(.dashboard.energy.cost_per_kwh)' "$C/config.sparse-before")"

rm -f "$C/config.after-view-b" "$C/config.sparse-before" \
    "$RESULTS/$CCA.json" "$RESULTS/$CCB.json" "$RESULTS/$CCS.json" \
    "$STAGED/$CCA.json" "$STAGED/$CCB.json" "$STAGED/$CCS.json"
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
