# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

# xmrig-proxy's live argv (#2344): its entrypoint appends --access-password from
# PROXY_STRATUM_PASSWORD, so Docker's configured `.Args` is deliberately not the live command.
_rotate_proxy_live_args() { rx "docker exec xmrig-proxy sh -c 'tr \"\\0\" \"\\n\" </proc/1/cmdline' 2>/dev/null"; }

# Host-side authed get_info — the same probe restore-proof.sh runs after an e2e restore, here run
# against THIS box's live monerod. Echoes rpc-ok only when monerod actually accepts <user>:<pass>
# over RPC digest auth, proving the credential is live in the running container rather than just
# written to config.json/.env.
_rotate_monero_rpc_probe() { # <user> <pass> -> rpc-ok | rpc-fail
    printf '%s\0%s' "$1" "$2" | jq -Rs 'split("\u0000") | {user: .[0], pass: .[1]}' | rx 'auth=$(cat); url=$(grep -E "^MONERO_RPC_URL=" .env 2>/dev/null | cut -d= -f2-); [ -n "$url" ] || url=http://127.0.0.1:18081; body=$(printf "user = %s\n" "$(printf "%s" "$auth" | jq -r "[.user,.pass] | join(\":\") | @json")" | curl -fsS --max-time 8 --digest -K - "$url/get_info" 2>/dev/null); printf "%s" "$body" | jq -e ".status==\"OK\"" >/dev/null 2>&1 && echo rpc-ok || echo rpc-fail' --stdin
}

# Dial xmrig-proxy's control API from the dashboard container (same network, same client the
# dashboard itself uses — live-upgrade-support.sh:proxy_active_route) with an EXPLICIT token rather
# than whatever the dashboard currently holds. get_config() calls raise_for_status(), so a 401
# (wrong/old token) makes the python process exit non-zero; a real answer exits 0.
_rotate_proxy_token_accepted() { # <token> -> rc 0 if the proxy answered
    printf '%s' "$1" | rx "docker exec -i dashboard python3 -c 'import sys; from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient; from mining_dashboard.config.config import PROXY_HOST, PROXY_API_PORT; XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, sys.stdin.read()).get_config()' >/dev/null 2>&1" --stdin
}

_rotate_proxy_summary() {
    rx "docker exec dashboard python3 -c 'import json; from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient; from mining_dashboard.config.config import PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN; print(json.dumps(XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN).get_summary()))' 2>/dev/null"
}
_rotate_proxy_upstream_active() { [ "$(printf '%s' "$(_rotate_proxy_summary)" | jq -r '.upstreams.active // 0' 2>/dev/null)" -gt 0 ] 2>/dev/null; }
_rotate_proxy_accepted_after() { [ "$(printf '%s' "$(_rotate_proxy_summary)" | jq -r '.results.accepted // 0' 2>/dev/null)" -gt "$1" ] 2>/dev/null; }

# Tier-4 leg for `rotate-secrets` (#2344): the CLI verb has never run on a bench, so nothing proves
# monerod, p2pool and the proxy survive a credential rotation, or that a restart-instead-of-recreate
# regression (#356's shape) would be caught. DESTRUCTIVE-then-restored via the harness's own safety
# backup, which --rotate-secrets requires (run-cli.sh) — it is the anchor this leg restores from,
# never a second archive of its own.
run_rotate_secrets() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="rotate-secrets"
    echo ""
    it_log "── rotate-secrets phase (#2344) ─────────────────────"

    if [ -z "$SAFETY_ARCHIVE" ]; then
        it_fail "rotate-secrets has a safety archive to restore from" "SAFETY_ARCHIVE is empty — --safety-backup should have required this"
        return 1
    fi

    local local_mode=0
    has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node && local_mode=1

    # Exercise the stratum-password path deliberately: most scenarios leave p2pool.stratum_password
    # unset (auth off), which would make rotate_secrets skip the rig-facing credential entirely —
    # the operator-visible half of this verb ("every rig is rejected"). Force it "auto" for this
    # phase only; the end-of-phase restore below reverts config.json (and the secret itself) to
    # whatever the box carried before this leg ever ran. A real attached miner with no stored
    # stratum 'pass' is EXPECTEDLY rejected for the rest of this phase — the exact operator
    # consequence rotate-secrets warns about — so mining-liveness assertions are deferred to AFTER
    # the restore, once the box is back on its original (possibly auth-off) posture.
    local orig_stratum_mode
    orig_stratum_mode="$(rx "jq -r '.p2pool.stratum_password // \"\"' config.json" 2>/dev/null)"
    if [ "$orig_stratum_mode" != "auto" ]; then
        it_step "setting p2pool.stratum_password=auto to exercise the stratum-credential rotation…"
        push_config "$(render_scenario_config "$BASELINE_CONFIG" "p2pool.stratum_password=auto")"
        pithead apply -y >/dev/null 2>&1
        wait_status_ok 240 || true
    fi

    # rotate_secrets regenerates MONERO_PASS only — MONERO_NODE_USERNAME never rotates — so one
    # user value serves both the old- and new-credential probes below.
    local old_proxy_token old_stratum_pass old_monero_pass="" monero_user=""
    old_proxy_token="$(env_on_box PROXY_AUTH_TOKEN)"
    old_stratum_pass="$(env_on_box PROXY_STRATUM_PASSWORD)"
    if [ "$local_mode" = 1 ]; then
        monero_user="$(env_on_box MONERO_NODE_USERNAME)"
        old_monero_pass="$(env_on_box MONERO_NODE_PASSWORD)"
    fi

    it_step "pithead rotate-secrets -y…"
    pithead rotate-secrets -y >/dev/null 2>&1
    assert_rc "rotate-secrets exits 0" "$?" "0"
    wait_status_ok 240 || true

    # The .bak-<stamp> safety copies (#2344 concern 5): nothing sweeps them today (backup archives a
    # fixed file list; support-bundle reads config.json/.env by name, never a glob) — they are an
    # orphaned side effect holding the OLD secrets. Owner-only is asserted; removing them IS this
    # leg's own cleanup, since no product path does it.
    local bak_config bak_env
    bak_config="$(rx 'ls -t config.json.bak-* 2>/dev/null | head -n1')"
    bak_env="$(rx 'ls -t .env.bak-* 2>/dev/null | head -n1')"
    if [ -n "$bak_config" ] && [ -n "$bak_env" ]; then
        assert_eq "config.json.bak-<stamp> is owner-only (600)" "$(rx "stat -c %a $(quote_arg "$bak_config")" 2>/dev/null)" "600"
        assert_eq ".env.bak-<stamp> is owner-only (600)" "$(rx "stat -c %a $(quote_arg "$bak_env")" 2>/dev/null)" "600"
        if rx "rm -f $(quote_arg "$bak_config") $(quote_arg "$bak_env") && ! test -e $(quote_arg "$bak_config") && ! test -e $(quote_arg "$bak_env")" >/dev/null 2>&1; then
            it_pass "rotate-secrets cleanup removes its owner-only .bak-<stamp> copies"
        else
            it_fail "rotate-secrets cleanup removes its owner-only .bak-<stamp> copies" "the old-secret backup copy remained or could not be removed"
        fi
    else
        it_fail "rotate-secrets left the pre-rotation .bak-<stamp> safety copies" "config.json.bak-* / .env.bak-* not found"
    fi

    local new_proxy_token new_stratum_pass new_monero_pass=""
    new_proxy_token="$(env_on_box PROXY_AUTH_TOKEN)"
    new_stratum_pass="$(env_on_box PROXY_STRATUM_PASSWORD)"
    [ "$local_mode" = 1 ] && new_monero_pass="$(env_on_box MONERO_NODE_PASSWORD)"
    if [ "$new_proxy_token" != "$old_proxy_token" ]; then
        it_pass "PROXY_AUTH_TOKEN rotated"
    else
        it_fail "PROXY_AUTH_TOKEN rotated" "rotated value equals its prior value"
    fi
    if [ "$new_stratum_pass" != "$old_stratum_pass" ]; then
        it_pass "stratum access-password rotated"
    else
        it_fail "stratum access-password rotated" "rotated value equals its prior value"
    fi

    # 1. Recreate, not restart: the new token/password must be LIVE in the running containers, and
    #    the old ones must be gone from them — not just written to config.json/.env (#356's shape).
    #    xmrig-proxy's healthcheck (build/xmrig-proxy/healthcheck.sh) is a bare TCP connect, so
    #    `pithead status`/wait_status_ok can read it healthy the instant the listener socket binds
    #    — before the recreated container has finished wiring the new token internally. A real bench
    #    run hit exactly that: the new token's get_config() failed ~0.3s after wait_status_ok
    #    returned, while monerod's (heavier) RPC handshake had already settled. Give it the same
    #    bounded settle window every other post-recreate check in this harness gets, not one
    #    point-in-time probe.
    if wait_for 60 3 "xmrig-proxy control API to accept the new PROXY_AUTH_TOKEN" _rotate_proxy_token_accepted "$new_proxy_token"; then
        it_pass "xmrig-proxy control API accepts the new PROXY_AUTH_TOKEN (recreated, not restarted)"
    else
        it_fail "xmrig-proxy control API accepts the new PROXY_AUTH_TOKEN (recreated, not restarted)" "get_config() with the new token still failed after 60s"
    fi
    if _rotate_proxy_token_accepted "$old_proxy_token"; then
        it_fail "xmrig-proxy control API refuses the old PROXY_AUTH_TOKEN" "get_config() with the OLD token still succeeded"
    else
        it_pass "xmrig-proxy control API refuses the old PROXY_AUTH_TOKEN"
    fi

    # The control-API wait above already settled on the recreated container, so its running argv is
    # safe to read once here. The failure
    # detail never echoes proxy_args itself (or the passwords) — it is the live --access-password
    # value, and it_fail's output is not secret-redacted the way a captured artifact is.
    local proxy_args
    proxy_args="$(_rotate_proxy_live_args)"
    case "$proxy_args" in
    *"$new_stratum_pass"*) it_pass "xmrig-proxy live argv carries the NEW stratum access-password" ;;
    *) it_fail "xmrig-proxy live argv carries the NEW stratum access-password" "new value not found in the live --access-password argv" ;;
    esac
    case "$proxy_args" in
    *"$old_stratum_pass"*) it_fail "xmrig-proxy live argv no longer carries the OLD stratum access-password" "old value still live in the --access-password argv" ;;
    *) it_pass "xmrig-proxy live argv no longer carries the OLD stratum access-password" ;;
    esac

    # 2. monerod RPC: the exact restart-vs-recreate regression, asserted from the other side (#2344
    #    concern 1) — remote mode owns no local monerod, and rotate_secrets itself skips this credential.
    if [ "$local_mode" = 1 ]; then
        if [ "$(_rotate_monero_rpc_probe "$monero_user" "$new_monero_pass")" = "rpc-ok" ]; then
            it_pass "monerod RPC answers with the new password (recreated, not restarted)"
        else
            it_fail "monerod RPC answers with the new password (recreated, not restarted)" "get_info with the new creds did not return status OK"
        fi
        if [ "$(_rotate_monero_rpc_probe "$monero_user" "$old_monero_pass")" = "rpc-ok" ]; then
            it_fail "monerod RPC refuses the old password" "get_info with the OLD creds still returned status OK"
        else
            it_pass "monerod RPC refuses the old password"
        fi
    else
        it_skip_leg "monerod RPC credential rotation" "monero.mode=remote — the credential belongs to the remote node; rotate_secrets itself skips it" "by-design"
    fi

    # 3. A live upstream is stronger than the configured route: it confirms the proxy has connected
    #    to p2pool. With a reserved miner, an accepted post-rotation share proves the full route,
    #    including p2pool's usable Monero connection.
    pithead status >/dev/null 2>&1
    assert_rc "pithead status OK after the rotate-secrets recreate" "$?" "0"
    if wait_for 60 3 "xmrig-proxy to connect to its p2pool upstream" _rotate_proxy_upstream_active; then
        it_pass "xmrig-proxy has an active p2pool upstream after rotation"
    else
        it_fail "xmrig-proxy has an active p2pool upstream after rotation" "summary never reported an active upstream"
    fi
    if [ -n "${RIG_NAME:-}" ]; then
        local accepted_before
        accepted_before="$(printf '%s' "$(_rotate_proxy_summary)" | jq -r '.results.accepted // 0' 2>/dev/null)"
        if wait_borrow_rearm rotate-stratum && wait_for 300 5 "the reserved miner to submit an accepted share with the new stratum password" _rotate_proxy_accepted_after "${accepted_before:-0}"; then
            it_pass "reserved miner reconnected and submitted an accepted share with the new stratum password"
        else
            it_fail "reserved miner reconnected and submitted an accepted share with the new stratum password" "the proxy accepted count did not advance after the credential change"
        fi
        wait_borrow_rearm restore-stratum || it_fail "reserved miner's temporary stratum credential restored" "controller did not verify the pre-rotation borrowed config"
    else
        it_pass "no reserved miner attached: running proxy argv proves the rotated stratum credential"
    fi

    # Restore: the harness's own safety backup is the anchor (#2344) — a second archive here would
    # duplicate it. Brings config.json (including the original stratum_password posture), .env and
    # every secret back to what the box carried before this phase ever touched it.
    it_step "restoring the pre-rotation secrets from the safety backup…"
    if ! pithead down >/dev/null 2>&1 || ! pithead restore -y "$SAFETY_ARCHIVE" >/dev/null 2>&1 ||
        ! strict_pithead up >/dev/null 2>&1 || ! wait_status_ok 240; then
        it_fail "rotate-secrets phase restored the pre-run baseline" "restore/up/health-wait failed; safety archive retained at $SAFETY_ARCHIVE"
        # shellcheck disable=SC2034  # read by run-safety.sh:safety_cleanup / safety_rollback_if_failed
        SAFETY_RESTORE_FAILED=1
        return 1
    fi
    assert_eq "restore reverts to the exact pre-rotation secrets" "$(secret_fingerprint)" "$BASELINE_SECRET_FP"

    # 4. Mining resumes after the recreate (#2344 concern 4) — asserted here, once the box is back on
    #    its original stratum posture, so a real attached miner with no stored 'pass' is never
    #    penalised for a password THIS phase invented and already reverted.
    if [ "$SKIP_MINING_ASSERTS" != "1" ]; then
        wait_stratum_hashes 180 || true
        local st workers hashes
        st="$(api_state)"
        workers="$(jq_get "$st" '.proxy_workers')"
        hashes="$(jq_get "$st" '.stratum.total_hashes')"
        assert_mining_state "0" "$workers" "$hashes" "$EXPECTED_WORKERS"
    else
        assert_mining_state "1" "" "" "$EXPECTED_WORKERS"
    fi
}
