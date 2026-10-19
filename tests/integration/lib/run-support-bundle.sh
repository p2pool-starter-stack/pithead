# shellcheck shell=bash disable=SC2034
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

run_support_bundle() {
    local dashboard_pass bot_token stratum_pass fixture before="$IT_FAIL" archive=""
    dashboard_pass="$(openssl rand -hex 24)" && stratum_pass="$(openssl rand -hex 24)" &&
        bot_token="123456:$(openssl rand -hex 24)" || return 1
    if [ -z "${SAFETY_ARCHIVE:-}" ]; then
        it_fail "support-bundle has a safety archive" "no credential was changed"
        return 1
    fi
    fixture="$(printf '%s' "$BASELINE_CONFIG" | jq --arg pass "$dashboard_pass" --arg stratum "$stratum_pass" --arg bot "$bot_token" '
        .dashboard.auth = {username: "admin", password: $pass} |
        .p2pool.stratum_password = $stratum |
        .telegram.enabled = false | .telegram.bot_token = $bot')" || return 1
    if push_config "$fixture" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 240; then
        it_pass "support-bundle fixture applied on a healthy live stack"
        local output rc
        output="$(pithead support-bundle 2>&1)"
        rc=$?
        assert_rc "support-bundle command succeeds on a live stack" "$rc" 0
        archive="$(printf '%s\n' "$output" | sed -n 's/.*Support bundle written: //p' | tail -n 1)"
        if [ "$rc" = 0 ] && [ -n "$archive" ] &&
            printf '%s\n' "$dashboard_pass" "$stratum_pass" "$bot_token" | jq -Rs 'split("\n")[:-1]' |
            rx "python3 -c $(quote_arg "$(cat "$HERE/lib/support-bundle-check.py")") $(quote_arg "$archive")" --stdin >/dev/null 2>&1; then
            it_pass "support-bundle is private, complete and contains none of the three fixture credentials"
        else
            it_fail "support-bundle is private, complete and contains none of the three fixture credentials" "collection or archive verification failed"
        fi
    else
        it_fail "support-bundle fixture applied on a healthy live stack" "config, apply or bounded health check failed"
    fi
    if ! safety_restore_exact; then
        SAFETY_RESTORE_FAILED=1
        it_fail "support-bundle restores the exact baseline credentials and stack" "safety restoration failed; archive retained"
        return 1
    fi
    _SAFETY_RESTORE_ARMED=1
    it_pass "support-bundle restores the exact baseline credentials and stack"
    case "$archive" in
    */support-bundle-*.tar.gz) rx "rm -f -- $(quote_arg "$archive")" || return 1 ;;
    esac
    [ "$IT_FAIL" -eq "$before" ]
}
