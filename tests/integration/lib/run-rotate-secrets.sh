# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

# Read live argv because the entrypoint appends --access-password after Docker's configured args.
_rotate_proxy_live_args() { rx "docker exec xmrig-proxy sh -c 'tr \"\\0\" \"\\n\" </proc/1/cmdline' 2>/dev/null"; }

# Only an accepted digest login proves the credential is live in the running monerod.
_rotate_monero_rpc_probe() { # <user> <pass> -> rpc-ok | rpc-refused | rpc-fail
    printf '%s\0%s' "$1" "$2" | jq -Rs 'split("\u0000") | {user: .[0], pass: .[1]}' | rx 'auth=$(cat); url=$(grep -E "^MONERO_RPC_URL=" .env 2>/dev/null | cut -d= -f2-); [ -n "$url" ] || url=http://127.0.0.1:18081; body=$(printf "user = %s\n" "$(printf "%s" "$auth" | jq -r "[.user,.pass] | join(\":\") | @json")" | curl -sS --max-time 8 --digest -K - -w "\n%{http_code}" "$url/get_info" 2>/dev/null) || { echo rpc-fail; exit; }; code=${body##*$'\''\n'\''}; [ "$code" != 401 ] || { echo rpc-refused; exit; }; [ "$code" = 200 ] && printf "%s" "${body%$'\''\n'\''*}" | jq -e ".status==\"OK\"" >/dev/null 2>&1 && echo rpc-ok || echo rpc-fail' --stdin
}

# A transport failure is not evidence that a token was refused, so require the exact HTTP status.
_rotate_proxy_token_accepted() { # <token> [expected HTTP code]
    printf '%s' "$1" | rx "docker exec -i dashboard python3 -c $(quote_arg "$(cat "$HERE/rotate-auth-probe.py")") http '${2:-200}'" --stdin >/dev/null 2>&1
}

_rotate_stratum_auth() { # <password> <accepted|refused> [stratum-route]
    printf '%s' "$1" | rx "docker exec -i dashboard python3 -c $(quote_arg "$(cat "$HERE/rotate-auth-probe.py")") ${3:-stratum} $2" --stdin >/dev/null 2>&1
}

_rotate_proxy_upstream_active() { _rotate_stratum_auth "$1" accepted stratum-route; }
_rotate_rig_accepted() {
    rx "docker exec dashboard python3 -c 'import json; from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient; from mining_dashboard.config.config import PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN; print(json.dumps(XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN).get_workers()))' 2>/dev/null" |
        jq -er --arg name "$RIG_NAME" '[.workers[] | select(.[0] == $name) | .[3]] | max // 0'
}
_rotate_proxy_accepted_after() { [ "$(_rotate_rig_accepted)" -gt "$1" ] 2>/dev/null; }
_rotate_p2pool_monero_live() { # <rotation epoch>
    local stats
    stats="$(quote_arg "$(env_on_box P2POOL_DATA_DIR)/stats/local/p2p")"
    # p2pool reports seconds since the last ZMQ message, not an epoch.
    rx "now=\$(date +%s); test \"\$(stat -c %Y $stats)\" -ge '$1' && jq -e --argjson elapsed \"\$((now - $1))\" '.zmq_last_active | type == \"number\" and . >= 0 and . < \$elapsed' $stats >/dev/null"
}

_rotate_new_baks() {
    local file inventory
    inventory="$(rx "find . -maxdepth 1 -type f \\( -name 'config.json.bak-*' -o -name '.env.bak-*' \\) -exec basename {} \\;")" || return 1
    while IFS= read -r file; do
        [[ "$file" =~ ^(config.json|\.env)\.bak-[0-9]{8}-[0-9]{6}$ ]] || continue
        grep -Fxq -- "$file" <<<"$_ROTATE_BAKS_BEFORE" || printf '%s\n' "$file"
    done <<<"$inventory"
}

_rotate_cleanup_baks() {
    local file inventory failed=0
    inventory="$(_rotate_new_baks)" || return 1
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        rx "rm -f $(quote_arg "$file") && ! test -e $(quote_arg "$file")" || failed=1
    done <<<"$inventory"
    return "$failed"
}

_rotate_abort_restore() {
    local rc=$?
    safety_abort_restore
    # Recovery copies survive until exact safety restoration verifies.
    if [ "${_SAFETY_RESTORE_ARMED:-1}" = 0 ] && ! _rotate_cleanup_baks; then
        it_fail "interrupted rotation recovery-copy cleanup verified" "inventory or removal failed"
        exit 1
    fi
    return "$rc"
}

# Destructive leg restored from the harness safety backup that --rotate-secrets requires.
run_rotate_secrets() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="rotate-secrets"
    echo ""
    it_log "── rotate-secrets phase (#2344) ─────────────────────"

    if [ -z "$SAFETY_ARCHIVE" ]; then
        it_fail "rotate-secrets has a safety archive to restore from" "SAFETY_ARCHIVE is empty — --safety-backup should have required this"
        return 1
    fi
    if [ -n "${RIG_NAME:-}" ] && [ "${CI_RIG_RECOVERY_HOLD:-0}" != 1 ]; then
        it_fail "reserved rig has a runner-owned persistent recovery hold" "runner capability absent; no credential was changed"
        return 1
    fi
    # Arm cleanup before any rotation write, including interrupted/failed invocations.
    _ROTATE_BAKS_BEFORE="$(rx "find . -maxdepth 1 -type f \\( -name 'config.json.bak-*' -o -name '.env.bak-*' \\) -exec basename {} \\;")" || {
        it_fail "pre-rotation recovery-copy inventory read" "could not establish cleanup ownership"
        return 1
    }
    trap _rotate_abort_restore EXIT

    local local_mode=0
    has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node && local_mode=1

    # rotate_secrets skips the stratum credential when auth is off, so force it on here.
    local orig_stratum_mode
    orig_stratum_mode="$(rx "jq -r '.p2pool.stratum_password // \"\"' config.json" 2>/dev/null)"
    if [ "$orig_stratum_mode" != "auto" ]; then
        it_step "setting p2pool.stratum_password=auto to exercise the stratum-credential rotation…"
        if ! push_config "$(render_scenario_config "$BASELINE_CONFIG" "p2pool.stratum_password=auto")" ||
            ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
            it_fail "temporary stratum authentication enabled" "config, apply or health verification failed"
            return 1
        fi
    fi

    # MONERO_NODE_USERNAME never rotates, so one user serves both probes.
    local old_proxy_token old_stratum_pass old_monero_pass="" monero_user=""
    old_proxy_token="$(env_on_box PROXY_AUTH_TOKEN)"
    old_stratum_pass="$(env_on_box PROXY_STRATUM_PASSWORD)"
    if [ "$local_mode" = 1 ]; then
        monero_user="$(env_on_box MONERO_NODE_USERNAME)"
        old_monero_pass="$(env_on_box MONERO_NODE_PASSWORD)"
    fi

    it_step "pithead rotate-secrets -y…"
    local rotation_epoch rc
    rotation_epoch="$(rx 'date +%s')"
    [[ "$rotation_epoch" =~ ^[0-9]+$ ]] || {
        it_fail "rotation start epoch read" "clock probe failed"
        return 1
    }
    pithead rotate-secrets -y >/dev/null 2>&1
    rc=$?
    assert_rc "rotate-secrets exits 0" "$rc" "0"
    [ "$rc" = 0 ] || return 1
    wait_status_ok 240 || true

    # The .bak copies hold the old secrets, so they must be owner-only.
    local bak_config bak_env
    bak_config="$(_rotate_new_baks | grep '^config.json.bak-')"
    bak_env="$(_rotate_new_baks | grep '^.env.bak-')"
    if [ -n "$bak_config" ] && [ -n "$bak_env" ]; then
        assert_eq "config.json.bak-<stamp> is owner-only (600)" "$(rx "stat -c %a $(quote_arg "$bak_config")" 2>/dev/null)" "600"
        assert_eq ".env.bak-<stamp> is owner-only (600)" "$(rx "stat -c %a $(quote_arg "$bak_env")" 2>/dev/null)" "600"
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

    # The proxy healthcheck is a bare TCP connect, so wait for the new token to settle.
    if wait_for 60 3 "xmrig-proxy control API to accept the new PROXY_AUTH_TOKEN" _rotate_proxy_token_accepted "$new_proxy_token"; then
        it_pass "xmrig-proxy control API accepts the new PROXY_AUTH_TOKEN (recreated, not restarted)"
    else
        it_fail "xmrig-proxy control API accepts the new PROXY_AUTH_TOKEN (recreated, not restarted)" "new token did not receive HTTP 200 after 60s"
    fi
    # The pinned proxy returns 403 for a mismatched Bearer token (401 means no auth header).
    if _rotate_proxy_token_accepted "$old_proxy_token" 403; then
        it_pass "xmrig-proxy control API refuses the old PROXY_AUTH_TOKEN"
    else
        it_fail "xmrig-proxy control API refuses the old PROXY_AUTH_TOKEN" "old token did not receive an explicit 403"
    fi

    # Never echo proxy_args: it holds the live password and it_fail output is not redacted.
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

    # Remote mode owns no local monerod and rotate_secrets skips its credential.
    if [ "$local_mode" = 1 ]; then
        if [ "$(_rotate_monero_rpc_probe "$monero_user" "$new_monero_pass")" = "rpc-ok" ]; then
            it_pass "monerod RPC answers with the new password (recreated, not restarted)"
        else
            it_fail "monerod RPC answers with the new password (recreated, not restarted)" "get_info with the new creds did not return status OK"
        fi
        if [ "$(_rotate_monero_rpc_probe "$monero_user" "$old_monero_pass")" = "rpc-refused" ]; then
            it_pass "monerod RPC refuses the old password"
        else
            it_fail "monerod RPC refuses the old password" "old password did not receive an explicit 401"
        fi
    else
        it_skip_leg "monerod RPC credential rotation" "monero.mode=remote — the credential belongs to the remote node; rotate_secrets itself skips it" "by-design"
    fi

    pithead status >/dev/null 2>&1
    assert_rc "pithead status OK after the rotate-secrets recreate" "$?" "0"
    # The proxy opens its upstream only for an authenticated miner, so rotate the rig's password first.
    local accepted_before=""
    if [ -n "${RIG_NAME:-}" ] && wait_borrow_rearm rotate-stratum; then
        accepted_before="$(_rotate_rig_accepted)" || accepted_before=""
    fi
    if wait_for 60 3 "the proxy to accept the new stratum password" _rotate_stratum_auth "$new_stratum_pass" accepted; then
        it_pass "stratum login accepts the new password and returns a mining job"
    else
        it_fail "stratum login accepts the new password and returns a mining job" "no valid authenticated job"
    fi
    if wait_for 60 3 "xmrig-proxy to connect to its p2pool upstream" _rotate_proxy_upstream_active "$new_stratum_pass"; then
        it_pass "xmrig-proxy has an active p2pool upstream after rotation"
    else
        it_fail "xmrig-proxy has an active p2pool upstream after rotation" "summary never reported an active upstream"
    fi
    if wait_for 90 3 "p2pool to receive a post-rotation Monero ZMQ message" _rotate_p2pool_monero_live "$rotation_epoch"; then
        it_pass "p2pool refreshed live Monero-backed network stats after rotation"
    else
        it_fail "p2pool refreshed live Monero-backed network stats after rotation" "stats file or last Monero ZMQ message predates the rotation"
    fi
    if _rotate_stratum_auth "$old_stratum_pass" refused; then
        it_pass "stratum login explicitly refuses the old password"
    else
        it_fail "stratum login explicitly refuses the old password" "no explicit password refusal"
    fi
    if [ -n "${RIG_NAME:-}" ]; then
        if [[ "$accepted_before" =~ ^[0-9]+$ ]] &&
            wait_for 300 5 "the reserved miner to submit an accepted share with the new stratum password" _rotate_proxy_accepted_after "$accepted_before"; then
            it_pass "reserved miner reconnected and submitted an accepted share with the new stratum password"
        else
            it_fail "reserved miner reconnected and submitted an accepted share with the new stratum password" "the proxy accepted count did not advance after the credential change"
        fi
        wait_borrow_rearm restore-stratum || it_fail "reserved miner's temporary stratum credential restored" "controller did not verify the pre-rotation borrowed config"
    fi

    it_step "restoring the pre-rotation secrets from the safety backup…"
    if ! safety_restore_exact; then
        it_fail "rotate-secrets phase restored the pre-run baseline" "restore/up/health-wait failed; safety archive retained at $SAFETY_ARCHIVE"
        # shellcheck disable=SC2034  # read by run-safety.sh:safety_cleanup / safety_rollback_if_failed
        SAFETY_RESTORE_FAILED=1
        return 1
    fi
    assert_eq "restore reverts to the exact pre-rotation secrets" "$(secret_fingerprint)" "$BASELINE_SECRET_FP"
    # No product path sweeps the .bak copies, so this leg removes its own.
    if _rotate_cleanup_baks; then
        it_pass "rotate-secrets cleanup removes only its owner-only .bak-<stamp> copies"
    else
        it_fail "rotate-secrets cleanup removes only its owner-only .bak-<stamp> copies" "a recovery copy remained"
    fi
    trap safety_abort_restore EXIT

    # Check mining after restore so a miner with no stored pass is not refused a reverted password.
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
