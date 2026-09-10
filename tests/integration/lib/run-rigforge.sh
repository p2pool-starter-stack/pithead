# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
run_rigforge_integration() { # [rig-name]
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="rigforge-integration"
    echo ""
    it_log "── RigForge integration phase (#185/#235/#260) ─────"
    local st rig="${1:-}"
    st="$(api_state)"
    if [ -z "$st" ]; then
        if [ -n "$rig" ]; then it_fail "dashboard state reachable for selected rig" "/api/state unreachable"; else it_skip_phase "rigforge-integration" "/api/state unreachable"; fi
        return 0
    fi
    [ -n "$rig" ] || rig="$(printf '%s' "$st" | jq -r 'first(.workers[]? | select(.rigforge != null and .rigforge.version != null) | .name) // empty' 2>/dev/null)"
    if [ -n "$rig" ] && ! printf '%s' "$st" | jq -e --arg n "$rig" 'any(.workers[]?; .name==$n and .rigforge.version != null)' >/dev/null 2>&1; then
        it_fail "dashboard consumed the selected RigForge rig's enriched feed" "worker '$rig' has no enriched feed"
        return 0
    fi
    if [ -z "$rig" ]; then
        it_skip_phase "rigforge-integration" "no worker exposes a RigForge enriched feed (a real rigforge rig with api:enabled on :8081?); the parse contract is covered by the tier-2 test" "covered"
        return 0
    fi
    it_pass "dashboard consumed a real RigForge rig's enriched feed: $rig (#235)"

    # 1. Enriched feed (#235/#260): the rig's row carries a version + at least one health/power/tune
    #    chip, so parse_rigforge ran on the REAL feed, not a fixture.
    local ver nchips
    ver="$(printf '%s' "$st" | jq -r --arg n "$rig" 'first(.workers[] | select(.name==$n) | .rigforge.version) // empty' 2>/dev/null)"
    assert_ne "rigforge version present in the live feed" "$ver" ""
    nchips="$(printf '%s' "$st" | jq -r --arg n "$rig" '[.workers[] | select(.name==$n) | .rigforge.chips[]?.text] | length' 2>/dev/null)"
    assert_num_ge "rigforge health/power/tune chips surfaced (>=1)" "${nchips:-0}" 1

    # 2. Worker Inspect (#185) rides on the control channel (fail-closed): the /api/worker route only
    #    exists when dashboard.control is on. Off here → the enriched-feed leg above still proves
    #    #235/#260; the control path itself is covered by the hardening phase + the tier-2 test.
    if [ "$(printf '%s' "$st" | jq -r '.control_enabled // false' 2>/dev/null)" != "true" ]; then
        it_skip_leg "Worker Inspect read/write (#185)" "dashboard.control off — not exposed here (covered by the hardening phase + tier-2 contract); enriched-feed consumption validated" "covered"
        return 0
    fi

    # 2a. Worker Inspect READ: GET /api/worker?name=<rig> returns the rig's detail carrying the
    #     enriched telemetry (plus the config prefill + history).
    local detail
    detail="$(_worker_detail "$rig" || true)"
    if [ -n "$detail" ] && printf '%s' "$detail" | jq -e '.name' >/dev/null 2>&1; then
        it_pass "Worker Inspect read returns the rig's detail (#185)"
        assert_ne "worker detail carries the enriched telemetry" \
            "$(printf '%s' "$detail" | jq -r '(.rigforge.version // .telemetry.rigforge.version // .telemetry.version) // empty' 2>/dev/null)" ""
    else
        it_fail "Worker Inspect read returns the rig's detail (#185)" "GET /api/worker returned no valid JSON: ${detail:0:120}"
    fi

    # 2b. Worker Inspect WRITE-path fail-closed guards (#185) — proven WITHOUT mutating the borrowed
    #     rig: a POST missing the X-Pithead-Control CSRF header is refused (403), and a non-writable key
    #     is rejected (400). The full dashboard->rig apply+rollback is the manual runbook step.
    local code_noheader code_badkey
    code_noheader="$(rx "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' --data '{\"worker\":\"$rig\",\"changes\":{\"DONATION\":1}}' http://127.0.0.1:8000/api/control/worker-apply" 2>/dev/null || echo 000)"
    assert_eq "Worker Inspect write refuses a request without the control header (403, #185)" "$code_noheader" "403"
    code_badkey="$(rx "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' -H 'X-Pithead-Control: 1' --data '{\"worker\":\"$rig\",\"changes\":{\"ACCESS_TOKEN\":\"x\"}}' http://127.0.0.1:8000/api/control/worker-apply" 2>/dev/null || echo 000)"
    assert_eq "Worker Inspect write rejects a non-writable key (400, #185)" "$code_badkey" "400"
    it_step "full dashboard->rig config push + rollback (#185) is a manual runbook step — it restarts the borrowed loaner and needs the rig's control API opted in"
}

# --- Moved-subnet phase (--subnet) ------------------------------------------
# Assert a config's network.subnet reached the LIVE stack, not just the rendered compose (#180/#201).
# Config-derived (default 172.28.0.0/24), local mode only. The two named highest-value checks from
# #201 — tor's render-at-start entrypoint and monerod's envsubst'd Tor proxy IP — plus the docker
# bridge, the dashboard SSRF CIDR/SOCKS, p2pool's URL, and the #344 onion vhost gateway.
assert_subnet_live() { # <config-json>
    local config="$1" subnet prefix
    subnet="$(jq_get "$config" '.network.subnet')"
    [ -n "$subnet" ] || subnet="172.28.0.0/24"
    case "$subnet" in
    *.0/24) prefix="${subnet%.0/24}" ;;
    *)
        it_fail "network.subnet is an X.Y.Z.0/24 block" "got [$subnet]"
        return 0
        ;;
    esac

    # 1. The moved subnet reached .env — both the CIDR and the derived prefix everything keys off.
    assert_eq "NETWORK_SUBNET matches config (#180)" "$(env_on_box NETWORK_SUBNET)" "$subnet"
    assert_eq "NETWORK_PREFIX derived from subnet (#180)" "$(env_on_box NETWORK_PREFIX)" "$prefix"

    # 2. The docker bridge is actually on the moved subnet (not just the compose render).
    assert_eq "docker mining_net bridge on the moved subnet (#180)" \
        "$(rx "docker network inspect mining_net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null")" \
        "$subnet"

    # 3. Tor's render-at-start entrypoint substituted the moved prefix (#180) — the container sits on
    #    prefix.25 AND its rendered torrc binds there. A hardcoded 172.28.0 in the entrypoint would
    #    pass tier 1 (which only reads the compose render) and only break here.
    assert_eq "tor container IP on the moved prefix (.25)" \
        "$(rx "docker inspect tor --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null")" \
        "$prefix.25"
    assert_num_ge "tor torrc rendered on the moved prefix (#180)" \
        "$(rx "docker exec tor grep -c -F 'ControlPort $prefix.25:9051' /tmp/torrc 2>/dev/null")" 1

    # 4. monerod's envsubst'd Tor P2P proxy points at the moved prefix (.25) — the other named check.
    assert_num_ge "monerod P2P proxy on the moved prefix (#180)" \
        "$(rx "docker exec monerod grep -c -F 'proxy=$prefix.25:9050' /home/ubuntu/.bitmonero/bitmonero.conf 2>/dev/null")" 1
    assert_eq "monerod container IP on the moved prefix (.26)" \
        "$(rx "docker inspect monerod --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null")" \
        "$prefix.26"

    # 5. The dashboard's SSRF guard CIDR + Tor SOCKS endpoint rebased (#180) — a stale 172.28.0 in
    #    either would let the guard misjudge a worker host or leak DNS off the moved bridge.
    assert_eq "dashboard MINING_NET_CIDR rebased (SSRF guard, #180)" \
        "$(rx "docker exec dashboard printenv MINING_NET_CIDR 2>/dev/null")" "$subnet"
    assert_eq "dashboard Tor SOCKS on the moved prefix (#180)" \
        "$(rx "docker exec dashboard printenv TOR_SOCKS_PROXY 2>/dev/null")" "socks5h://$prefix.25:9050"

    # 6. p2pool's stratum URL rides the moved prefix (.28).
    assert_contains "P2POOL_URL on the moved prefix (.28)" "$(env_on_box P2POOL_URL)" "$prefix.28:3333"

    # 7. The #344 onion vhost binds the bridge gateway (prefix.1, post-#346 proxy path) — gated on the
    #    onion being provisioned on this box.
    if [ "$(env_on_box DASHBOARD_ONION_ENABLED)" = "true" ]; then
        assert_num_ge "dashboard onion vhost bound to the moved gateway (.1, #344)" \
            "$(rx "grep -c -F 'http://$prefix.1' Caddyfile 2>/dev/null")" 1
    else
        it_step "onion vhost check skipped (dashboard.onion.enabled off on this box)"
    fi
}

# Bring the stack up on a NON-default network.subnet and run the standard battery (#201/#180). A
# subnet move is the one axis a hot `apply` can't do — Compose won't recreate the bridge's IPAM subnet
# while containers are attached — so this phase does a full down -> up on the moved subnet and, at the
# end, another down -> up back to the baseline subnet. The synced chains are bind-mounted by PATH (not
# on the docker network), so they are never touched. DESTRUCTIVE-then-restored; local mode only.
run_subnet_scenario() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="subnet"
    echo ""
    it_log "── moved-subnet phase (#201/#180) ──────────────────"

    if [ "$IT_MODE" != "local" ]; then
        it_skip_phase "moved-subnet" "needs local mode: it brings the stack down/up and inspects the live docker network" "by-design"
        return 0
    fi
    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_skip_phase "moved-subnet" "remote mode: monerod's moved-prefix proxy is one of the named checks" "by-design"
        return 0
    fi

    # The subnet value lives in the matrix (data, not code); isolate JUST the subnet axis onto the
    # baseline so this phase doesn't drag in the prune/pool axes (the #281 entanglement lesson).
    local ov subnet
    ov="$(scenario_overrides local-pruned-main-subnet || true)"
    subnet="$(printf '%s' "$ov" | tr ' ' '\n' | sed -n 's/^network\.subnet=//p')"
    [ -n "$subnet" ] || subnet="10.84.0.0/24"

    local config
    config="$(render_scenario_config "$BASELINE_CONFIG" "network.subnet=$subnet")"
    if ! printf '%s' "$config" | jq empty 2>/dev/null; then
        it_fail "rendered moved-subnet config is valid JSON" "jq rejected it"
        return 0
    fi

    local fails_before="$IT_FAIL"
    it_step "moving the stack onto $subnet (down -> up — Compose can't hot-move the bridge subnet)…"
    push_config "$config"
    pithead down >/dev/null 2>&1
    # After down, apply renders the moved-subnet .env and `compose up` recreates the bridge + every
    # container on the new /24.
    if ! pithead apply -y >"$OUT_DIR/subnet.apply.log" 2>&1; then
        it_fail "apply on the moved subnet succeeded" "see $OUT_DIR/subnet.apply.log"
    fi
    wait_status_ok 300 || true
    wait_monero_synced 120 || true
    [ "$SKIP_MINING_ASSERTS" = "1" ] || wait_miner_running 180 || true
    [ "$SKIP_MINING_ASSERTS" = "1" ] || wait_hashes_flowing 300 || true
    # The down/up restarted Tari too, so — like the per-scenario deploy path — let it close its
    # post-restart offline gap before assert_running_state's sync check, or we catch it mid-"loading".
    if [ "$(jq_get "$config" '.dashboard.tari_required')" = "true" ]; then
        wait_tari_synced 300 || true
    fi

    # Subnet-specific live checks + the standard running-state battery on the moved subnet.
    assert_subnet_live "$config"
    assert_running_state "subnet" "$config"

    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "subnet" "$OUT_DIR"

    # Always move the box back to the baseline subnet — a hot apply can't, so down -> up again. Runs
    # regardless of the assertions above so a mid-phase failure can't strand the box on the moved /24.
    it_step "restoring the baseline subnet (down -> up)…"
    push_config "$BASELINE_CONFIG"
    pithead down >/dev/null 2>&1
    pithead apply -y >/dev/null 2>&1 || it_warn "baseline-subnet apply returned non-zero — check the box"
    wait_status_ok 300 || true
}

# --- RigForge control phase (--rigforge-control) ----------------------------
# Drive Worker Inspect through the live dashboard-to-rig control path.
