# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"
echo "== unit: control carries the live config version =="
cp "$ROOT/VERSION" "$C/VERSION"
seed_control_env
control_config main
jq '.config_version="2.0.0"' "$C/config.json" >"$C/with-version"
mv "$C/with-version" "$C/config.json"
CV_ID=88888888-8888-4888-8888-888888888888
for candidate_stamp in '"9.9.9"' null; do
    jq --arg id "$CV_ID" --argjson stamp "$candidate_stamp" \
        '{id:$id,action:"preview",actor:"admin",config:(if $stamp == null then del(.config_version) else .config_version=$stamp end)}' \
        "$C/config.json" >"$REQS/$CV_ID.json"
    (cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead control-run-pending >/dev/null 2>&1)
    assert_eq "version edit $candidate_stamp previews" "$(jq -r .status "$RESULTS/$CV_ID.json")" previewed
    assert_eq "version edit $candidate_stamp carries live stamp" "$(jq -r .config_version "$STAGED/$CV_ID.json")" 2.0.0
    assert_eq "stamp produces no preview value" "$(jq '[.preview_values[]? | select(.key=="config_version")] | length' "$RESULTS/$CV_ID.json")" 0
    assert_not_contains "stamp produces no porcelain row" "$(jq -r '.porcelain // ""' "$RESULTS/$CV_ID.json")" config_version
    printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$CV_ID" >"$REQS/$CV_ID.json"
    (cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead control-run-pending >/dev/null 2>&1)
    assert_eq "stamp-only candidate passes schema and commits" "$(jq -r .status "$RESULTS/$CV_ID.json")" applied
    assert_eq "commit retains host stamp" "$(jq -r .config_version "$C/config.json")" "$(cat "$ROOT/VERSION")"
done
control_config main
jq --arg id "$CV_ID" '{id:$id,action:"preview",actor:"admin",config:(.config_version="9.9.9")}' "$C/config.json" >"$REQS/$CV_ID.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "unstamped live file ignores supplied stamp" "$(jq 'has("config_version")' "$STAGED/$CV_ID.json")" false
rm -f "$RESULTS/$CV_ID.json" "$STAGED/$CV_ID.json"
