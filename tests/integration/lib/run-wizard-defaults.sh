# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
run_cli_wizard_defaults() {
    local monero tari entry_config trial_rc=0 restore_rc=0 failures_before
    monero=$(jq -er '.monero.wallet_address | select(type == "string" and length > 0)' <<<"${BASELINE_CONFIG:-null}") || {
        it_fail "CLI defaults fixture supplies a Monero wallet"
        return 1
    }
    tari=$(jq -r '.tari.wallet_address // ""' <<<"$BASELINE_CONFIG") || {
        it_fail "CLI defaults fixture has a readable Tari section"
        return 1
    }
    if ! entry_config=$(rx 'cat config.json') || ! jq -e 'type == "object"' <<<"$entry_config" >/dev/null 2>&1; then
        it_fail "CLI defaults entry configuration readable" "cannot save the configuration active before the trial"
        return 1
    fi
    failures_before=$IT_FAIL
    cli_wizard_defaults_trial "$monero" "$tari" || trial_rc=$?
    if [ "$trial_rc" -ne 0 ] && [ "$IT_FAIL" -eq "$failures_before" ]; then
        it_fail "CLI defaults trial completed" "fixture preparation or deployment failed"
    fi
    if ! rx 'rm -f .itest-wizard-defaults.json'; then
        it_fail "CLI defaults removes its temporary configuration" "fixture cleanup failed"
        trial_rc=1
    fi
    lifecycle_gate_sample before-wizard-restore
    push_config "$entry_config" && pithead apply -y >/dev/null 2>&1
    restore_rc=$?
    lifecycle_gate_sample after-wizard-restore-apply
    if [ "$restore_rc" -eq 0 ]; then
        wait_status_ok 300
        restore_rc=$?
    fi
    assert_rc "CLI defaults proof restores its entry config for lifecycle" "$restore_rc" 0
    [ "$trial_rc" -eq 0 ] && [ "$restore_rc" -eq 0 ] && [ "$IT_FAIL" -eq "$failures_before" ]
}

cli_wizard_defaults_trial() {
    local monero="$1" tari="$2" cfg out rc
    run_cli_wizard_eof "$monero" "$tari" || return 1
    out=$(rx "PITHEAD_CONFIG_FILE=\"\$PWD/.itest-wizard-defaults.json\"
        source $(quote_arg "$IT_PITHEAD")
        wizard_tari_disk_default local >/dev/null
        {
            printf 'garbage\\n%s\\n\\n2\\ngarbage\\n%s\\n' $(quote_arg "$monero") $(quote_arg "$tari")
            printf '\\n\\n\\n\\n\\n\\n\\n'
        } | { wizard_ask_core; wizard_ask_shape; wizard_write_config; }
        jq -e '.xvb.enabled == false and .monero.clearnet_initial_sync == false and
            .tari.mode == \"local\" and .dashboard.tari_required == false and
            .tari.clearnet_initial_sync == false and (.dashboard.auth.password | length) == 32' .itest-wizard-defaults.json >/dev/null" 2>&1)
    rc=$?
    assert_rc "fresh CLI wizard writes the explicit Tari yes, no XvB, Tor sync and a generated dashboard password" "$rc" 0
    [ "$rc" = 0 ] || return 1
    assert_eq "CLI wizard retries a malformed Monero payout" "$([[ "$out" == *"Not a valid Monero primary address"* ]] && echo true || echo false)" true
    assert_eq "CLI wizard retries a malformed Tari payout" "$([[ "$out" == *"Not a valid Tari address"* ]] && echo true || echo false)" true
    cfg=$(rx 'cat .itest-wizard-defaults.json') || return 1
    assert_eq "CLI wizard saves the valid Monero payout after retry" "$([[ "$(jq -r '.monero.wallet_address' <<<"$cfg")" = "$monero" ]] && echo true || echo false)" true
    assert_eq "CLI wizard saves the valid Tari payout after retry" "$([[ "$(jq -r '.tari.wallet_address' <<<"$cfg")" = "$tari" ]] && echo true || echo false)" true
    assert_eq "fresh CLI Tari answer is the explicit yes" "$(jq -r '.tari.mode' <<<"$cfg")" "local"
    assert_eq "fresh CLI generated password is printed once" "$(grep -Fc "$(jq -r '.dashboard.auth.password' <<<"$cfg")" <<<"$out")" 1
    cfg=$(jq --argjson baseline "$BASELINE_CONFIG" '
        reduce ["monero", "tari", "p2pool", "dashboard", "tor"][] as $service (.;
            if $baseline[$service].data_dir then .[$service].data_dir = $baseline[$service].data_dir else . end)
        | reduce ["monero", "tari"][] as $node (.;
            if ($baseline[$node].mode // "local") != "local" then .[$node] = $baseline[$node] else . end)
    ' <<<"$cfg") || return 1
    push_config "$cfg" || return 1
    rx "sed -i 's/^DEPLOYMENT_COMPLETED=.*/DEPLOYMENT_COMPLETED=false/' .env && grep -qx 'DEPLOYMENT_COMPLETED=false' .env" || return 1
    out=$(rx "printf '\\nn\\n' | $IT_PITHEAD setup --skip-deps --skip-optimize" 2>&1)
    rc=$?
    assert_rc "fresh CLI defaults complete real setup" "$rc" 0
    [ "$rc" = 0 ] || return "$rc"
    assert_contains "fresh CLI defaults reach completed preparation" "$out" "Deployment preparation complete"
    rx "set -e
        source ./pithead
        test ! -e .itest-first-run-done
        had_marker=false
        if [ -e \"\$FIRST_RUN_MARKER\" ]; then
            mv \"\$FIRST_RUN_MARKER\" .itest-first-run-done
            had_marker=true
        fi
        trap 'rm -f \"\$FIRST_RUN_MARKER\"; if [ \"\$had_marker\" = true ]; then mv .itest-first-run-done \"\$FIRST_RUN_MARKER\"; fi' EXIT
        out=\$($IT_PITHEAD up 2>&1)
        [ -f \"\$FIRST_RUN_MARKER\" ]
        chains=Monero
        if [ \"\$(env_get TARI_REQUIRED)\" != false ]; then chains='Monero and Tari'; fi
        [[ \"\$out\" == *\"The miner is held until the initial sync finishes for \$chains, then starts automatically.\"* ]]
        out=\$($IT_PITHEAD restart 2>&1)
        [[ \"\$out\" != *'What happens next:'* ]]" >/dev/null 2>&1
    rc=$?
    assert_rc "fresh CLI first-start names required chains and restart suppresses the note" "$rc" 0
    [ "$rc" = 0 ] || return "$rc"
    lifecycle_gate_sample after-wizard-up
    wait_status_ok 300
    rc=$?
    assert_rc "fresh CLI defaults report a healthy stack" "$rc" 0
    return "$rc"
}
