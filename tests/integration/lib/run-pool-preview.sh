# shellcheck shell=bash disable=SC2034
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
run_p2pool_preview() {
    IT_CURRENT_SCENARIO="p2pool-preview"
    local preview preview_rc before="$IT_FAIL" expected clearnet invocation
    invocation="${IT_PITHEAD/#sudo /sudo --preserve-env=PITHEAD_CONFIG_FILE }"
    clearnet="$(rx "jq -r '.p2pool.clearnet // false' config.json")" || {
        it_fail "P2Pool preview fixture reads the current route (#3382)"
        return 1
    }
    if [ "$clearnet" = true ]; then
        expected="P2Pool sidechain peers back on Tor"
    else
        expected="P2Pool sidechain peers over CLEARNET"
    fi
    preview="$(rx "
        candidate=\$(mktemp) || exit 1
        trap 'rm -f \"\$candidate\"' EXIT
        jq '.p2pool.clearnet = ((.p2pool.clearnet // false) | not)' config.json >\"\$candidate\" || exit 1
        PITHEAD_CONFIG_FILE=\"\$candidate\" $invocation apply --dry-run --porcelain" 2>&1)"
    preview_rc=$?
    assert_rc "P2Pool route-only dry-run succeeds (#3382)" "$preview_rc" "0"
    assert_contains "P2Pool route-only preview retains the exposure row (#3382)" "$preview" "$expected"
    assert_contains "P2Pool route-only preview describes routing (#3382)" "$preview" "P2Pool peer routing changed"
    case "$preview" in
    *PPLNS* | *"sidechain changing"*) it_fail "P2Pool route-only preview keeps the sidechain and window (#3382)" "routing edit claimed a sidechain switch or window reset" ;;
    *) it_pass "P2Pool route-only preview keeps the sidechain and window (#3382)" ;;
    esac
    [ "$IT_FAIL" -eq "$before" ]
}

_pred_p2pool_extra_flag() {
    [ "$(service_state p2pool)" = 'running healthy' ] &&
        rx "docker compose logs --no-color --tail=200 p2pool" 2>/dev/null |
        grep -E '\[p2pool-entrypoint\] launching: .*--loglevel 3( |$)' >/dev/null
}

run_p2pool_extra_flags() {
    local IT_CURRENT_SCENARIO="p2pool-extra-flags"
    local saved candidate before="$IT_FAIL"
    saved=$(rx 'cat config.json') || {
        it_fail "P2Pool expert flag fixture reads the current config"
        return 1
    }
    candidate=$(printf '%s' "$saved" | jq '.p2pool.extra_flags=["--loglevel 3"]') || return 1
    if push_config "$candidate" && pithead apply -y >/dev/null 2>&1; then
        if wait_for 180 5 "P2Pool healthy with an expert launch option" _pred_p2pool_extra_flag; then
            it_pass "P2Pool expert flag starts healthy and appears in its logged launch arguments"
        else
            it_fail "P2Pool expert flag starts healthy and appears in its logged launch arguments"
        fi
    else
        it_fail "P2Pool expert flag applies through the config renderer"
    fi
    if push_config "$saved" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 240; then
        it_pass "P2Pool expert flag fixture restores the original configuration"
    else
        it_fail "P2Pool expert flag fixture restores the original configuration"
    fi
    [ "$IT_FAIL" -eq "$before" ]
}
