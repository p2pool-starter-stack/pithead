# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
run_lifecycle() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="lifecycle"
    local lifecycle_ok=1
    echo ""
    it_log "── lifecycle + failover phase ──────────────────────"

    # restart brings the stack back healthy.
    it_step "pithead restart…"
    pithead restart >/dev/null 2>&1
    wait_status_ok 240 || true
    pithead status >/dev/null 2>&1
    assert_rc "status OK after restart" "$?" "0"

    # #2654: a source checkout ups with --pull never, so a digest-pinned third-party image that is
    # gone from the engine (after `uninstall`, or on a new host) left its services down. Remove the
    # socket-proxy image (docker-proxy and docker-control, both profile-free) and prove `up` fetches it.
    if rx 'test -f dashboard/Dockerfile'; then
        local proxy_ref proxy_id proxy_fails="$IT_FAIL"
        proxy_ref="$(rx "docker compose config --images" 2>/dev/null | grep -m1 'docker-socket-proxy')"
        proxy_id="$(rx "docker image inspect --format '{{.Id}}' $(quote_arg "$proxy_ref")" 2>/dev/null)"
        it_step "removing the pinned socket-proxy image, then pithead up (#2654)…"
        if [ -n "$proxy_ref" ] && [ -n "$proxy_id" ] && pithead down >/dev/null 2>&1 &&
            rx "docker image rm -f $(quote_arg "$proxy_id")" >/dev/null 2>&1; then
            local up_out up_rc
            up_out="$(pithead up 2>&1)"
            up_rc=$?
            assert_rc "up on a source checkout succeeds with a pinned image missing (#2654)" "$up_rc" "0"
            # The failing pull or up names its cause; job 1280 lost it to /dev/null (#2755).
            [ "$up_rc" -eq 0 ] || printf '%s\n' "$up_out" | tail -n 15 | redact | sed 's/^/        /'
            rx "docker image inspect $(quote_arg "$proxy_ref")" >/dev/null 2>&1
            assert_rc "up fetched the missing pinned image (#2654)" "$?" "0"
            assert_eq "docker-proxy runs from the fetched image (#2654)" "$(svc_state_of "$(service_state docker-proxy)")" "running"
            if wait_status_ok 240; then
                it_pass "status OK after up restored a missing pinned image (#2654)"
            else
                it_fail "status OK after up restored a missing pinned image (#2654)" "pithead status did not recover"
            fi
            [ "$IT_FAIL" -le "$proxy_fails" ] || lifecycle_ok=0
        else
            it_fail "missing pinned image fixture armed (#2654)" "no socket-proxy image found, or down / image rm returned non-zero"
            lifecycle_ok=0
        fi
    else
        it_skip_leg "missing pinned image on up (#2654)" "release install: --pull missing fetches it" "by-design"
    fi

    # apply that changes the sidechain recreates only the affected containers, preserving
    # secrets. We flip main<->mini and assert the token/onions are untouched, then revert.
    local cur_pool fp_before
    cur_pool="$(jq_get "$BASELINE_CONFIG" '.p2pool.pool')"
    cur_pool="${cur_pool:-main}"
    local other
    [ "$cur_pool" = "mini" ] && other="main" || other="mini"
    fp_before="$(secret_fingerprint)"
    # ensure_owner whole-tree migration (#255): plant a root-owned file UNDER a data dir (the
    # root-container-era signature — user-owned dir, root-owned contents) and prove this apply chowns
    # it to the container uid, the exact regression MEMORY flags ("scan contents, not just the dir").
    # Piggybacks the pool-flip apply below, which always runs ensure_directories -> ensure_owner.
    # Local mode only (has data dirs); a stub can't create a foreign-uid inode, so this is tier-4.
    local own_dir own_probe=""
    if has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        own_dir="$(env_on_box DASHBOARD_DATA_DIR)"
        if [ -n "$own_dir" ]; then
            own_probe="$own_dir/.itest-owner-probe"
            it_step "planting a root-owned file under $own_dir to exercise ensure_owner (#255)…"
            rx "sudo touch $(quote_arg "$own_probe") && sudo chown 0:0 $(quote_arg "$own_probe")" >/dev/null 2>&1
        fi
    fi
    push_config "$(render_scenario_config "$BASELINE_CONFIG" "p2pool.pool=$other")"
    it_step "apply pool $cur_pool -> ${other}…"
    pithead apply -y >/dev/null 2>&1
    wait_status_ok 180 || true
    assert_eq "secrets preserved across pool change" "$(secret_fingerprint)" "$fp_before"
    # APP_UID is 1000 in pithead; the migrated contents must now be owned by it, not root.
    if [ -n "$own_probe" ]; then
        assert_eq "apply migrates root-owned CONTENTS to the container uid (#255)" \
            "$(rx "stat -c %u $(quote_arg "$own_probe") 2>/dev/null")" "1000"
        rx "sudo rm -f $(quote_arg "$own_probe")" >/dev/null 2>&1 || true
    fi
    # .pool.type lags a sidechain switch until peers on the new chain connect — wait + three-way
    # verdict, don't assert cold on a peer-timing state (#54, #687).
    assert_pool_switched "pool actually changed" "$(pool_label "$other")"

    # Node-down failover (#31): stop monerod -> status non-zero (node down), dashboard rejects
    # workers (xmrig-proxy stopped) -> start monerod -> readmitted -> status 0 again.
    if has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_step "stopping monerod to exercise node-down failover…"
        rx "docker compose stop monerod" >/dev/null 2>&1
        wait_for 120 5 "status to report node down" _pred_status_down || true
        pithead status >/dev/null 2>&1
        assert_rc "status non-zero when node down" "$?" "1"
        it_step "starting monerod and waiting for readmit…"
        rx "docker compose start monerod" >/dev/null 2>&1
        wait_status_ok 240 || true
        pithead status >/dev/null 2>&1
        assert_rc "status OK after node recovery" "$?" "0"
    else
        it_skip_leg "node-down failover" "remote mode: no local monerod to stop" "by-design"
    fi

    # backup → restore round-trip (#102): a backup archives config/.env/onions/dashboard; a
    # restore brings them back. We change the pool, restore, and assert the pool reverted and
    # every wallet/proxy/dashboard/RPC/onion secret survived exactly — the same per-category check
    # the rollback net makes (#2579), exercised here on a run that does not fail.
    it_step "backup → restore round-trip…"
    if pithead backup -y --no-encrypt >/dev/null 2>&1; then
        local arch
        arch="$(rx 'ls -t backups/pithead-backup-*.tar.gz 2>/dev/null | head -n1')"
        if [ -n "$arch" ]; then
            local fp_b backed_pool fp_after
            if ! fp_b="$(upgrade_secret_fingerprints)" || [ -z "$fp_b" ]; then
                it_fail "backup secrets fingerprint readable" "could not fingerprint backed-up secrets"
                lifecycle_ok=0
            elif ! backed_pool="$(jq_get "$(api_state)" '.pool.type')" || [ -z "$backed_pool" ]; then
                it_fail "backed-up pool state readable" "dashboard did not report pool.type before restore"
                lifecycle_ok=0
            # Diverge from the backed-up state, then restore it back.
            elif push_config "$(render_scenario_config "$BASELINE_CONFIG" "p2pool.pool=$other")" &&
                pithead apply -y >/dev/null 2>&1 &&
                pithead down >/dev/null 2>&1 &&
                pithead restore -y "$arch" >/dev/null 2>&1 &&
                pithead up >/dev/null 2>&1; then
                if wait_status_ok 240; then
                    it_pass "status OK after restore"
                else
                    it_fail "status OK after restore" "pithead status did not recover after backup restore"
                    lifecycle_ok=0
                fi
                # Operator ruling on #2626: `./pithead restore` is same-box recovery, not the
                # cross-hardware carry restore_apply() handles, so it must NOT hold the miner behind
                # the sync gate — this bench's chains never desynced. No marker, and p2pool comes
                # back up on `up`'s own schedule rather than sitting stopped behind a hold `status`
                # wouldn't flag (it treats a gate-stopped p2pool as intentional).
                local ddir
                ddir="$(env_on_box DASHBOARD_DATA_DIR)"
                if [ -n "$ddir" ]; then
                    assert_eq "restore plants no sync-gate marker (#2626, same-box recovery)" \
                        "$(rx "sudo test -e $(quote_arg "$ddir/sync-gate-reset")" 2>/dev/null && echo present || echo none)" none
                fi
                if wait_for 60 5 "p2pool running after restore, not held (#2626)" \
                    _pred_p2pool_running; then
                    it_pass "restore does not hold p2pool behind the sync gate (#2626)"
                else
                    it_fail "restore does not hold p2pool behind the sync gate (#2626)" \
                        "p2pool still not running 60s after restore+up"
                    lifecycle_ok=0
                fi
                # pool.type lags peer reconnect after restore+up — wait + three-way verdict, don't assert
                # cold on a peer-timing state (#54, #687).
                local failures_before="$IT_FAIL"
                assert_pool_switched "restore reverts the pool to the backed-up value" "$backed_pool"
                if fp_after="$(upgrade_secret_fingerprints)" && [ -n "$fp_after" ]; then
                    assert_eq "restore preserves secrets" "$fp_after" "$fp_b"
                else
                    it_fail "restore preserves secrets" "could not fingerprint restored secrets"
                fi
                [ "$IT_FAIL" -le "$failures_before" ] || lifecycle_ok=0
            else
                it_fail "backup restore round-trip succeeded" "apply, down, restore, or up returned non-zero"
                lifecycle_ok=0
            fi
            rx "rm -f $(quote_arg "$arch")" >/dev/null 2>&1 || true
        else
            it_fail "backup produced an archive" "no backups/pithead-backup-*.tar.gz"
            lifecycle_ok=0
        fi
    else
        it_fail "pithead backup succeeded" "backup returned non-zero"
        lifecycle_ok=0
    fi

    # Confirmed dashboard.data_dir carry (#2360): DASHBOARD_DATA_DIR is CONFIRM-class both from
    # the dashboard (typed APPLY) and the host CLI (folded into the disruptive y/N, exercised here
    # with -y) — same apply()-time carry either way. Without it the recreated dashboard would open
    # an EMPTY DB at the new path and silently re-seed the payout-wallet tripwire baseline (#375)
    # on the next observation. Local mode only: remote mode has no local data dir to move.
    if has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        local carry_old carry_new carry_epoch rows_before rows_after
        carry_old="$(env_on_box DASHBOARD_DATA_DIR)"
        if [ -n "$carry_old" ]; then
            carry_epoch="$(rx 'date +%s')"
            carry_new="${carry_old}-carried-$carry_epoch"
            # kv_store-volatile-shape is left out: the recreated dashboard rewrites those live keys
            # within seconds, so their shape reflects what the new process has seen, not what was
            # carried. The kv_store-key lines still require every key to arrive.
            rows_before="$(dashboard_durable_rows "$carry_epoch" | grep -v '^kv_store-volatile-shape ')"
            it_step "confirmed dashboard.data_dir move: $carry_old -> ${carry_new}…"
            push_config "$(render_scenario_config "$BASELINE_CONFIG" "dashboard.data_dir=$carry_new")"
            if pithead apply -y >/dev/null 2>&1 && wait_status_ok 180; then
                assert_eq "DASHBOARD_DATA_DIR points at the new path" "$(env_on_box DASHBOARD_DATA_DIR)" "$carry_new"
                rows_after="$(dashboard_durable_rows "$carry_epoch" | grep -v '^kv_store-volatile-shape ')"
                if telemetry_rows_continue "$rows_before" "$rows_after"; then
                    it_pass "durable rows (incl. the kv_store payout-wallet baseline, #375) survived the carry"
                else
                    it_fail "durable rows (incl. the kv_store payout-wallet baseline, #375) survived the carry" "rows diverged after the move ($(telemetry_rows_diff "$rows_before" "$rows_after"))"
                    lifecycle_ok=0
                fi
            else
                it_fail "dashboard.data_dir carry applied and returned healthy" "apply failed or the recreated stack did not become healthy"
                lifecycle_ok=0
            fi
            # The product correctly refuses to overwrite the old, still-complete directory on a
            # reverse move. Stop first and remove only this test's verified copy, so suite cleanup
            # can return to its original configuration without discarding the source database.
            if pithead down >/dev/null 2>&1 && rx "rm -rf -- $(quote_arg "$carry_new")" >/dev/null 2>&1 &&
                push_config "$BASELINE_CONFIG" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 180; then
                it_pass "dashboard carry cleanup restored its baseline safely"
            else
                it_fail "dashboard carry cleanup restored its baseline safely" "the stack was not stopped, its test copy was not removed, or the baseline did not return healthy"
                lifecycle_ok=0
            fi
        else
            it_skip_leg "confirmed dashboard.data_dir carry" "DASHBOARD_DATA_DIR is unset on the box" "by-design"
        fi
    else
        it_skip_leg "confirmed dashboard.data_dir carry" "remote mode: no local data dir to move" "by-design"
    fi
    run_uninstall_round_trip || lifecycle_ok=0
    [ "$lifecycle_ok" = 1 ]
}

# A remote snippet printing one sorted line per entry under the given paths (#2379): a sha256 for
# every regular file up to 64 MiB, and for a larger one (the chains' LMDB files, hundreds of GiB
# on a synced box, an hour per hashing pass) its inode, size, mtime and ctime to the nanosecond.
# Any write to a file moves its mtime and ctime, and ctime cannot be set back from userspace, so
# an unchanged line proves no byte of that file was written. Directories and links print their
# type, so a removed or added entry shows too. pipefail makes an unreadable path a failed probe,
# never an empty snapshot that equals another empty one. -H descends a kept dir that is itself a
# symlink (a chain on another disk). KEPT_SNAPSHOT_SUDO is the selftest seam.
kept_data_snapshot_snippet() { # <path>...
    local p paths=""
    for p in "$@"; do paths="$paths $(quote_arg "$p")"; done
    printf '%s' "set -o pipefail; ${KEPT_SNAPSHOT_SUDO-sudo -n} find -H$paths \\( -type f -size +65536k -printf 'meta %i %s %T@ %C@ %p\\n' \\) -o \\( -type f -exec sha256sum {} + \\) -o -printf '%y %p -> %l\\n' | LC_ALL=C sort"
}

# The same paths' LMDB files as inode, birth time to the nanosecond and path: a chain that was
# reused keeps all three, one re-created by a resync gets a new birth time even when the
# filesystem hands the freed inode number straight back. Only *.mdb: a log rotates into new
# inodes while the node runs, which says nothing about the chain.
kept_chain_files_snippet() { # <path>...
    local p paths=""
    for p in "$@"; do paths="$paths $(quote_arg "$p")"; done
    printf '%s' "set -o pipefail; ${KEPT_SNAPSHOT_SUDO-sudo -n} find -H$paths -type f -name '*.mdb' -exec stat -c '%i %.9W %n' {} + | LC_ALL=C sort"
}

# uninstall -> setup round trip (#2379): uninstall removes the named volumes and every derived
# path, keeps every *_DATA_DIR, config.json and backups/ byte-identical, and a setup after it
# re-provisions from what was kept (and the harness's own secrets). The stack is stopped BEFORE the first snapshot: a running
# monerod writes its LMDB, log and peer state continuously, and its own shutdown flushes them, so
# a snapshot of a live node can never match anything (job 680). Stopped, the daemons write
# nothing, and uninstall's own code must then change zero bytes: the allowlist of permitted writes
# is empty. Always ends by bringing a stack back up, so the phases after this one have one.
run_uninstall_round_trip() {
    local fails_before="$IT_FAIL" key p kept=() derived=() snippet before after out rc onion_before big_before big_after
    it_step "pithead uninstall keeps every byte of data, then setup re-provisions from it…"
    for key in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR TOR_DATA_DIR; do
        p="$(env_on_box "$key")"
        [ -n "$p" ] && rx "test -e $(quote_arg "$p")" && kept+=("$p")
    done
    kept+=(config.json)
    rx 'test -e backups' && kept+=(backups)
    for key in CONTROL_DIR CLEARNET_STATE_DIR CADDY_LOG_DIR PROXY_TLS_DIR; do
        p="$(env_on_box "$key")"
        [ -n "$p" ] && derived+=("$p")
    done
    derived+=(data/tari-wallet-secret.env .env)
    onion_before="$(env_on_box MONERO_ONION_ADDRESS)"
    local local_node=""
    has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node && local_node=1
    snippet="$(kept_data_snapshot_snippet "${kept[@]}")"
    if ! pithead down >/dev/null 2>&1 || ! rx 'cp -p .env .env.itest-round-trip' ||
        ! before="$(rx "$snippet")" || [ -z "$before" ] ||
        ! big_before="$(rx "$(kept_chain_files_snippet "${kept[@]}")")"; then
        it_fail "stopped stack snapshot readable before uninstall" "pithead down or the kept-data snapshot failed"
        rx 'rm -f .env.itest-round-trip'
        pithead up >/dev/null 2>&1
        wait_status_ok 240 || true
        return 1
    fi
    out="$(pithead uninstall -y 2>&1)"
    rc=$?
    assert_rc "pithead uninstall -y succeeded" "$rc" "0"
    assert_contains "uninstall states the removed column" "$out" "Removed:"
    assert_contains "uninstall states the kept column" "$out" "Kept (yours):"
    assert_contains "uninstall states the left-behind column" "$out" "Left behind"
    assert_contains "uninstall prints the removal command" "$out" "sudo rm -rf"
    if after="$(rx "$snippet")" && [ "$after" = "$before" ]; then
        it_pass "uninstall leaves every kept path byte-identical (no allowed writes)"
    else
        it_fail "uninstall leaves every kept path byte-identical (no allowed writes)" \
            "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^[<>]' | head -n 12)"
    fi
    local vols
    if vols="$(rx "docker volume ls -q")"; then
        assert_eq "uninstall removes the caddy_data, wallet_data and tari_wallet_data volumes" \
            "$(printf '%s\n' "$vols" | grep -E '^pithead_(caddy_data|wallet_data|tari_wallet_data)$')" ""
    else
        it_fail "uninstall removes the caddy_data, wallet_data and tari_wallet_data volumes" "docker volume ls failed"
    fi
    local left=""
    for p in "${derived[@]}"; do rx "test -e $(quote_arg "$p")" && left="$left $p"; done
    assert_eq "uninstall removes every derived path and .env" "$left" ""

    # An operator's setup here generates the secrets that lived only in .env anew (docs/operations.md).
    # The harness puts its own back, minus the completion flag setup refuses to re-run over, because
    # the phases after this one and the end-of-run restore check the baseline's secrets, and a Tari
    # wallet volume created under a new password would not open under the restored old one.
    rx "grep -v '^DEPLOYMENT_COMPLETED=' .env.itest-round-trip >.env && rm -f .env.itest-round-trip"
    # A source checkout (every bench box) runs `compose up --pull never`, which cannot bring back
    # the pinned third-party images uninstall just removed; `missing` is what a release install,
    # the channel uninstall serves, runs anyway (01-lifecycle.sh resolve_pull_policy; #2654).
    it_step "pithead setup re-provisions from the kept config…"
    out="$(rx "PITHEAD_PULL=missing $IT_PITHEAD setup --skip-deps --skip-optimize" 2>&1)"
    rc=$?
    assert_rc "setup after uninstall succeeded" "$rc" "0"
    [ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -n 15 | redact | sed 's/^/        /'
    if wait_status_ok 600; then
        it_pass "status OK after setup-after-uninstall"
    else
        it_fail "status OK after setup-after-uninstall" "pithead status did not recover within 600s"
    fi
    # The chains' large files are the same files after setup, and the kept Tor keys give back the
    # same onion address.
    if [ -n "$local_node" ]; then
        big_after="$(rx "$(kept_chain_files_snippet "${kept[@]}")")"
        if [ -n "$big_before" ] && [ "$big_after" = "$big_before" ]; then
            it_pass "setup after uninstall reuses the kept chain files"
        else
            it_fail "setup after uninstall reuses the kept chain files" "a chain file changed inode or birth time, or none was found"
        fi
    else
        it_skip_leg "setup after uninstall reuses the kept chain files" "remote mode: no local chain" "by-design"
    fi
    assert_eq "setup after uninstall keeps the Monero onion address" "$(env_on_box MONERO_ONION_ADDRESS)" "$onion_before"
    [ "$IT_FAIL" -le "$fails_before" ]
}

# Table names and counts only (never row values): which families lost rows, and whether either probe
# came back empty — an empty snapshot is a probe failure, not a divergence.
telemetry_rows_diff() { # <before-lines> <after-lines>
    local missing
    missing="$(comm -23 <(printf '%s\n' "$1" | sort) <(printf '%s\n' "$2" | sort) | awk 'NF {print $1}' | sort | uniq -c | awk '{printf " %s x%s", $2, $1}')"
    printf 'before=%s after=%s missing:%s' "$(printf '%s' "$1" | grep -c .)" "$(printf '%s' "$2" | grep -c .)" "${missing:- none}"
}

_pred_status_down() { ! pithead status >/dev/null 2>&1; }
# --- Fault-injection phase (--fault-injection) ------------------------------
# Break local monerod three ways, assert status/failover, then restore; opt-in because debounces are slow.
_monerod_is() { # _monerod_is <state> [<health>]
    local s
    s="$(service_state monerod)"
    [ "$(svc_state_of "$s")" = "$1" ] && { [ -z "${2:-}" ] || [ "$(svc_health_of "$s")" = "$2" ]; }
}
_pred_monerod_missing() { _monerod_is missing; }
_pred_monerod_unhealthy() { _monerod_is running unhealthy; }
_pred_monerod_healthy() { _monerod_is running healthy; }
_pred_proxy_stopped() { [ "$(svc_state_of "$(service_state xmrig-proxy)")" != "running" ]; }
_pred_failover_armed() {
    # `/api/state` never carried the raw monero_sync/miner_released/workers_rejected fields
    # (docs/dev/testing-strategy.md §F: this class of internal state is surfaced through
    # `sync.monero.state` and the badges list, never as its own machine-queryable booleans) —
    # so read the same contract the dashboard's own client reads, not internal names that were
    # never part of the response.
    local st badges
    st="$(api_state)"
    badges="$(jq_get "$st" '.badges | map(.text) | join("")')"
    [ "$(jq_get "$st" '.sync.monero.state')" = "done" ] &&
        [[ "$badges" != *"Miner held"* ]] &&
        [[ "$badges" != *"Workers rejected"* ]] &&
        [ "$(svc_state_of "$(service_state xmrig-proxy)")" = "running" ]
}
_pred_p2pool_running() { [ "$(svc_state_of "$(service_state p2pool)")" = "running" ]; }
_pred_tor_stopped() { [ "$(svc_state_of "$(service_state tor)")" != "running" ]; }
_pred_tor_healthy() {
    local s
    s="$(service_state tor)"
    [ "$(svc_state_of "$s")" = "running" ] && { [ "$(svc_health_of "$s")" = "healthy" ] || [ "$(svc_health_of "$s")" = "none" ]; }
}
