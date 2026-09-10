# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
assert_running_state() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    local name="$1" config="$2"
    local st mode tmode pool secure tari_req xvb rpc_lan monero_clearnet tari_clearnet
    mode="$(jq_get "$config" '.monero.mode')"
    mode="${mode:-local}"
    tmode="$(jq_get "$config" '.tari.mode')"
    tmode="${tmode:-local}"
    pool="$(jq_get "$config" '.p2pool.pool')"
    pool="${pool:-main}"
    secure="$(jq_get "$config" '.dashboard.secure')"
    tari_req="$(jq_get "$config" '.dashboard.tari_required')"
    xvb="$(jq_get "$config" '.xvb.enabled')"
    rpc_lan="$(jq_get "$config" '.monero.rpc_lan_access')"
    # Clearnet initial sync (#183): absent => default false.
    monero_clearnet="$(jq_get "$config" '.monero.clearnet_initial_sync')"
    [ "$monero_clearnet" = "true" ] || monero_clearnet="false"
    tari_clearnet="$(jq_get "$config" '.tari.clearnet_initial_sync')"
    [ "$tari_clearnet" = "true" ] || tari_clearnet="false"

    # 0. Clearnet auto-transition settle (#234). Enabling clearnet on an already-synced node makes the
    # dashboard supervisor flip it back to Tor, which RESTARTS the daemon(s). Wait for that to fully
    # COMPLETE before the steady-state battery below — otherwise we catch a daemon mid-restart and the
    # health/sync/proxy assertions fail spuriously. The marker is written BEFORE the restart, so the
    # marker alone isn't "settled": for Monero we also wait for the Tor `proxy=` to reappear in the
    # running config (only true once the flip-back re-render + restart finished), then for the whole
    # stack to report healthy. This block also IS the end-to-end proof the transition fired.
    if [ "$monero_clearnet" = "true" ] || [ "$tari_clearnet" = "true" ]; then
        local csdir
        csdir="$(env_on_box CLEARNET_STATE_DIR)"
        if [ "$monero_clearnet" = "true" ]; then
            if wait_for 180 10 "monero clearnet→Tor transition marker (#234)" rx "test -f '$csdir/monero.synced'"; then
                it_pass "monero auto-transitioned clearnet→Tor (#234)"
            else it_fail "monero auto-transitioned clearnet→Tor (#234)" "marker not written within 180s"; fi
            wait_for 240 10 "monerod restarted back on Tor — proxy restored (#234)" \
                rx "docker exec monerod grep -qE '^proxy=' /home/ubuntu/.bitmonero/bitmonero.conf 2>/dev/null" || true
        fi
        if [ "$tari_clearnet" = "true" ]; then
            if wait_for 180 10 "tari clearnet→Tor transition marker (#234)" rx "test -f '$csdir/tari.synced'"; then
                it_pass "tari auto-transitioned clearnet→Tor (#234)"
            else it_fail "tari auto-transitioned clearnet→Tor (#234)" "marker not written within 180s"; fi
        fi
        wait_for 240 5 "stack healthy after clearnet→Tor transition (#234)" _pred_status_ok || true
    fi

    # 1. Expected containers up; unexpected ones absent.
    local running expected svc
    running="$(running_services)"
    expected="$(expected_services "$config")"
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        if service_present "$svc" "$running"; then
            it_pass "container up: $svc"
        else
            it_fail "container up: $svc" "not in running services"
        fi
    done <<<"$expected"
    if [ "$mode" = "remote" ]; then
        if service_present monerod "$running"; then
            it_fail "monerod absent in remote mode" "monerod is running"
        else
            it_pass "monerod absent in remote mode"
        fi
    fi
    # tari.mode is an independent axis from monero.mode (#103/#942): the bundled tari container
    # must be absent whenever it's remote, same as monerod above.
    if [ "$tmode" = "remote" ]; then
        if service_present tari "$running"; then
            it_fail "tari absent in remote mode (#103/#942)" "tari is running"
        else
            it_pass "tari absent in remote mode (#103/#942)"
        fi
    fi
    # 1b. A node's inbound onion follows the node (#103): the LIVE torrc must carry the node's
    #     hidden service only in local mode, or the stack advertises an onion address that accepts
    #     connections into a container that never started. Tier-1 proves the rendering; only here
    #     can we prove the running container actually got the gate through compose. Read the torrc
    #     rather than the hostname file — a key minted during an earlier local scenario stays on
    #     disk, so its presence proves nothing; what tor publishes is what the torrc lists. Monero
    #     and Tari toggle this independently (their onions are gated by separate compose profiles).
    local hs_monero hs_tari
    hs_monero="$(rx "docker exec tor grep -c -F 'HiddenServiceDir /var/lib/tor/monero/' /tmp/torrc 2>/dev/null")"
    if [ "$mode" = "remote" ]; then
        assert_eq "no Monero inbound onion in remote mode (#103)" "${hs_monero:-0}" "0"
    else
        assert_num_ge "Monero inbound onion published in local mode (#103)" "${hs_monero:-0}" 1
    fi
    hs_tari="$(rx "docker exec tor grep -c -F 'HiddenServiceDir /var/lib/tor/tari/' /tmp/torrc 2>/dev/null")"
    if [ "$tmode" = "remote" ]; then
        assert_eq "no Tari inbound onion in remote mode (#103/#942)" "${hs_tari:-0}" "0"
    else
        assert_num_ge "Tari inbound onion published in local mode (#103)" "${hs_tari:-0}" 1
    fi

    # 2. pithead status is green for a healthy config.
    pithead status >/dev/null 2>&1
    assert_rc "status exit code is 0 (healthy)" "$?" "0"

    # 3. Dashboard reachable and reading live state. In local mode, let the monero sync panel finish
    #    its first poll after the scenario's apply/restart before snapshotting, so step 4 sees settled
    #    state instead of a cold "loading" (a stuck panel never settles, so the assert still catches the
    #    #180 regression). Poll, don't sleep (issue #54).
    [ "$mode" = "local" ] && wait_for 60 3 "monero sync panel to settle (dashboard)" _pred_monero_panel_done || true
    st="$(api_state)"
    if [ -z "$st" ]; then
        it_fail "dashboard /api/state reachable" "empty response"
        return 0
    fi
    it_pass "dashboard /api/state reachable"

    # 4. Monero caught up — per monerod's own get_info, not the dashboard UI field.
    if monero_caught_up; then it_pass "monerod reports synced (RPC)"; elif [ $? = 1 ]; then it_fail "monerod reports synced (RPC)" "get_info answered: not synchronized"; else it_fail "monerod reports synced (RPC)" "get_info could not be asked — unreachable, refused, timed out or rejected"; fi
    # 4b. The node's ZMQ endpoint is a live ZMTP PUBLISHER (#1497) — strictly less than "publishes
    #     block notifications", and this row is named for what it proves, not for what the issue
    #     wants. Step 4 is satisfied by a node that can never publish one: an --offline monerod
    #     reports status OK with target_height 0, so both disjuncts of monero_caught_up pass.
    #     Nothing downstream covers the gap either — p2pool's healthcheck is a TCP connect to its
    #     OWN stratum port — and neither does the installer preflight, whose dial is a bare TCP
    #     connect and so passes against a docker-published port with nothing behind it. A
    #     protocol-level ZMTP handshake, which an accept() cannot satisfy, closes THAT case, and
    #     only that case. MEASURED, four targets on one host: a permanently-silent XPUB and a live
    #     monerod on a MOVING tip are INDISTINGUISHABLE to the handshake — both "ok ... XPUB".
    # 4c. So tier B SUBSCRIBES and waits for the peer to actually send something, which separates
    #     those two by construction (measured both ways: live node passes in ~2s, silent XPUB reds
    #     at the budget). What remains uncovered is narrower than it was — that the published frame
    #     was a BLOCK notification rather than txpool or miner_data — and stays a COUNTED SKIP
    #     below: a skip announces itself, a false green does not.
    local zmq_host zmq_port zv
    if [ "$mode" = "remote" ]; then
        zmq_host="$REMOTE_MONERO_HOST"
        zmq_port="${REMOTE_MONERO_ZMQ_PORT:-18083}"
    else
        zmq_host="127.0.0.1"
        zmq_port="18083"
    fi
    if zv=$(zmq_pub_probe "$zmq_host" "$zmq_port" 8); then it_pass "monero ZMQ endpoint is a live ZMTP publisher (#1497)"; else it_fail "monero ZMQ endpoint is a live ZMTP publisher (#1497)" "$zv"; fi
    if zv=$(zmq_publishes_probe "$zmq_host" "$zmq_port" 8 90); then it_pass "monero ZMQ endpoint actually publishes, not merely a live socket (#1497)"; else it_fail "monero ZMQ endpoint actually publishes, not merely a live socket (#1497)" "$zv"; fi
    it_skip_leg "monero ZMQ published frame is a BLOCK notification" "tier C (#1497): the row above proves the publisher is not silent, which is the starving-p2pool failure; proving the frame was chain_main rather than txpool_add needs a new block, a wait of minutes against seconds" missing
    assert_mergemine_roundtrip
    # The dashboard's sync panel must also read "done" for a synced node — not stay stuck at
    # "loading". A synced monerod reports target_height 0, so the panel has to trust the caught-up
    # flag, not percent-vs-target; getting that wrong left a synced node "loading" forever (the real
    # bug found in the #180 live validation). Local only: we control + know the node is synced.
    if [ "$mode" = "local" ]; then
        assert_eq "monero sync panel reads done (dashboard)" "$(jq_get "$st" '.sync.monero.state')" "done"
    fi
    # Pruned/full panel (#32): determinate (Pruned|Full) for a local node; remote is often Unknown.
    local dmode
    dmode="$(jq_get "$st" '.monero.mode')"
    if [ "$mode" = "remote" ]; then
        it_pass "monero display mode present ($dmode)"
    else
        case "$dmode" in Pruned | Full) it_pass "monero display mode determinate ($dmode)" ;;
        *) it_fail "monero display mode determinate" "got [$dmode], want Pruned|Full" ;; esac
    fi

    # 5. Sidechain selection matches the pool axis. Four-way verdict (assert_pool_type,
    #    #454/#687/#746): match passes; "Unknown" is peer-discovery timing (warn); a determinate
    #    mismatch is checked against the rendered P2POOL_FLAGS ground truth — correct flags mean
    #    the classifier is still on the pre-switch sidechain (warn, #746), wrong flags mean a real
    #    config/render bug (fail).
    assert_pool_type "pool type" "$(jq_get "$st" '.pool.type')" "$(pool_label "$pool")"

    # 6. End-to-end mining: workers online + hashes accumulating (#28). proxy_workers is the
    #    reliable liveness signal; stratum.conns is reported but informational (can be 0). The
    #    hashes figure gets a bounded wait first (#831): between scenarios the bench stratum
    #    bounces, a REAL rig fails over to its secondary pool and returns on xmrig's own retry
    #    clock (~60-90s) — a single early sample reads 0 while the rig is genuinely mining a
    #    minute later, and which scenario loses that race moves run to run. The re-fetched
    #    assertion below stays the arbiter: a rig that never returns still fails after the
    #    timeout.
    if [ "$SKIP_MINING_ASSERTS" = "1" ]; then
        # #905: no miner is connected on purpose (e2e --no-miner), so a live worker/hash count
        # would fail a healthy stack. assert_mining_state (skip-accounting.sh) skips these two loudly; every
        # other assertion in the scenario stays binding.
        assert_mining_state "1" "" "" "$EXPECTED_WORKERS"
    else
        local workers conns hashes
        wait_stratum_hashes 180 || true
        st="$(api_state)" # re-fetch so this step and everything after read post-wait state
        workers="$(jq_get "$st" '.proxy_workers')"
        conns="$(jq_get "$st" '.stratum.conns')"
        hashes="$(jq_get "$st" '.stratum.total_hashes')"
        assert_mining_state "0" "$workers" "$hashes" "$EXPECTED_WORKERS"
        it_step "stratum conns=${conns:-?} (informational)"
    fi

    # 7. Tari sync-gate posture matches tari_required. The sync verdict tolerates post-restart
    #    target re-discovery ONLY once Tari has proved "done" earlier this run (#746).
    assert_eq "TARI_REQUIRED env matches config" "$(env_on_box TARI_REQUIRED)" "${tari_req:-true}"
    if [ "$tari_req" = "true" ]; then
        assert_tari_synced_required "$(jq_get "$st" '.sync.tari.state')"
    fi

    # 7b. The #170 Stack Topology & Egress panel rides on /api/state, derived live from config.
    #     Assert the data contract survives the trip (the on-the-wire privacy posture is verified
    #     separately by assert_egress_posture via /proc/net/tcp): both sections present, the badge
    #     summary shared verbatim with the map so they can never disagree, and the canonical node
    #     set exposed. Holds for every scenario — the node set is static and the summary invariant
    #     is config-independent.
    assert_eq "egress posture section present" "$(jq_get "$st" '.egress.summary | type')" "object"
    assert_eq "topology section present" "$(jq_get "$st" '.topology.summary | type')" "object"
    assert_eq "topology + egress share one summary" \
        "$(jq_get "$st" '.topology.summary == .egress.summary')" "true"
    assert_eq "topology exposes the canonical node set" \
        "$(jq_get "$st" '[.topology.nodes[].id] | sort | join(",")')" \
        "browser,caddy,dashboard,docker,internet,monerod,p2pool,rigs,tari,tor,xmrig-proxy"

    # 8. Security/posture axes propagated to .env.
    local want_bind
    [ "$rpc_lan" = "true" ] && want_bind="0.0.0.0" || want_bind="127.0.0.1"
    assert_eq "MONERO_RPC_BIND matches rpc_lan_access" "$(env_on_box MONERO_RPC_BIND)" "$want_bind"
    assert_eq "DASHBOARD_SECURE matches config" "$(env_on_box DASHBOARD_SECURE)" "${secure:-true}"
    # #740: dashboard.port flows config -> .env. Unset in every scenario, so HOST_PORT must render
    # empty (the scheme-default path); a scenario that sets dash_port would assert the custom value.
    assert_eq "HOST_PORT matches config (empty = scheme default)" "$(env_on_box HOST_PORT)" "${dash_port:-}"
    assert_eq "XVB_ENABLED matches config" "$(env_on_box XVB_ENABLED)" "${xvb:-true}"

    # 8b. Resource + privacy posture (LOCAL only). These regress silently and would otherwise only
    # be caught at tier 1 (compose/config), never live: a dropped mem_limit (#132) lets a leak
    # OOM-kill monerod instead of the offender; a reverted node-DNS setting (#161/#162) leaks
    # "this IP runs Monero/Tari" to the clearnet.
    if [ "$mode" = "local" ]; then
        local svc memlim
        for svc in monerod tari p2pool dashboard; do
            memlim="$(rx "docker inspect $svc --format '{{.HostConfig.Memory}}' 2>/dev/null")"
            assert_num_gt "memory ceiling live on $svc (#132)" "${memlim:-0}" 0
        done
        # Per-service runtime uid (#255/#91): compose only pins tari's `user: 1000:1000` at
        # config time (tests/stack/standalone/test_compose.sh) — nothing checks what's actually running. The
        # 5 first-party pithead-* images run their own build-time USER (tor's alpine 'tor' package
        # user is uid 100; monerod/p2pool/xmrig-proxy/dashboard, built on ubuntu:24.04's built-in
        # 'ubuntu' user or an explicit useradd, are uid 1000) and tari pins 1000 via the compose
        # override (the pulled image ships no non-root user of its own). Caddy and the two Docker
        # socket proxies are the audited exception — verified against the upstream images
        # (caddy:2.11.4, tecnativa/docker-socket-proxy:v0.5.0): neither ships a non-root user, so
        # they run as root, mitigated by cap_drop: ALL + read_only rootfs and (the proxies) sitting
        # off mining_net on host-loopback-only ports (#345) rather than by uid. Pin ALL 9 so a
        # silent drift either way — a hardened image reverting to root, or an accepted-root service
        # unexpectedly changing uid — is caught.
        local pair svc uid_want uid_got
        for pair in "tor=100" "monerod=1000" "p2pool=1000" "tari=1000" "xmrig-proxy=1000" \
            "dashboard=1000" "caddy=0" "docker-proxy=0" "docker-control=0"; do
            svc="${pair%%=*}"
            uid_want="${pair#*=}"
            uid_got="$(rx "docker exec $svc id -u" 2>/dev/null)"
            assert_eq "runtime uid of $svc is $uid_want (#255/#91)" "$uid_got" "$uid_want"
        done
        assert_num_ge "monerod DNS checkpoints disabled (#161)" \
            "$(rx "docker exec monerod grep -c '^disable-dns-checkpoints=1' /home/ubuntu/.bitmonero/bitmonero.conf 2>/dev/null")" 1
        assert_eq "monerod has no clearnet priority-node hostnames (#161)" \
            "$(rx "docker exec monerod grep -cE 'xmrvsbeast.com|hashvault.pro' /home/ubuntu/.bitmonero/bitmonero.conf 2>/dev/null")" "0"
        # Clearnet initial sync (#183) + auto-transition (#234). The flag propagates to .env; pithead
        # ALWAYS renders the canonical Tor config (the clearnet transform is applied per-start
        # in-container, gated on the flag AND the dashboard's marker). The dashboard switches a
        # clearnet node back to Tor once it's synced — so in the synced steady state asserted here,
        # monerod always carries the Tor P2P proxy and Tari's canonical config stays `type = "tor"`.
        assert_eq "MONERO_CLEARNET_SYNC matches config (#183)" "$(env_on_box MONERO_CLEARNET_SYNC)" "$monero_clearnet"
        assert_eq "TARI_CLEARNET_SYNC matches config (#183)" "$(env_on_box TARI_CLEARNET_SYNC)" "$tari_clearnet"
        assert_num_ge "tari canonical config is always Tor (#234)" \
            "$(rx "docker exec tari grep -c '^type = \"tor\"' /var/tari/config/config.toml 2>/dev/null")" 1
        assert_num_ge "monerod runs Tor-only in steady state — proxy present (#183/#234)" \
            "$(rx "docker exec monerod grep -cE '^proxy=' /home/ubuntu/.bitmonero/bitmonero.conf 2>/dev/null")" 1
        # (The clearnet→Tor auto-transition was already awaited + asserted at the top of this function,
        # before the steady-state battery, so the assertions above see the settled post-flip state.)
        case "$(rx "docker inspect tari --format '{{.HostConfig.Dns}}' 2>/dev/null")" in
        *1.1.1.1* | *8.8.8.8*) it_fail "tari DNS sinkholed — no clearnet resolver (#162)" "clearnet nameserver present" ;;
        *127.0.0.1*) it_pass "tari DNS sinkholed — no clearnet resolver (#162)" ;;
        *) it_fail "tari DNS sinkholed — no clearnet resolver (#162)" "unexpected HostConfig.Dns" ;;
        esac
        # The xmrig-proxy config knobs must reach the RUNNING proxy's argv, not just the compose
        # render. donate-level is rendered explicitly so it's always visible (#173). The matrix
        # deploys the default config (no p2pool.stratum_password) → stratum auth OFF, which must
        # render NO --access-password flag at all: a literal empty '--access-password=' would demand
        # an empty password and reject every rig (the bug verified + guarded for #152).
        local proxy_args
        proxy_args="$(rx "docker inspect xmrig-proxy --format '{{json .Args}}' 2>/dev/null")"
        case "$proxy_args" in
        *'--donate-level='*) it_pass "xmrig-proxy dev-fee donate-level is explicit + live (#173)" ;;
        *) it_fail "xmrig-proxy dev-fee donate-level is explicit + live (#173)" "no --donate-level in proxy argv" ;;
        esac
        case "$proxy_args" in
        *'--access-password='*) it_fail "default-off stratum: no --access-password live (#152)" "found --access-password with no stratum_password set — would reject rigs" ;;
        *) it_pass "default-off stratum: no --access-password live (#152)" ;;
        esac
    fi

    # 8c. Stratum-over-TLS (#261/#942): tier 1 proves the render (PROXY_STRATUM_TLS -> the
    # wrapper's cert flags); nothing before this dialed it. A LIVE TLS handshake against the
    # published stratum port proves xmrig-proxy actually terminates TLS there, and that the
    # served certificate is the SAME one the operator was told to pin (announce_stratum_tls's
    # fingerprint) — not just that a keypair exists on disk. Same-port cleartext/TLS
    # autodetection means already-connected cleartext rigs are unaffected (the mining assertions
    # above already prove they keep hashing); a real xmrig client dialing with pools[].tls:true is
    # a rig-configuration step outside this harness's control, deferred like the stratum-password
    # headless-probe gap (docs/dev/testing-strategy.md).
    if [ "$mode" = "local" ] && [ "$(jq_get "$config" '.p2pool.stratum_tls')" = "true" ]; then
        local tls_port tls_dir served_fp announced_fp
        tls_port="$(env_on_box STRATUM_PORT)"
        [ -n "$tls_port" ] || tls_port=3333
        tls_dir="$(env_on_box PROXY_TLS_DIR)"
        served_fp="$(rx "openssl s_client -connect 127.0.0.1:$tls_port </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'")"
        assert_ne "stratum TLS handshake succeeds on the published port (#261/#942)" "$served_fp" ""
        announced_fp="$(rx "openssl x509 -in $(quote_arg "$tls_dir/cert.pem") -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'")"
        assert_eq "live-served cert fingerprint matches the one rigs are told to pin (#261/#942)" "$served_fp" "$announced_fp"
    fi

    # 8d. Firewall opt-out actually opens the path (#270/#942) — the mirror of the fail-closed
    # default that assert_egress_posture/fault_firewall_rollback prove elsewhere: no rule
    # installed is necessary but not sufficient, so dial a real clearnet IP DIRECTLY from a
    # mining_net container (bypassing its own --socks5 config) with wget (already present in every
    # first-party image for the build-time binary download — no new tool). Read the CONNECT-phase
    # line, not the HTTP result — a 403/redirect still proves the TCP handshake got through, while
    # a DROPped SYN would just hang to wget's own timeout instead.
    if [ "$mode" = "local" ] && [ "$(jq_get "$config" '.network.tor_egress_firewall')" = "false" ]; then
        assert_eq "no pithead-tagged firewall rule installed when opted out (#270/#942)" \
            "$(rx "sudo iptables-save 2>/dev/null | grep -c pithead-tor-egress")" "0"
        local dial
        dial="$(rx "docker exec xmrig-proxy wget -T 8 -t 1 -O /dev/null http://1.1.1.1/ 2>&1")"
        assert_contains "clearnet dial SUCCEEDS with the firewall opted out (#270/#942)" "$dial" "connected."
    fi

    # 8e. Payout confirmation is live (#381/#462/#942) — the flagship feature's live leg. A real
    # payout landing (and thus a non-empty confirmed total) needs days of chain time no e2e run
    # has; what IS honestly provable now is that the view-only wallet-rpc/tari-wallet actually
    # started (expected_services already asserts the container up) and that the dashboard's own
    # feature flag — the same one build_earnings reads to decide "on, nothing confirmed yet" vs.
    # "off" — reads ON. .earnings.confirmed.enabled is False only when payouts is None
    # (service/earnings.py:confirmed_payouts_summary), i.e. exactly PAYOUT_CONFIRM_ENABLED.
    if [ "$mode" = "local" ] && [ -n "$(jq_get "$config" '.monero.view_key')" ]; then
        assert_eq "PAYOUT_CONFIRM_ENABLED matches config (#381/#942)" "$(env_on_box PAYOUT_CONFIRM_ENABLED)" "true"
        assert_eq "dashboard confirms Monero payout tracking is live (#381/#942)" "$(jq_get "$st" '.earnings.confirmed.enabled')" "true"
    fi
    if [ "$mode" = "local" ] && [ -n "$(jq_get "$config" '.tari.view_key')" ]; then
        assert_eq "TARI_PAYOUT_CONFIRM_ENABLED matches config (#462/#942)" "$(env_on_box TARI_PAYOUT_CONFIRM_ENABLED)" "true"
        assert_eq "dashboard confirms Tari payout tracking is live (#462/#942)" "$(jq_get "$st" '.earnings.tari_confirmed.enabled')" "true"
    fi

    # 9. Caddy scheme matches dashboard.secure — read from the DASHBOARD's site block, which is
    #    neither line 1 nor the first scheme in the file. #1123 put a global options block
    #    (`{ auto_https disable_redirects }`) at the top, and in HTTPS mode an `http:// {` redirect
    #    block ABOVE the dashboard's own block. So `head -n1` sees `{`, and "the first scheme in the
    #    file" sees `http://` on a box that is correctly serving HTTPS — both spellings report a
    #    false RED on a healthy stack, which is how this assertion failed 8 times in one green run.
    #    The dashboard's block is the one whose address carries a HOST after the scheme; the bare
    #    redirect is `http:// {`, with a space where the host would be, so `[^ ]` separates them.
    local want_scheme
    [ "$secure" = "false" ] && want_scheme='^http://[^ ]' || want_scheme='^https://[^ ]'
    assert_eq "Caddyfile's dashboard site block uses the correct scheme (#1123)" \
        "$(rx "grep -qE '$want_scheme' Caddyfile && echo yes || echo no")" "yes"

    # 10. Secrets intact (proxy token + onions unchanged vs the baseline we captured).
    assert_eq "secrets intact (token + onions)" "$(secret_fingerprint)" "$BASELINE_SECRET_FP"
}

# Full per-scenario battery: the read-only state assertions, plus the apply-only idempotency
# check (a second apply with no config change is a clean no-op).
