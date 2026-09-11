# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
assert_scenario() {
    local name="$1" config="$2"
    assert_running_state "$name" "$config"
    local again
    again="$(pithead apply -y 2>&1)"
    assert_contains "re-apply is a no-op" "$again" "No configuration changes detected"
}

# Runtime egress observation (#274), beyond config: poll each bridge app container's LIVE IPv4 TCP
# connections and FAIL if any holds a PERSISTENT direct public connection (i.e. it isn't dialing
# through the Tor SOCKS). It observes IPv4 TCP from the bridge networks only — it does NOT capture
# UDP or host-network processes, so a clean verdict is evidence, not a proof of #270. Config-level
# checks miss even this — it's what caught the #165 stale-image p2pool leak and the #271 Tari
# direct-dial. Reuses bench-verify-egress.sh (the #256 verifier) in its persistent-only mode so
# post-restart startup transients don't false-positive. Skipped only while a clearnet initial sync
# is genuinely UNFINISHED (#183): a node is then intentionally on clearnet.
assert_egress_posture() { # [tor-down]  — "tor-down" waives Tor's own liveness control (#563)
    local mc tc sdir prefix out waive=""
    [ "${1:-}" != "tor-down" ] || waive=" --allow-tor-down"
    mc="$(env_on_box MONERO_CLEARNET_SYNC)"
    tc="$(env_on_box TARI_CLEARNET_SYNC)"
    # The flag alone is not the exemption — it stays `true` in .env long after the sync finished,
    # which silently retired this gate for the rest of the run. The entrypoints drop a persistent
    # marker in CLEARNET_STATE_DIR when they are done, so skip only while the marker is ABSENT.
    sdir="$(env_on_box CLEARNET_STATE_DIR)"
    [ -n "$sdir" ] || sdir="$IT_REMOTE_DIR/data/clearnet-state"
    if { [ "$mc" = "true" ] && ! rx "test -f $(quote_arg "$sdir/monero.synced")"; } ||
        { [ "$tc" = "true" ] && ! rx "test -f $(quote_arg "$sdir/tari.synced")"; }; then
        it_skip_leg "all-Tor live egress (#274/#270)" "clearnet initial sync is explicitly active" "by-design"
        return 0
    fi
    prefix="$(env_on_box NETWORK_PREFIX)"
    [ -n "$prefix" ] || prefix="172.28.0"
    # Resolve the verifier by absolute path off run.sh's $HERE so it runs even when the stack --dir is a
    # release bundle with no tests/ tree (local mode: driver == box, so $HERE reaches it). SSH mode keeps
    # the remote-relative path — the remote is a full checkout and $HERE is a driver path meaningless there.
    local bench="tests/integration/benchmarks/bench-verify-egress.sh"
    [ "$IT_MODE" = "local" ] && bench="$HERE/benchmarks/bench-verify-egress.sh"
    out="$(rx "bash $(quote_arg "$bench") tor --dir . --prefix '$prefix' --polls 3 --interval 8$waive 2>&1")"
    case "$(egress_verdict "$out")" in
    ok) it_pass "no persistent direct IPv4 TCP egress observed from bridge apps (#274/#270)" ;;
    leak) it_fail "no persistent direct IPv4 TCP egress observed from bridge apps (#274/#270)" "$(printf '%s' "$out" | grep -E 'LEAK|✗' | head -4)" ;;
    *) it_fail "egress verifier INCONCLUSIVE — could not run, not a detected leak (#274/#270)" "$(printf '%s' "$out" | tail -4)" ;;
    esac
}

# XvB stats + auto-registration over Tor (#206/#163). The dashboard's ONLY clearnet-bound traffic is
# the XvB call to xmrvsbeast (the bonus-history stats fetch and the #263 auto-register POST). It must
# ride the bridge Tor SOCKS so the operator's home IP is never correlated with the wallet. Two-part
# LIVE proof, the tier-4 counterpart to test_xvb_client's socks5h assertion:
#   1. the RUNNING dashboard is wired to the Tor SOCKS — TOR_SOCKS_PROXY = socks5h://<prefix>.25:9050.
#      Reading the live container env (not the compose render) catches a stale-image/partial update
#      that didn't apply the proxy, exactly like the #152/#173 live xmrig-proxy argv checks. socks5h
#      (not socks5) means the xmrvsbeast hostname resolves over Tor too — no local DNS leak.
#   2. The focused live smoke runs the wallet-bearing client in an internal network whose only peer
#      is Tor, so the call has no other route out. assert_egress_posture separately observes
#      sustained direct IPv4 TCP bridge traffic.
# Skipped when XvB is disabled (nothing dials xmrvsbeast then).
assert_xvb_over_tor() {
    if [ "$(env_on_box XVB_ENABLED)" != "true" ]; then
        it_skip_leg "XvB-over-Tor wiring (#206/#163)" "XvB is disabled in this scenario" "by-design"
        return 0
    fi
    local prefix proxy want
    prefix="$(env_on_box NETWORK_PREFIX)"
    [ -n "$prefix" ] || prefix="172.28.0"
    want="socks5h://$prefix.25:9050"
    proxy="$(rx "docker exec dashboard printenv TOR_SOCKS_PROXY 2>/dev/null")"
    assert_eq "XvB stats + auto-register wired to the Tor SOCKS (#206/#163)" "$proxy" "$want"
}

# /metrics through the operator path (#379): curl the Prometheus endpoint THROUGH host-networked
# Caddy — scheme from DASHBOARD_SECURE, vhost from HOST_IP, pinned to loopback so the box needn't
# resolve its own hostname — and assert a pithead_ sample line survives the trip. This is the
# wiring api_state (which hits the app directly on 127.0.0.1:8000) can't prove: the route a real
# scraper uses, behind the proxy and its basic_auth (#8). Only the bcrypt HASH of the dashboard
# password lives in .env, so when a login is set the plaintext must come via IT_DASHBOARD_PASSWORD
# (it travels to curl as stdin configuration, outside shell/SSH/curl argv) —
# without it the check skips rather than false-FAILs on the 401 Caddy returns by design.
assert_metrics_via_caddy() {
    local host secure scheme port curl_auth="" body
    host="$(env_on_box HOST_IP)"
    if [ -z "$host" ]; then
        it_skip_leg "/metrics via Caddy" "no HOST_IP in .env"
        return 0
    fi
    secure="$(env_on_box DASHBOARD_SECURE)"
    # #740: Caddy binds HOST_PORT when set, else the scheme default (80/443). Read it so the operator
    # path is curled on the port Caddy actually listens on, not a hardcoded 80/443.
    port="$(env_on_box HOST_PORT)"
    if [ "$secure" = "false" ]; then
        scheme="http"
        [ -n "$port" ] || port=80
    else
        scheme="https"
        [ -n "$port" ] || port=443
    fi
    if [ -n "$(env_on_box DASHBOARD_AUTH_HASH_B64)" ]; then
        if [ -z "${IT_DASHBOARD_PASSWORD:-}" ]; then
            it_skip_leg "/metrics via Caddy" "dashboard login is set — export IT_DASHBOARD_PASSWORD to test through it"
            return 0
        fi
        curl_auth="$(printf 'user = %s\n' "$(printf '%s:%s' "$(env_on_box DASHBOARD_AUTH_USER)" "$IT_DASHBOARD_PASSWORD" | jq -Rs .)")"
    fi
    # -k: the LAN cert is Caddy's internal CA (tls internal); trust isn't what this asserts.
    body="$(printf '%s\n' "$curl_auth" | rx "curl -ksS --max-time 15 -K - --resolve $(quote_arg "$host:$port:127.0.0.1") $(quote_arg "$scheme://$host/metrics")" --stdin 2>/dev/null)"
    if metrics_has_pithead_sample "$body"; then
        it_pass "/metrics serves pithead_ samples through Caddy (#379)"
    else
        it_fail "/metrics serves pithead_ samples through Caddy (#379)" "no pithead_ sample line in the response [$(printf '%s' "$body" | head -c 120)]"
    fi
}

# pithead doctor on the real box (#383): exit 0 plus the three runtime OK verdicts — egress
# firewall installed, stratum :3333 listening, dashboard answering. Tier 1 proves each verdict's
# decision logic against stubs; this proves the real toolchain (docker/sudo/iptables/ss/curl)
# feeds them on a healthy box. The firewall line is config-gated the same way doctor itself is.
assert_doctor_ok() {
    local out rc
    out="$(pithead doctor 2>&1)"
    rc=$?
    assert_rc "doctor exits 0 on a healthy box (#383)" "$rc" "0"
    if [ "$(env_on_box TOR_EGRESS_FIREWALL)" = "false" ]; then
        it_log "   doctor: egress firewall opted out — skipping that OK line"
    else
        assert_contains "doctor: egress firewall installed (#383)" "$out" "egress firewall rules are installed"
    fi
    assert_contains "doctor: stratum :3333 listening (#383)" "$out" "workers can connect"
    assert_contains "doctor: dashboard answers (#383)" "$out" "answers on 127.0.0.1:8000"
}

# Share-health capture is live (#116): .share_stats must be non-empty on a mining box — proof the
# per-poll delta capture is writing rows, not just that the key exists (tier 1 covers the shape).
assert_share_stats_live() {
    if wait_for 120 5 "share-stats series non-empty (#116)" _pred_share_stats_nonempty; then
        it_pass "share_stats non-empty on a mining box (#116)"
    else
        it_fail "share_stats non-empty on a mining box (#116)" ".share_stats stayed empty"
    fi
}

# Telemetry-persistence backbone (#196): five additive SQLite tables (blocks, xvb_history,
# network_history, disk_growth, worker_history), each created via `CREATE TABLE IF NOT EXISTS` at
# StateManager init — schema-only, no capture needed to observe it. Proves the migration actually
# ran against a REAL, already-populated DB on the upgrade path. Row presence is deliberately NOT
# asserted: capture cadences are hourly/5-min, so a single e2e run won't fill them, and the write
# path is already proven at tier 1 (test_data_service.py's capture-hook tests). No sqlite3 CLI
# ships in the dashboard image (#282 keeps it to bash + iproute2), so query via the venv's own
# python3 — the SQL uses `?` placeholders throughout so the one-liner needs no embedded single
# quotes and stays safely bash-single-quotable.
assert_telemetry_tables_present() {
    # "table exists" said nothing about whether an upgrade migrated it correctly, and nothing about
    # whether the file survived. quick_check proves the DB is not corrupt; the column lists pin the
    # post-upgrade schema of the five backbone series. These five take no additive migrations (only
    # `history` and `worker_config` do), so an exact match is the right contract — and any future
    # column added here SHOULD land in this list deliberately.
    local verdict
    verdict="$(rx "docker exec dashboard python3 -c 'import sqlite3;c=sqlite3.connect(\"/data/mining_data.db\");want={\"blocks\":[\"ts\",\"height\",\"difficulty\"],\"xvb_history\":[\"ts\",\"avg_1h\",\"avg_24h\",\"fail_count\",\"donation_fraction\",\"mode\"],\"network_history\":[\"ts\",\"difficulty\",\"height\",\"reward\",\"pool_hashrate\"],\"disk_growth\":[\"ts\",\"monero_db_bytes\",\"disk_used_gb\",\"disk_total_gb\"],\"worker_history\":[\"ts\",\"name\",\"h15\",\"accepted\",\"rejected\"]};bad=[n for n,cols in want.items() if [r[1] for r in c.execute(f\"PRAGMA table_info({n})\")]!=cols];qc=c.execute(\"PRAGMA quick_check\").fetchone()[0];print(\"ok\" if qc==\"ok\" and not bad else (\"quick_check: \"+qc if qc!=\"ok\" else \"schema drift in: \"+\",\".join(sorted(bad))))'" 2>/dev/null)"
    if [ "$verdict" = "ok" ]; then
        it_pass "telemetry DB is valid and has the expected post-upgrade schema (#196: blocks/xvb_history/network_history/disk_growth/worker_history)"
    else
        it_fail "telemetry DB is valid and has the expected post-upgrade schema (#196)" "${verdict:-could not query the telemetry DB in the dashboard container}"
    fi
}

# Non-destructive --check: assert the box's CURRENT live state (its own config), no apply.
assert_current_state() {
    IT_CURRENT_SCENARIO="check"
    echo ""
    it_log "── read-only check against the live stack ──────────"
    local fails_before="$IT_FAIL"
    assert_running_state "check" "$BASELINE_CONFIG"
    assert_egress_posture
    assert_xvb_over_tor
    assert_metrics_via_caddy
    assert_share_stats_live
    assert_telemetry_tables_present
    assert_doctor_ok
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "check" "$OUT_DIR"
}

# --- Release-server readiness (--readiness) ---------------------------------
# Read-only assessment of whether the box is fit to be a RELEASE / validation server: it must
# reuse already-synced chains, vary configs cheaply, and keep its keys/secrets and dashboard
# from leaking. Complements `pithead doctor` (stack health) — this checks the server's fitness
# for the integration harness's job. A WARN is "works, but not ideal"; a FAIL is "fix before
# using as a release gate".
box_fstype() { rx "df --output=fstype $(quote_arg "$1") 2>/dev/null | tail -n1 | tr -d ' '"; }
box_avail_gb() { rx "df -BG --output=avail $(quote_arg "$1") 2>/dev/null | tail -n1 | tr -dc '0-9'"; }
box_mode() { rx "stat -c %a $(quote_arg "$1") 2>/dev/null"; }

assert_release_readiness() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="readiness"
    echo ""
    it_log "── release-server readiness ────────────────────────"

    # 1. The whole point of a release server: chains already synced, reused in minutes.
    if monero_caught_up; then it_pass "Monero is synced (chain reusable by the matrix)"; elif [ $? = 1 ]; then it_fail "Monero is synced" "monerod answered: not caught up — the matrix would have to re-sync"; else it_fail "Monero is synced" "monerod could not be asked — unreachable, refused, timed out or rejected; sync state unknown"; fi
    # Tari is the other chain the matrix reuses; a readiness verdict that only looked at Monero
    # passed boxes whose merge-mining scenarios would start from an incomplete chain.
    if [ "$(jq_get "$(api_state)" '.sync.tari.state')" = "done" ]; then
        it_pass "Tari is synced (chain reusable by the matrix)"
    else
        it_fail "Tari is synced" "dashboard reports Tari is not done — the matrix would start from an incomplete chain"
    fi
    pithead status >/dev/null 2>&1
    assert_rc "stack is healthy (pithead status)" "$?" "0"

    # 2. The prune axis must vary the DB without re-syncing or mutating the canonical chain. The
    #    OTHER prune mode is unlocked either by (a) a snapshot/reflink-capable live FS (so a
    #    variant can be made cheaply) or (b) supplying a pre-built chain of the OPPOSITE mode
    #    (--full-data-dir when the box is pruned, --pruned-data-dir when it's full). A SAME-mode
    #    copy on a CoW volume is also useful: it lets destructive scenarios run off the live chain.
    #    the test bench is a pruned box (MONERO_PRUNE=1) with a pruned copy on a btrfs CoW loopback, so it
    #    exercises pruned mode live with snapshot isolation; full mode is covered by the fakes.
    local mdir fstype="" cow_live=0 baseline_mode="full" bp
    mdir="$(env_on_box MONERO_DATA_DIR)"
    bp="${BASELINE_PRUNE:-$(env_on_box MONERO_PRUNE)}" # so standalone --readiness sees it too
    [ -n "$mdir" ] && fstype="$(box_fstype "$mdir")"
    case "$fstype" in btrfs | zfs | xfs) cow_live=1 ;; esac
    [ "$bp" = "1" ] && baseline_mode="pruned"
    it_log "   live chain: ${mdir:-?} (${fstype:-unknown}, ${baseline_mode})"

    # Classify any supplied chains by prune mode relative to the live baseline.
    local opp_dir opp_label same_dir
    if [ "$bp" = "1" ]; then
        opp_dir="${FULL_DATA_DIR:-}"
        opp_label="full"
        same_dir="${PRUNED_DATA_DIR:-}"
    else
        opp_dir="${PRUNED_DATA_DIR:-}"
        opp_label="pruned"
        same_dir="${FULL_DATA_DIR:-}"
    fi

    # A same-mode copy (e.g. the CoW pruned chain) — snapshot isolation for destructive scenarios.
    if [ -n "$same_dir" ]; then
        local sfs
        sfs="$(box_fstype "$same_dir")"
        if rx "test -e $(quote_arg "$same_dir")/lmdb/data.mdb" >/dev/null 2>&1; then
            case "$sfs" in
            btrfs | zfs | xfs) it_pass "snapshot-isolated $baseline_mode chain on a CoW FS ($same_dir, $sfs) — destructive scenarios needn't touch the live chain" ;;
            *) it_log "   same-mode copy at $same_dir ($sfs — not CoW)" ;;
            esac
        else
            it_warn "supplied same-mode dir has no lmdb/data.mdb ($same_dir)"
        fi
    fi

    # The opposite-mode chain is what unlocks the OTHER value of the prune axis.
    if [ -n "$opp_dir" ]; then
        if rx "test -e $(quote_arg "$opp_dir")/lmdb/data.mdb" >/dev/null 2>&1; then
            it_pass "both prune modes exercisable (live=$baseline_mode + supplied $opp_label chain at $opp_dir)"
        else
            it_fail "supplied $opp_label chain present" "$opp_dir has no lmdb/data.mdb"
        fi
    elif [ "$cow_live" -eq 1 ]; then
        it_pass "prune axis: live FS is snapshot-capable ($fstype) — the $opp_label variant can be built cheaply"
    else
        it_warn "prune axis: only $baseline_mode is testable live — no $opp_label chain supplied, so $opp_label scenarios skip (cover that mode via the fake mini-stack, or build one)"
    fi

    # The prune axis infers CoW from the fstype above, which is a proxy. --image-upgrade does not
    # get to infer: it takes `cp --reflink=always` snapshots of every writable mount, so the only
    # honest check is to ATTEMPT one. A WARN, not a FAIL — a box without reflink is still a fine
    # release server for everything except that one gate, and saying so here is what stops someone
    # scheduling a destructive upgrade run that cannot reach its own rollback net.
    if [ -n "$mdir" ]; then
        local probe rc
        probe="$mdir/.itest-reflink-probe-$$"
        rx "rm -rf $(quote_arg "$probe") $(quote_arg "$probe.copy"); mkdir -p $(quote_arg "$probe") && : > $(quote_arg "$probe/f") && cp -a --reflink=always -- $(quote_arg "$probe") $(quote_arg "$probe.copy")" >/dev/null 2>&1
        rc=$?
        rx "rm -rf $(quote_arg "$probe") $(quote_arg "$probe.copy")" >/dev/null 2>&1 || true
        if [ "$rc" = 0 ]; then
            it_pass "writable-mount filesystem supports cp --reflink=always (--image-upgrade can snapshot)"
        else
            it_warn "no reflink on the chain FS (${fstype:-unknown}) — --image-upgrade cannot take its rollback snapshots and will refuse; every other phase is unaffected"
        fi
    fi

    # 3. Disk headroom on the live chain FS (room to operate + hold a co-located second chain).
    if [ -n "$mdir" ]; then
        local avail
        avail="$(box_avail_gb "$mdir")"
        if [ -n "$avail" ] && [ "$avail" -ge 100 ] 2>/dev/null; then
            it_pass "disk headroom on the live chain FS (${avail} GiB free)"
        else
            it_warn "low disk headroom on the live chain FS (${avail:-?} GiB free) — snapshots / a full+pruned matrix may not fit"
        fi
    fi

    # 4. Secrets must not be world/group readable (the box holds wallet/RPC creds + onion keys).
    local envmode
    envmode="$(box_mode .env)"
    case "$envmode" in
    "" | *[!0-9]*) it_warn ".env permissions unknown" ;;
    ?00) it_pass ".env is owner-only (mode $envmode)" ;;
    *) it_fail ".env is owner-only" "mode is $envmode — group/other can read RPC creds & onions; run: chmod 600 .env" ;;
    esac

    # 5. The dashboard must sit behind Caddy on localhost, never bound to a public interface.
    local d_addrs exposed=0 st _q1 _q2 laddr
    d_addrs="$(rx "ss -tlnH 'sport = :8000' 2>/dev/null")"
    if [ -z "$d_addrs" ]; then
        it_warn "nothing listening on :8000 (dashboard) — can't assess exposure"
    else
        # shellcheck disable=SC2034  # shared through the assembled runner scope
        while read -r st _q1 _q2 laddr _; do
            [ -n "$laddr" ] || continue
            case "$laddr" in 127.0.0.1:* | "[::1]:"*) : ;; *) exposed=1 ;; esac
        done <<<"$d_addrs"
        if [ "$exposed" -eq 0 ]; then it_pass "dashboard bound to localhost only (Caddy fronts it)"; else it_fail "dashboard bound to localhost only" "it is listening on a non-loopback address — do not expose the dashboard directly"; fi
    fi

    # 6. The backup/rollback safety net must be usable (writable backups dir + tar).
    if rx "mkdir -p backups && touch backups/.itest-rw 2>/dev/null && rm -f backups/.itest-rw && command -v tar" >/dev/null 2>&1; then
        it_pass "backup/rollback prerequisites present (writable backups/, tar)"
    else
        it_fail "backup prerequisites present" "backups/ not writable or tar missing — --safety-backup won't work"
    fi
}

# --- Lifecycle + edge phase (--lifecycle) -----------------------------------
