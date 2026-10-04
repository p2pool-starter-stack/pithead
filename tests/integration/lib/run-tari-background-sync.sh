# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

tari_enable_snapshot() { # <phase>: allowlisted, bounded evidence; no env/config dump
    printf 'phase=%s\n' "$1"
    rx "docker inspect --format '{{.Name}} id={{.Id}} state={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}}' xmrig-proxy p2pool dashboard tari" 2>&1 | redact
    api_state | jq '{timestamp, proxy_workers, hashes: .stratum.total_hashes, sync: {monero: .sync.monero.state, tari: .sync.tari.state}, tari: (.tari | {active, connected, height}), badges: [.badges[]? | {text}]}' | redact
}

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
    local evidence="$OUT_DIR/tari-enable" current_start current_state continuity_failed=0 continuity_checks=0
    mkdir -p "$evidence" || return 1
    tari_enable_snapshot before-off >"$evidence/snapshots.log"
    if ! push_config "$(render_scenario_config "$saved_config" 'tari.mode=off' 'dashboard.tari_required=true')" ||
        ! pithead apply -y >"$evidence/off.apply.log" 2>&1 || ! wait_stratum_hashes 240; then
        it_fail "Tari-off baseline is mining (#3094)" "apply or worker/hash readiness failed"
        failed=1
    else
        proxy_start="$(rx "docker inspect --format '{{.State.StartedAt}}' xmrig-proxy")"
        tari_enable_snapshot after-off >>"$evidence/snapshots.log"
        if [ -z "$proxy_start" ]; then
            it_fail "Tari-off proxy start is readable (#3094)" "container inspection failed"
            failed=1
        else
            # Let the dashboard persist the earned release and the stopped chain fall behind.
            # No chain files are removed or rewritten; this is a warm-chain catch-up trial.
            sleep 90
            tari_enable_snapshot before-enable >>"$evidence/snapshots.log"
            if ! push_config "$(render_scenario_config "$saved_config" 'tari.mode=local' 'dashboard.tari_required=true')" ||
                ! pithead apply -y >"$evidence/on.apply.log" 2>&1; then
                it_fail "Tari off -> local applies (#3094)" "apply failed"
                failed=1
            else
                tari_enable_snapshot after-enable >>"$evidence/snapshots.log"
                deadline=$(($(now_s) + 600))
                while [ "$(now_s)" -lt "$deadline" ]; do
                    continuity_checks=$((continuity_checks + 1))
                    current_state="$(svc_state_of "$(service_state xmrig-proxy)")"
                    current_start="$(rx "docker inspect --format '{{.State.StartedAt}}' xmrig-proxy")"
                    if [ "$current_state" != running ] || [ "$current_start" != "$proxy_start" ]; then
                        it_fail "xmrig-proxy stays up during Tari enable/sync (#3094)" "proxy stopped or restarted"
                        printf 'proxy continuity: state=%s expected_start=%s actual_start=%s\n' "$current_state" "$proxy_start" "$current_start" >>"$evidence/snapshots.log"
                        tari_enable_snapshot continuity-failure >>"$evidence/snapshots.log"
                        failed=1
                        continuity_failed=1
                        break
                    fi
                    state="$(api_state)"
                    printf '%s\n' "$state" | jq -c --argjson observed "$(now_s)" \
                        '{observed, workers: .proxy_workers, hashes: .stratum.total_hashes, tari_sync: (.sync.tari | {state, current, target, percent}), template: (.tari | {connected, height})}' | redact >>"$evidence/samples.jsonl"
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
                if [ "$continuity_failed" = 0 ]; then
                    if [ "$continuity_checks" -gt 0 ]; then
                        it_pass "xmrig-proxy stays up during Tari enable/sync (#3094)"
                    else
                        it_fail "xmrig-proxy stays up during Tari enable/sync (#3094)" "no continuity samples"
                        failed=1
                    fi
                fi
                tari_enable_snapshot trial-finish >>"$evidence/snapshots.log"
                if [ "$failed" = 1 ]; then
                    rx 'docker logs --tail 100 dashboard' 2>&1 | redact >"$evidence/dashboard.log"
                    capture_artifacts "tari-enable" "$OUT_DIR"
                fi
            fi
        fi
    fi
    tari_enable_snapshot before-restore >>"$evidence/snapshots.log"
    if ! push_config "$saved_config" || ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
        it_fail "Tari enable trial restores its original config (#3094)" "restoration failed"
        return 1
    fi
    tari_enable_snapshot after-restore >>"$evidence/snapshots.log"
    it_pass "Tari enable trial restores its original config (#3094)"
    [ "$failed" = 0 ]
}
