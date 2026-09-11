# shellcheck shell=bash
# Exact restoration and isolated-client helpers for the bounded live XvB smoke.

XVB_FEED_TS_BEFORE=0
_XVB_RESTORE_ARMED=0
_XVB_FOREIGN_TRAP=""
_XVB_SECRET_FP_BEFORE=""
_XVB_P2POOL_URL="" _XVB_BASELINE_ROUTE="" _XVB_EXPECTED_WORKERS=0 _XVB_BASELINE_WORKERS=""

restore_xvb_original() {
    local baseline_tor=true
    [ "$(jq_get "$BASELINE_CONFIG" '.xvb.tor')" = false ] && baseline_tor=false
    push_config "$BASELINE_CONFIG" >/dev/null 2>&1 &&
        strict_pithead apply -y >/dev/null 2>&1 && wait_status_ok 240 &&
        [ "$(rx 'cat config.json' 2>/dev/null)" = "$BASELINE_CONFIG" ] &&
        [ "$(upgrade_secret_fingerprints)" = "$_XVB_SECRET_FP_BEFORE" ] &&
        [ "$(env_on_box XVB_ENABLED)" = true ] &&
        [ "$(env_on_box XVB_TOR_ENABLED)" = "$baseline_tor" ] &&
        wait_for 120 5 "proxy to restore the exact P2Pool route" _pred_proxy_route P2POOL "$_XVB_P2POOL_URL" &&
        [ "$(proxy_active_route)" = "$_XVB_BASELINE_ROUTE" ] &&
        wait_for 240 5 "the exact baseline worker set" _pred_worker_set "$_XVB_BASELINE_WORKERS" &&
        [ "$(jq_get "$(api_state)" '.stratum.total_hashes')" -gt 0 ] 2>/dev/null || return 1
    [ "${_UPGRADE_RESTORE_ARMED:-0}" = 1 ] || _SAFETY_RESTORE_ARMED=0
}

firewall_verifier_script() {
    cat <<'SH'
verify_tor_egress_firewall() {
    local subnet prefix tor_ip expected actual br rule
    subnet=$(env_get NETWORK_SUBNET 2>/dev/null); [ -n "$subnet" ] || subnet=172.28.0.0/24
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null); [ -n "$prefix" ] || prefix=172.28.0
    tor_ip="$prefix.25"
    if [ "$(container_engine)" = podman ]; then
        br=$(mining_net_ipv6_bridge) || return 1
        expected=$(render_tor_egress_nft "$subnet" "$tor_ip" "$br" | tail -n +3 | tr -d '[:space:]')
        actual=$(sudo -n nft list table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null | tr -d '[:space:]' | sed 's/priorityfilter-5/priority-5/') || return 1
    else
        sudo -n iptables -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || return 1
        # Ask iptables whether each canonical rule is installed, with `-C` and the SAME spec
        # apply_tor_egress_iptables uses. Do NOT diff `iptables -S` output: it re-prints a rule in
        # its own canonical form — `-m comment` moves after the `-s`/`-d` selectors and a bare host
        # becomes `/32` — so a literal string compare can never match on a correctly configured
        # Docker host. That is not a normalisation to reimplement; `-C` already IS iptables'
        # equality, and reusing the applier's spec keeps the two from drifting apart.
        local want=0
        while IFS= read -r rule; do
            want=$((want + 1))
            # shellcheck disable=SC2086  # intentional word-splitting of the rule body, as in the applier
            sudo -n iptables -C DOCKER-USER -m comment --comment "$TOR_EGRESS_TAG" $rule >/dev/null 2>&1 || return 1
        done < <(tor_egress_rules "$subnet" "$tor_ip")
        [ "$want" -gt 0 ] || return 1
        # Presence is not enough: a stray extra tagged rule, or the subnet-wide DROP sitting ahead
        # of the ACCEPTs, would both pass the checks above and both change what actually egresses.
        actual=$(sudo -n iptables -S DOCKER-USER 2>/dev/null | grep -F -- "--comment $TOR_EGRESS_TAG") || return 1
        [ "$(printf '%s\n' "$actual" | grep -c .)" = "$want" ] || return 1
        printf '%s\n' "$actual" | tail -n1 | grep -q -- '-j DROP' || return 1
        return 0
    fi
    [ "$actual" = "$expected" ]
}
SH
}

strict_firewall_installed() {
    local payload verifier
    verifier="$(firewall_verifier_script)"
    payload="$(printf '%s\n%s\n%s\n' 'source ./pithead' "$verifier" verify_tor_egress_firewall | base64 | tr -d '\n')"
    rx "printf %s $(quote_arg "$payload") | base64 -d | bash"
}

_pred_hashes_advanced() {
    local now
    now="$(jq_get "$(api_state)" '.stratum.total_hashes')"
    [[ "$now" =~ ^[0-9]+$ ]] && [ "$now" -gt "$1" ]
}

_pred_fresh_xvb_history_on_route() { # <epoch> <pool-url>
    local rows
    _pred_proxy_route XVB "$2" || return 1
    rows="$(rx "docker exec dashboard python3 -c 'import sqlite3,sys;c=sqlite3.connect(\"/data/mining_data.db\");print(c.execute(\"SELECT count(*) FROM history WHERE timestamp > ? AND v_xvb > 0\",(float(sys.argv[1]),)).fetchone()[0])' $(quote_arg "$1")" 2>/dev/null)"
    [[ "$rows" =~ ^[1-9][0-9]*$ ]]
}

strict_pithead() {
    local payload verifier args="" arg
    for arg in "$@"; do printf -v args '%s %q' "$args" "$arg"; done
    verifier="$(firewall_verifier_script)"
    payload="$(
        {
            printf '%s\n%s\n' 'source ./pithead' "$verifier"
            cat <<'SH'
eval "$(declare -f apply_tor_egress_firewall | sed '1s/apply_tor_egress_firewall/original_apply_tor_egress_firewall/')"
apply_tor_egress_firewall() {
    original_apply_tor_egress_firewall
    verify_tor_egress_firewall || error "Live gate refuses to start containers without the complete canonical Tor-egress ruleset."
}
main "$@"
SH
        } | base64 | tr -d '\n'
    )"
    rx "printf %s $(quote_arg "$payload") | base64 -d | bash -s --$args"
}

restore_xvb_or_safety() {
    if restore_xvb_original; then
        _XVB_RESTORE_ARMED=0
        return 0
    fi
    # shellcheck disable=SC2034 # consumed by run.sh:safety_cleanup
    SAFETY_RESTORE_FAILED=1
    [ -n "$SAFETY_ARCHIVE" ] && safety_restore_exact && _XVB_RESTORE_ARMED=0
    return 1
}

xvb_abort_restore() {
    local original_rc=$? restore_failed=0
    if [ "$_XVB_RESTORE_ARMED" = "1" ]; then
        it_warn "aborted XvB smoke — restoring the exact original configuration"
        if ! restore_xvb_or_safety; then
            restore_failed=1
            it_warn "XvB abort restore failed; safety archive retained at ${SAFETY_ARCHIVE:-<none>}"
        fi
    fi
    [ -z "$_XVB_FOREIGN_TRAP" ] || eval "$_XVB_FOREIGN_TRAP"
    [ "$restore_failed" -eq 0 ] || exit 1
    return "$original_rc"
}

arm_xvb_abort_restore() {
    local cur
    cur="$(trap -p EXIT)"
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _XVB_FOREIGN_TRAP="${parsed[2]}"
    fi
    _XVB_RESTORE_ARMED=1
    trap xvb_abort_restore EXIT
}

trigger_dashboard_xvb_fetch() {
    local payload inner
    payload="$(base64 <"$HERE/lib/xvb-egress-probe.py" | tr -d '\n')"
    inner="read -r MONERO_WALLET_ADDRESS; export MONERO_WALLET_ADDRESS; printf %s $(quote_arg "$payload") | base64 -d | python3 -"
    rx "net=pithead-xvb-probe-\$\$; cleanup() { docker network disconnect -f \"\$net\" tor >/dev/null 2>&1 || true; docker network rm \"\$net\" >/dev/null 2>&1 || true; }; trap cleanup EXIT; docker network create --internal \"\$net\" >/dev/null && docker network connect --alias tor \"\$net\" tor && wallet=\$(grep -E '^MONERO_WALLET_ADDRESS=' .env | head -n1 | cut -d= -f2-) && image=\$(docker inspect dashboard --format '{{.Config.Image}}') && [ -n \"\$wallet\" ] && [ -n \"\$image\" ] && printf '%s\\n' \"\$wallet\" | docker run --rm -i --network \"\$net\" -e TOR_SOCKS_PROXY=socks5h://tor:9050 --entrypoint sh \"\$image\" -c $(quote_arg "$inner") >/dev/null 2>&1"
}

run_xvb_routing_smoke() {
    # shellcheck disable=SC2034 # read by assertion logging in lib.sh
    IT_CURRENT_SCENARIO="xvb-routing"
    echo ""
    it_log "── bounded live XvB routing smoke ───────────────────"
    local fp_before p2pool_url xvb_url xvb_route_epoch prefix privacy_fails baseline_hash fails_before="$IT_FAIL"
    if [ "$(jq_get "$BASELINE_CONFIG" '.xvb.enabled')" != true ]; then
        it_fail "XvB smoke starts from a known enabled baseline" "set xvb.enabled=true before the bounded transition"
        return 0
    fi
    if ! fp_before="$(upgrade_secret_fingerprints)"; then
        it_fail "XvB smoke secret/onion fingerprints readable" "required secret categories are absent or unreadable"
        return 0
    fi
    baseline_hash="$(jq_get "$(api_state)" '.stratum.total_hashes')"
    [[ "$baseline_hash" =~ ^[0-9]+$ ]] || baseline_hash=0
    if ! wait_status_ok 240 || ! wait_miner_running 240 || ! wait_for 360 5 "fresh stratum hashes" _pred_hashes_advanced "$baseline_hash"; then
        it_fail "XvB smoke starts healthy with miners actively hashing" "status, miner release, or a fresh hash advance was absent"
        capture_artifacts "xvb-routing" "$OUT_DIR"
        return 0
    fi
    if [ "$(env_on_box XVB_ENABLED)" != true ] || [ "$(env_on_box XVB_TOR_ENABLED)" != true ] ||
        [ "$(env_on_box TOR_EGRESS_FIREWALL)" != true ] || ! strict_firewall_installed; then
        it_fail "XvB smoke starts from a live enabled, Tor-only, kernel-fenced configuration" "converge the declared baseline before this gate"
        capture_artifacts "xvb-routing" "$OUT_DIR"
        return 0
    fi
    p2pool_url="$(env_on_box P2POOL_URL)"
    if wait_for 120 5 "proxy to establish P2Pool baseline route" _pred_proxy_route P2POOL "$p2pool_url"; then
        it_pass "controller/proxy established the P2Pool baseline route"
    else
        it_fail "controller/proxy established the P2Pool baseline route" \
            "mode [$(jq_get "$(api_state)" '.hashrate.mode_name')], active pool [$(proxy_active_pool)]"
    fi

    _XVB_SECRET_FP_BEFORE="$fp_before"
    _XVB_P2POOL_URL="$p2pool_url"
    _XVB_BASELINE_ROUTE="$(proxy_active_route)"
    _XVB_EXPECTED_WORKERS="$(jq_get "$(api_state)" '.proxy_workers')"
    _XVB_BASELINE_WORKERS="$(worker_names)"
    # These four were one condition and one message, so a bench that was simply idle reported the
    # same way as a broken controller. Separate them, and name the one that actually bit.
    local shares_now why=""
    shares_now="$(jq_get "$(api_state)" '.shares_window.count')"
    [ "$IT_FAIL" -le "$fails_before" ] || why="an assertion above already failed"
    [ -n "$_XVB_BASELINE_ROUTE" ] || why="${why:-the proxy reports no active route}"
    [ "$_XVB_EXPECTED_WORKERS" -gt 0 ] 2>/dev/null || why="${why:-no workers are attached to the proxy}"
    if [ -n "$why" ]; then
        it_fail "XvB routing transition has a healthy P2Pool baseline, workers, and hashes" "$why; the requested gate cannot safely enable the controller"
        capture_artifacts "xvb-routing" "$OUT_DIR"
        return 0
    fi
    # A PPLNS share is an INPUT this gate needs, not a property it tests. A bench mining below the
    # rate that holds a share in the window will never have one, and failing for that reported an
    # idle bench as a product defect. Expected time to a share is sidechain_difficulty / your
    # hashrate, so a low-hashrate bench can be hours away — that is a missing input, and the
    # summary's "missing" column is exactly where it belongs.
    if [ "${shares_now:-0}" -le 0 ] 2>/dev/null; then
        it_skip_leg "XvB routing transition (#1997)" \
            "no PPLNS share in the window — attach enough hashrate to hold one on this sidechain, then re-run" "missing"
        return 0
    fi
    privacy_fails="$IT_FAIL"
    if trigger_dashboard_xvb_fetch; then
        it_pass "candidate XvB client proved a wallet-bearing real fetch in a Tor-only isolated network"
    else
        it_fail "candidate XvB client proved a wallet-bearing real fetch in a Tor-only isolated network" "the real client attempted clearnet/DNS or did not reach Tor"
    fi
    assert_egress_posture
    if [ "$IT_FAIL" -gt "$privacy_fails" ]; then
        capture_artifacts "xvb-routing" "$OUT_DIR"
        return 0
    fi
    XVB_FEED_TS_BEFORE="$(rx 'curl -fsS --max-time 8 http://127.0.0.1:8000/api/xvb-standby 2>/dev/null' | jq -r '(.ts // 0) | floor' 2>/dev/null)"
    [[ "$XVB_FEED_TS_BEFORE" =~ ^[0-9]+$ ]] || XVB_FEED_TS_BEFORE=0
    arm_xvb_abort_restore
    # `donor` is the lowest tier (1,000 H/s); the box's own configured level is deliberately
    # NOT used. The gate needs one real routing transition, and the smallest tier that produces
    # one keeps the window short and the run bounded. The baseline config is restored after.
    if ! push_config "$(printf '%s' "$BASELINE_CONFIG" | jq '.xvb.enabled=true | .xvb.tor=true | .network.tor_egress_firewall=true | .xvb.donation_level="donor"')" ||
        ! strict_pithead apply -y 2>&1 | redact >"$OUT_DIR/xvb-routing-enable.apply.log" || ! strict_firewall_installed || ! wait_status_ok 240; then
        it_fail "enable XvB donor routing with Tor fail-closed" "see $OUT_DIR/xvb-routing-enable.apply.log"
        capture_artifacts "xvb-routing" "$OUT_DIR"
        restore_xvb_or_safety || it_fail "failed XvB enable restored the exact baseline"
        return 0
    fi
    privacy_fails="$IT_FAIL"
    assert_eq "XvB controller enabled only after privacy proof" "$(env_on_box XVB_ENABLED)" true
    assert_eq "XvB donation routing forced through Tor" "$(env_on_box XVB_TOR_ENABLED)" true
    assert_eq "Tor egress firewall forced on for XvB smoke" "$(env_on_box TOR_EGRESS_FIREWALL)" true
    assert_xvb_over_tor
    if [ "$IT_FAIL" -gt "$privacy_fails" ]; then
        capture_artifacts "xvb-routing" "$OUT_DIR"
        restore_xvb_or_safety || it_fail "failed XvB wiring restored the exact baseline"
        return 0
    fi
    xvb_url="$(env_on_box XVB_POOL_URL)"
    if [ -z "$xvb_url" ]; then
        it_fail "XvB route has a real upstream URL" "XVB_POOL_URL is empty"
        capture_artifacts "xvb-routing" "$OUT_DIR"
        restore_xvb_or_safety || it_fail "missing XvB upstream restored the exact baseline"
        return 0
    fi
    if wait_for 180 5 "a fresh configured XvB network sample" _pred_xvb_feed_fresh; then
        it_pass "dashboard received a fresh configured XvB network sample"
    else
        it_fail "dashboard received a fresh configured XvB network sample" "XvB feed stayed stale"
    fi
    if wait_for 240 5 "controller to move the live proxy to XvB" _pred_proxy_route XVB "$xvb_url"; then
        it_pass "controller moved the real proxy route to XvB with workers attached"
    else
        it_fail "controller moved the real proxy route to XvB with workers attached" \
            "mode [$(jq_get "$(api_state)" '.hashrate.mode_name')], active pool [$(proxy_active_pool)]"
    fi
    xvb_route_epoch="$(rx 'date +%s')"
    if wait_for 360 5 "a fresh positive XvB-routed hashrate sample" _pred_fresh_xvb_history_on_route "$xvb_route_epoch" "$xvb_url"; then
        it_pass "dashboard recorded fresh positive hashrate while the XvB route was active"
    else
        it_fail "dashboard recorded fresh positive hashrate while the XvB route was active" "no new positive v_xvb history row appeared on the configured route"
    fi
    privacy_fails="$IT_FAIL"
    assert_egress_posture
    prefix="$(env_on_box NETWORK_PREFIX)"
    [ -n "$prefix" ] || prefix="172.28.0"
    assert_eq "active XvB proxy upstream uses the Tor SOCKS" "$(proxy_active_socks5)" "$prefix.25:9050"
    if [ "$IT_FAIL" -gt "$privacy_fails" ]; then
        capture_artifacts "xvb-routing" "$OUT_DIR"
        restore_xvb_or_safety || it_fail "failed XvB privacy check restored the exact baseline"
        return 0
    fi
    if wait_for 120 5 "dashboard to expose routed XvB hashrate and PPLNS shares" _pred_xvb_routed_visible; then
        it_pass "dashboard kept routed hashrate and PPLNS shares visible during XvB"
    else
        it_fail "dashboard kept routed hashrate and PPLNS shares visible during XvB" "live routed/share evidence did not appear"
    fi
    if wait_for 720 10 "controller to restore the live proxy to P2Pool" _pred_proxy_route P2POOL "$p2pool_url"; then
        it_pass "controller restored the real proxy route to P2Pool"
    else
        it_fail "controller restored the real proxy route to P2Pool" \
            "mode [$(jq_get "$(api_state)" '.hashrate.mode_name')], active pool [$(proxy_active_pool)]"
    fi

    [ "$IT_FAIL" -le "$fails_before" ] || capture_artifacts "xvb-routing" "$OUT_DIR"
    if restore_xvb_original; then
        it_pass "XvB smoke restored exact config, runtime wiring, route, workers, hashes, and secrets"
        _XVB_RESTORE_ARMED=0
    else
        it_fail "XvB smoke restored exact config, runtime wiring, route, workers, hashes, and secrets"
    fi
}
