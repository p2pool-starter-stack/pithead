# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

run_support_bundle() {
    local saved changed nonce snapshot before after restoration_ok=1 failures="$IT_FAIL"
    saved=$(rx 'cat config.json') || return 1
    nonce=$(openssl rand -hex 24) || return 1
    changed=$(printf '%s' "$saved" | jq --arg nonce "$nonce" '
        .dashboard.secure = true |
        .dashboard.auth.password = ("dashboard-" + $nonce) |
        .p2pool.stratum_password = ("stratum-" + $nonce) |
        .telegram.enabled = false |
        .telegram.bot_token = ("123456789:" + $nonce)') || return 1
    before=$(upgrade_secret_fingerprints) || return 1
    [ -n "$before" ] || return 1
    snapshot=$(rx 'set -e; umask 077; export TMPDIR="${TMPDIR:-$HOME}"; d=$(mktemp -d "$TMPDIR/support-bundle.XXXXXX"); if cp -p config.json "$d/config.json" && cp -p .env "$d/env"; then printf "%s" "$d"; else rm -f "$d/config.json" "$d/env"; rmdir "$d"; exit 1; fi') || return 1
    [ -n "$snapshot" ] || return 1
    if push_config "$changed" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 240; then
        it_pass "support-bundle credential fixture applied to a healthy stack"
        if rx "set -e
            umask 077
            export TMPDIR=\"\${TMPDIR:-\$HOME}\"
            marker=\$(mktemp \"\$TMPDIR/support-bundle-marker.XXXXXX\")
            trap 'find . -maxdepth 1 -name support-bundle-\\*.tar.gz -newer \"\$marker\" -exec rm -f {} +; rm -f \"\$marker\"' EXIT
            sleep 1
            timeout 180 $IT_PITHEAD support-bundle >/dev/null 2>&1
            archive=\$(find . -maxdepth 1 -name 'support-bundle-*.tar.gz' -newer \"\$marker\")
            test -n \"\$archive\"
            python3 - \"\$archive\" config.json .env" --stdin <"$(dirname "${BASH_SOURCE[0]}")/check-support-bundle.py"; then
            it_pass "live support-bundle is private, complete and contains no fixture credentials"
        else
            it_fail "live support-bundle is private, complete and contains no fixture credentials" "collection or archive inspection failed; contents withheld"
        fi
    else
        it_fail "support-bundle credential fixture applied to a healthy stack" "config, apply or bounded health check failed"
    fi
    if rx "cp -p $(quote_arg "$snapshot")/config.json config.json && cp -p $(quote_arg "$snapshot")/env .env" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 240; then
        after=$(upgrade_secret_fingerprints) || after=""
        if [ "$before" != "$after" ] || ! rx "cmp -s config.json $(quote_arg "$snapshot")/config.json"; then
            it_fail "support-bundle restores its starting configuration and stack health" "configuration or secret fingerprints changed"
            restoration_ok=0
        else
            it_pass "support-bundle restores its starting configuration and stack health"
        fi
    else
        it_fail "support-bundle restores its starting configuration and stack health" "restoration failed"
        restoration_ok=0
    fi
    rx "rm -f $(quote_arg "$snapshot")/config.json $(quote_arg "$snapshot")/env && rmdir $(quote_arg "$snapshot")" || return 1
    [ "$restoration_ok" -eq 1 ] && [ "$IT_FAIL" -eq "$failures" ]
}
