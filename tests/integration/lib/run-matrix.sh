# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
print_list() {
    echo "Scenarios:"
    local name rest
    while IFS=$'\t' read -r name rest; do
        printf '  %-32s %s\n' "$name" "$rest"
    done < <(scenario_matrix)
    echo ""
    echo "Axis coverage (every value below must appear at least once):"
    axis_coverage | sed 's/^/  /'
}

# --- Target I/O helpers (depend on globals set above) -----------------------
# Write a config.json onto the box from stdin-less arg.
push_config() {
    local json="$1"
    if [ "$IT_MODE" = "local" ]; then
        printf '%s\n' "$json" >"$IT_REMOTE_DIR/config.json"
    else
        printf '%s\n' "$json" | ssh "${IT_SSH_OPTS[@]}" "$IT_SSH_DEST" \
            "cd $(quote_arg "$IT_REMOTE_DIR") && cat > config.json"
    fi
}

# Read a single (non-secret) .env value off the box.
env_on_box() { rx "grep -E '^$1=' .env 2>/dev/null | head -n1 | cut -d= -f2-"; }

# Services currently running, one per line, sorted. Honours active compose profiles, so
# monerod is absent in remote mode.
running_services() { rx "docker compose ps --services --status running 2>/dev/null | sort"; }

# Print "<state> <health>" for one service, exactly as stack_status reads it: state is the
# container State.Status (running/exited/paused/restarting/…) and health is the healthcheck
# verdict (healthy/unhealthy/starting/none), or "missing none" when absent. The fault-injection
# predicates assert pithead's status verdicts against this.
service_state() {
    rx 'cid=$(docker compose ps -aq '"$1"' 2>/dev/null | head -n1); if [ -z "$cid" ]; then echo "missing none"; else docker inspect --format "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$cid" 2>/dev/null || echo "unknown none"; fi'
}

# A stable fingerprint of the secrets we must preserve across applies (proxy token + onion
# addresses). Hashed ON THE BOX so the plaintext never crosses the wire or hits a log.
secret_fingerprint() {
    rx "grep -Eq '^(PROXY_AUTH_TOKEN|[A-Z]+_ONION_ADDRESS)=' .env 2>/dev/null && grep -E '^(PROXY_AUTH_TOKEN|[A-Z]+_ONION_ADDRESS)=' .env | sort | sha256sum | cut -d' ' -f1"
}

# --- Preflight --------------------------------------------------------------
preflight() {
    it_log "Connecting to target ($IT_MODE${IT_SSH_DEST:+ $IT_SSH_DEST}) at $IT_REMOTE_DIR …"
    if ! rx "true" >/dev/null 2>&1; then
        it_err "Cannot reach the target. Check --host/--local, --dir, and SSH access."
        exit 1
    fi

    # The stack dir must contain a deployed pithead.
    if ! rx "test -x $IT_PITHEAD" >/dev/null 2>&1; then
        it_err "pithead not found/executable at $IT_REMOTE_DIR/$IT_PITHEAD (set --dir/--pithead)."
        exit 1
    fi
    if ! rx "grep -q '^DEPLOYMENT_COMPLETED=true' .env" >/dev/null 2>&1; then
        it_err "Box is not fully deployed (.env missing DEPLOYMENT_COMPLETED). Run 'pithead setup' there first."
        exit 1
    fi

    # Tools the harness leans on, on the box.
    local tool
    for tool in jq curl docker sha256sum; do
        if ! rx "command -v $tool" >/dev/null 2>&1; then
            it_err "Required tool '$tool' missing on the box."
            exit 1
        fi
    done

    # Start from a clean results dir: a prior run's per-scenario artifacts (e2e.sh preserves
    # results/ across runs) otherwise linger and read as THIS run's state when diagnosing a failure
    # — a stale capture from another branch bit us during the v1.4 gate (#454). Keep the dir itself
    # (callers may have pointed --out at it); wipe its contents.
    mkdir -p "$OUT_DIR"
    find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    record_manifest

    # Snapshot the baseline so we can restore it and compare secrets later.
    BASELINE_CONFIG="$(rx 'cat config.json')"
    BASELINE_PRUNE="$(env_on_box MONERO_PRUNE)" # 1 = pruned, 0 = full
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    BASELINE_SECRET_FP="$(secret_fingerprint)"
    # The coarse fingerprint proves "unchanged"; it cannot say WHICH category moved. The
    # destructive gates roll back against per-category wallet/proxy/dashboard/RPC/onion
    # fingerprints, so capture them up front whenever a rollback net is armed.
    if [ "$SAFETY_BACKUP" = 1 ]; then
        # shellcheck disable=SC2034 # read by run-safety.sh:safety_restore_exact and live-xvb-support.sh
        BASELINE_EXACT_SECRET_FP="$(upgrade_secret_fingerprints)" || {
            it_err "Could not fingerprint every wallet/proxy/dashboard/RPC/onion secret category."
            exit 1
        }
    fi
    if [ -z "$BASELINE_CONFIG" ]; then
        it_err "Could not read baseline config.json from the box."
        exit 1
    fi
    it_log "Baseline captured (prune=$BASELINE_PRUNE). Original config will be restored at the end."
}

# Record exactly what's under test, so a run is reproducible (#54 manifest).
record_manifest() {
    local f="$OUT_DIR/manifest.txt"
    {
        echo "# Pithead integration run manifest"
        echo "stack_version: $(rx 'cat VERSION 2>/dev/null' | tr -d '\n')"
        echo "git_rev:       $(rx 'git rev-parse --short HEAD 2>/dev/null' | tr -d '\n')"
        echo "target_mode:   $IT_MODE"
        echo "remote_dir:    $IT_REMOTE_DIR"
        echo "expected_workers: $EXPECTED_WORKERS"
        echo ""
        echo "# docker compose images"
        rx "docker compose images 2>/dev/null"
    } | redact >"$f" 2>/dev/null || true
    it_step "wrote run manifest to $f"
}

# --- Scenario execution -----------------------------------------------------
# resolve_overrides (the prerequisite gate that decides whether a scenario can run on this box,
# and never mutates the canonical chain) lives in lib.sh so the self-test can exercise it. It
# reads BASELINE_PRUNE / PRUNED_DATA_DIR / FULL_DATA_DIR / REMOTE_MONERO_HOST and sets the
# globals RESOLVED / SKIP_REASON.

run_scenario() {
    local name="$1" overrides="$2"
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="$name"
    echo ""
    it_log "── scenario: ${name} ───────────────────────────────"

    if ! resolve_overrides "$overrides"; then
        it_skip_scenario "$name" "$SKIP_REASON" "$SKIP_CLASS"
        return 0
    fi

    # Render + push config, then apply non-interactively.
    local config
    # shellcheck disable=SC2086  # RESOLVED is a space-separated list of override tokens, on purpose
    config="$(render_scenario_config "$BASELINE_CONFIG" $RESOLVED)"
    if ! printf '%s' "$config" | jq empty 2>/dev/null; then
        it_fail "rendered config is valid JSON" "jq rejected the rendered config"
        return 0
    fi
    push_config "$config"

    it_step "applying config (pithead apply -y)…"
    if ! pithead apply -y >"$OUT_DIR/${name}.apply.log" 2>&1; then
        it_fail "apply succeeded" "see $OUT_DIR/${name}.apply.log"
        capture_artifacts "$name" "$OUT_DIR"
        restore_firewall_after_clearnet "$name" "$config"
        return 0
    fi

    # Wait for the stack to settle on real readiness signals before asserting. The miner/hash
    # waits are pointless with --no-mining-asserts (nothing will ever connect) — skip the stall.
    wait_status_ok 240 || true
    wait_monero_synced 120 || true
    [ "$SKIP_MINING_ASSERTS" = "1" ] || wait_miner_running 180 || true
    # p2pool infers its sidechain from connected peers, so after a pool switch it reads "Unknown"
    # until peers on the new chain connect — wait for the dashboard to classify it (issue #54).
    local _pool
    _pool="$(jq_get "$config" '.p2pool.pool')"
    _pool="${_pool:-main}"
    wait_pool_ready 180 "$(pool_label "$_pool")" || true
    # End-to-end mining: p2pool's stratum hash counter resets on restart and climbs only once the
    # proxy's upstream reconnects and a share lands — wait for it before asserting hashes>0 (issue #54).
    [ "$SKIP_MINING_ASSERTS" = "1" ] || wait_hashes_flowing 300 || true
    # When Tari is a required sync gate, give it the same treatment as Monero: after a restart it
    # must close its offline gap before the .sync.tari.state assertion, or we'd catch it mid-"loading".
    if [ "$(jq_get "$config" '.dashboard.tari_required')" = "true" ]; then
        wait_tari_synced 300 || true
    fi

    local fails_before="$IT_FAIL"
    assert_scenario "$name" "$config"
    # If this scenario turned anything red, grab artifacts for it.
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "$name" "$OUT_DIR"
    restore_firewall_after_clearnet "$name" "$config"
    return 0
}

# The clearnet-sync scenario runs with the egress firewall off, the only way its flags reach the
# daemons (#2649). Before that scenario ends, turn the firewall back on with the flags left set and
# prove what the operator then gets: the rules are installed again, render_env zeroes both .env
# flags, and a sync that already completed stays spent. The marker survives the apply, so turning
# the firewall off again later would not put a synced node back on clearnet. Any other config is
# left alone.
restore_firewall_after_clearnet() { # <name> <config>
    local name="$1" config="$2" sdir chain had=""
    [ "$(jq_get "$config" '.network.tor_egress_firewall')" = "false" ] || return 0
    [ "$(jq_get "$config" '.monero.clearnet_initial_sync')" = "true" ] ||
        [ "$(jq_get "$config" '.tari.clearnet_initial_sync')" = "true" ] || return 0
    # Only a marker that existed before this apply can prove it survives it; a missing one is the
    # transition row's failure, reported there once.
    sdir="$(env_on_box CLEARNET_STATE_DIR)"
    [ -n "$sdir" ] || sdir="$IT_REMOTE_DIR/data/clearnet-state"
    for chain in monero tari; do
        [ "$(jq_get "$config" ".$chain.clearnet_initial_sync")" = "true" ] || continue
        rx "test -f $(quote_arg "$sdir/$chain.synced")" && had="$had $chain"
    done
    it_step "turning the egress firewall back on after the clearnet sync (#2649)…"
    push_config "$(printf '%s' "$config" | jq '.network.tor_egress_firewall = true')"
    if ! pithead apply -y >"$OUT_DIR/${name}.firewall-on.apply.log" 2>&1; then
        it_fail "egress firewall back on after the clearnet sync (#2649)" "apply failed; see $OUT_DIR/${name}.firewall-on.apply.log"
        capture_artifacts "${name}-firewall-on" "$OUT_DIR"
        return 0
    fi
    wait_status_ok 240 || true
    assert_contains "egress firewall back on after the clearnet sync (#2649)" "$(pithead doctor 2>&1)" "egress firewall is installed"
    assert_eq "firewall on: monero clearnet flag ignored (#2649)" "$(env_on_box MONERO_CLEARNET_SYNC)" "false"
    assert_eq "firewall on: tari clearnet flag ignored (#2649)" "$(env_on_box TARI_CLEARNET_SYNC)" "false"
    for chain in $had; do
        if rx "test -f $(quote_arg "$sdir/$chain.synced")"; then
            it_pass "firewall on: the completed $chain clearnet sync stays spent (#234/#2649)"
        else
            it_fail "firewall on: the completed $chain clearnet sync stays spent (#234/#2649)" "$chain.synced marker removed by the firewall-on apply"
        fi
    done
}

# The read-only assertion battery (infrastructure-level). Asserts the live running state of
# the stack for a given config WITHOUT changing anything — so it backs both a post-apply
# scenario check and the non-destructive `--check` mode. Calibrated against real hardware:
# monerod's own RPC sync flag is authoritative for "caught up", and (for a local node) the
# dashboard's sync panel is polled to "done" before snapshotting — it reads "loading" until its
# first poll lands after a restart. proxy_workers signals mining liveness (stratum.conns can read 0).
