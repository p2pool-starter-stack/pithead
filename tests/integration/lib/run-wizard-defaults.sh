# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# Exercise the real CLI wizard and setup against the candidate stack. Wallets come from
# the baseline; the runner owns restoration of the deployment after this lifecycle phase.
run_cli_wizard_defaults() {
    local monero tari cfg out rc expected
    monero=$(jq -r '.monero.wallet_address' <<<"$BASELINE_JSON")
    tari=$(jq -r '.tari.wallet_address // ""' <<<"$BASELINE_JSON")
    out=$(rx "source $(quote_arg "$IT_PITHEAD")
        CONFIG_FILE=\"\$PWD/.itest-wizard-defaults.json\"
        wizard_tari_disk_default local >/dev/null
        {
            printf '%s\\n\\n\\n' $(quote_arg "$monero")
            [ \"\$WIZ_TARI_DEFAULT\" = off ] || printf '%s\\n' $(quote_arg "$tari")
            printf '\\n\\n\\n\\n\\n\\n\\n'
        } | { wizard_ask_core; wizard_ask_shape; wizard_write_config; }
        jq -e '.xvb.enabled == false and .monero.clearnet_initial_sync == false and
            .tari.clearnet_initial_sync == false and (.dashboard.auth.password | length) == 32' .itest-wizard-defaults.json >/dev/null")
    rc=$?
    assert_rc "fresh CLI wizard writes no XvB, Tor sync and a generated dashboard password" "$rc" 0
    [ "$rc" = 0 ] || return 1
    cfg=$(rx 'cat .itest-wizard-defaults.json')
    expected=$(rx "source $(quote_arg "$IT_PITHEAD"); wizard_tari_disk_default local >/dev/null; printf '%s' \"\$WIZ_TARI_DEFAULT\"")
    assert_eq "fresh CLI Tari answer follows the measured data disk" "$(jq -r '.tari.mode' <<<"$cfg")" "$expected"
    assert_eq "fresh CLI generated password is printed once" "$(grep -Fc "$(jq -r '.dashboard.auth.password' <<<"$cfg")" <<<"$out")" 1
    push_config "$cfg" || return 1
    rx "sed -i 's/^DEPLOYMENT_COMPLETED=.*/DEPLOYMENT_COMPLETED=false/' .env && grep -qx 'DEPLOYMENT_COMPLETED=false' .env" || return 1
    out=$(rx "printf '\\nn\\n' | $IT_PITHEAD setup --skip-deps --skip-optimize" 2>&1)
    rc=$?
    assert_rc "fresh CLI defaults complete real setup" "$rc" 0
    assert_contains "fresh CLI defaults reach completed preparation" "$out" "Deployment preparation complete"
    rx 'rm -f .itest-wizard-defaults.json'
    pithead up >/dev/null 2>&1
    assert_rc "fresh CLI defaults start their rendered services" "$?" 0
    wait_status_ok 300
    assert_rc "fresh CLI defaults report a healthy stack" "$?" 0
    # Keep the general lifecycle's secret-preservation tests on their original fixture.
    push_config "$BASELINE_JSON" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 300
    assert_rc "CLI defaults proof restores the baseline config for lifecycle" "$?" 0
}
