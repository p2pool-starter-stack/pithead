# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"
echo "== unit: configuration version stamp =="
CV="$SANDBOX/config-version"
mkdir -p "$CV"
cp "$ROOT/VERSION" "$CV/VERSION"
printf '{"monero":{"wallet_address":"%s","node_username":"u","node_password":"p"},"tari":{"mode":"off"},"dashboard":{"secure":false}}\n' "$VALID_PRIMARY" >"$CV/config.json"
cp "$CV/config.json" "$CV/before"
out=$(run_sourced "$CV" eval 'PITHEAD_DRY_RUN=1; parse_and_validate_config' 2>&1)
assert_rc "dry validation succeeds" "$?" 0
cmp -s "$CV/config.json" "$CV/before" && ok "dry validation never stamps" || bad "dry validation never stamps" changed
out=$(run_sourced "$CV" parse_and_validate_config 2>&1)
assert_rc "non-dry validation succeeds" "$?" 0
assert_eq "successful validation stamps VERSION" "$(jq -r .config_version "$CV/config.json")" "$(cat "$ROOT/VERSION")"
assert_eq "stamp secures file mode" "$(file_mode "$CV/config.json")" 600
assert_eq "stamp preserves owner" "$(stat -c '%u:%g' "$CV/config.json")" "$(stat -c '%u:%g' "$CV/before")"
assert_eq "stamp changes no settings" "$(jq -Sc 'del(.config_version)' "$CV/config.json")" "$(jq -Sc . "$CV/before")"
cp "$CV/config.json" "$CV/equal"
run_sourced "$CV" parse_and_validate_config >/dev/null 2>&1
cmp -s "$CV/config.json" "$CV/equal" && ok "equal stamp leaves bytes untouched" || bad "equal stamp leaves bytes untouched" changed
jq '.config_version="9.9.9"' "$CV/equal" >"$CV/config.json"
cp "$CV/config.json" "$CV/newer"
out=$(run_sourced "$CV" parse_and_validate_config 2>&1)
assert_rc "newer config continues validation" "$?" 0
assert_contains "newer config warns" "$out" "written by pithead 9.9.9"
cmp -s "$CV/config.json" "$CV/newer" && ok "newer stamp is never lowered" || bad "newer stamp is never lowered" changed
jq '.config_version="old" | .dashboard.control.enabled=true' "$CV/equal" >"$CV/config.json"
cp "$CV/config.json" "$CV/invalid"
out=$(run_sourced "$CV" parse_and_validate_config 2>&1)
assert_rc "late validation error fails" "$?" 1
cmp -s "$CV/config.json" "$CV/invalid" && ok "failed validation keeps stamp" || bad "failed validation keeps stamp" changed
for stamp in '"old"' 17 null '"100000000000.1.0"'; do
    jq --argjson stamp "$stamp" '.config_version=$stamp' "$CV/equal" >"$CV/config.json"
    printf '2.0.0-pre.1+build\n' >"$CV/VERSION"
    out=$(run_sourced "$CV" parse_and_validate_config 2>&1)
    assert_rc "malformed stamp $stamp does not fail" "$?" 0
    assert_eq "stamp $stamp becomes release core" "$(jq -r .config_version "$CV/config.json")" 2.0.0
done
cp "$CV/before" "$CV/config.json"
out=$(run_sourced "$CV" eval 'mv() { return 1; }; parse_and_validate_config' 2>&1)
assert_rc "stamp write failure is nonfatal" "$?" 0
assert_contains "stamp write failure warns" "$out" "Could not write config_version"
cmp -s "$CV/config.json" "$CV/before" && ok "failed write leaves original intact" || bad "failed write leaves original intact" changed
assert_eq "failed write removes secret scratch" "$(find "$CV" -name '*.version.*' | wc -l | tr -d ' ')" 0

# Real archives exercise both promotion doors, including cleanup of private staging.
build_backup_sandbox
cp "$ROOT/VERSION" "$BK/VERSION"
CV_TREE="$CV/tree"
mkdir -p "$CV_TREE/${BK#/}"
jq '.config_version="9.9.9"' "$BK/config.json" >"$CV_TREE/${BK#/}/config.json"
cp "$BK/.env" "$CV_TREE/${BK#/}/.env"
tar -czf "$CV/newer.tar.gz" -C "$CV_TREE" "${BK#/}/config.json" "${BK#/}/.env"
cp "$BK/config.json" "$CV/live-before"
out=$(run_sourced "$BK" restore_apply "$CV/newer.tar.gz" "" "$CV/restore-error" "$CV/restored" "" "$CV/stage" 2>&1)
assert_rc "setup restore refuses newer backup" "$?" 1
assert_contains "setup restore names required version" "$(cat "$CV/restore-error")" "Update to 9.9.9 or later"
[ ! -e "$CV/restored" ] && ok "setup refusal promotes nothing" || bad "setup refusal promotes nothing" changed
out=$(CV_STAGE="$CV/admin-stage" CV_ARCHIVE="$CV/newer.tar.gz" run_sourced "$BK" eval 'RESTORE_STAGE_DIR="$CV_STAGE"; mkdir -m 700 "$RESTORE_STAGE_DIR"; restore_stage_archive "$CV_ARCHIVE" 0 ""' 2>&1)
assert_rc "administrative restore refuses newer backup" "$?" 1
[ ! -e "$CV/admin-stage" ] && ok "administrative refusal discards staging" || bad "administrative refusal discards staging" retained
assert_contains "administrative restore names required version" "$out" "Update to 9.9.9 or later"
cmp -s "$BK/config.json" "$CV/live-before" && ok "restore refusals leave live config intact" || bad "restore refusals leave live config intact" changed
cp "$CV/live-before" "$CV_TREE/${BK#/}/config.json"
tar -czf "$CV/baseline.tar.gz" -C "$CV_TREE" "${BK#/}/config.json" "${BK#/}/.env"
out=$(PATH="$BK/bin:$PATH" run_sourced "$BK" restore_apply "$CV/baseline.tar.gz" "" "$CV/restore-error" "$CV/restored" "" "$CV/stage" 2>&1)
assert_rc "setup restore accepts absent baseline stamp" "$?" 0
assert_eq "setup restore stamps baseline" "$(jq -r .config_version "$CV/restored")" "$(cat "$ROOT/VERSION")"

# A stamp-only USB import changes nothing; a real edit retains the host's stamp.
printf '{"config_version":"2.0.0","p2pool":{"pool":"mini"}}' >"$CV/media-live"
printf '{"config_version":"9.9.9"}' >"$CV/media-candidate"
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$CV/media-live" "$CV/media-candidate"
)
assert_eq "USB cannot replace host stamp" "$(jq -r .config_version "$merged")" 2.0.0
out=$(
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON='[]'
    media_config_diff "$CV/media-live" "$merged"
)
assert_eq "stamp-only USB changes nothing" "$out" ""
rm -f "$merged"
printf '{"config_version":"9.9.9","p2pool":{"pool":"main"}}' >"$CV/media-candidate"
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$CV/media-live" "$CV/media-candidate"
)
assert_eq "real USB edit preserves host stamp" "$(jq -r .config_version "$merged")" 2.0.0
out=$(
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON='[]'
    media_config_diff "$CV/media-live" "$merged"
)
assert_eq "USB diff shows only real setting" "$out" "  p2pool.pool: mini -> main"
rm -f "$merged"

# Recovery from an unreadable running config still ignores the stick's stamp.
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$CV/no-running-config" "$CV/media-candidate"
)
assert_eq "USB recovery drops supplied stamp" "$(jq 'has("config_version")' "$merged")" false
assert_eq "USB recovery retains real setting" "$(jq -r .p2pool.pool "$merged")" main
rm -f "$merged"
