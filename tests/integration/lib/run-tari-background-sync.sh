# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

run_tari_background_sync() {
    # Only a local Tari baseline can prove off -> local without changing the node fixture.
    if [ "$(env_on_box TARI_MODE)" != local ]; then
        it_skip_leg "Tari-only apply keeps Monero mining (#3094)" "requires a local Tari baseline" "missing"
        return 0
    fi
    local saved_config proxy_start deadline state syncing_hashes=0 synced=0 failed=0 previous_hashes="" hashes height_before
    height_before="$(jq_get "$(api_state)" '.tari.height | tonumber')"
    [[ "$height_before" =~ ^[0-9]+$ ]] || {
        it_fail "pre-enable Tari template height is readable (#3094)" "no numeric template baseline"
        return 1
    }
    saved_config="$(rx 'cat config.json')" || return 1
    if ! push_config "$(render_scenario_config "$saved_config" 'tari.mode=off' 'dashboard.tari_required=true')" ||
        ! pithead apply -y >/dev/null 2>&1 || ! wait_stratum_hashes 240; then
        it_fail "Tari-off baseline is mining (#3094)" "apply or worker/hash readiness failed"
        failed=1
    else
        proxy_start="$(rx "docker inspect --format '{{.State.StartedAt}}' xmrig-proxy")"
        if [ -z "$proxy_start" ]; then
            it_fail "Tari-off proxy start is readable (#3094)" "container inspection failed"
            failed=1
        else
            # Let the dashboard persist the earned release and the stopped chain fall behind.
            # No chain files are removed or rewritten; this is a warm-chain catch-up trial.
            sleep 90
            if ! push_config "$(render_scenario_config "$saved_config" 'tari.mode=local' 'dashboard.tari_required=true')" ||
                ! pithead apply -y >/dev/null 2>&1; then
                it_fail "Tari off -> local applies (#3094)" "apply failed"
                failed=1
            else
                deadline=$(($(now_s) + 600))
                while [ "$(now_s)" -lt "$deadline" ]; do
                    if [ "$(svc_state_of "$(service_state xmrig-proxy)")" != running ] ||
                        [ "$(rx "docker inspect --format '{{.State.StartedAt}}' xmrig-proxy")" != "$proxy_start" ]; then
                        it_fail "xmrig-proxy stays up during Tari enable/sync (#3094)" "proxy stopped or restarted"
                        failed=1
                        break
                    fi
                    state="$(api_state)"
                    hashes="$(jq_get "$state" '.stratum.total_hashes')"
                    if [ "$(jq_get "$state" '.sync.tari.state')" = syncing ] &&
                        [ "$(jq_get "$state" '.proxy_workers')" -ge 1 ] 2>/dev/null &&
                        [[ "$hashes" =~ ^[0-9]+$ ]]; then
                        if [ -n "$previous_hashes" ] && [ "$hashes" -gt "$previous_hashes" ]; then syncing_hashes=1; fi
                        previous_hashes="$hashes"
                    else
                        previous_hashes=""
                    fi
                    if [ "$(jq_get "$state" '.sync.tari.state')" = "done" ] &&
                        [ "$(jq_get "$state" '.tari.connected')" = true ] &&
                        [ "$(jq_get "$state" '.tari.height | tonumber')" -gt "$height_before" ] 2>/dev/null; then
                        synced=1
                        break
                    fi
                    sleep 2
                done
                assert_eq "workers hash while newly enabled Tari syncs (#3094)" "$syncing_hashes" 1
                assert_eq "merge-mining templates arrive after Tari sync (#3094)" "$synced" 1
                [ "$syncing_hashes" = 1 ] && [ "$synced" = 1 ] || failed=1
                [ "$failed" = 1 ] || it_pass "xmrig-proxy stays up during Tari enable/sync (#3094)"
            fi
        fi
    fi
    if ! push_config "$saved_config" || ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
        it_fail "Tari enable trial restores its original config (#3094)" "restoration failed"
        return 1
    fi
    it_pass "Tari enable trial restores its original config (#3094)"
    [ "$failed" = 0 ]
}
