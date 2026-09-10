# ruff: noqa: F403, F405
from tests.service.notify._telegram_commands_support import *  # noqa: F403


@pytest.mark.parametrize(
    "text,expected",
    [
        ("/status", "status"),
        ("/info", "info"),
        ("  /sync  ", "sync"),
        ("/HASHRATE", "hashrate"),
        ("/system", "system"),
        ("/pool", "pool"),
        ("/xvb", "xvb"),
        ("/earnings", "earnings"),
        ("/luck", "luck"),
        ("/luck@Bot", "luck"),
        ("/status@PitheadBot", "status"),  # group @mention suffix stripped
        ("/workers now please", "workers"),  # only the first word matters
        ("/help", "help"),
        ("/frobnicate", "unknown"),  # a slash command we don't answer
        ("hello there", None),  # plain chatter is ignored
        ("", None),
        (None, None),
        ("/", None),
    ],
)
def test_parse_command(text, expected):
    assert tc.parse_command(text) == expected


def test_status_active():
    out = tc.format_status(_metrics(), mining_active=True)
    assert "Monero node: 🟢 synced" in out
    assert "Mining: 🟢 active (P2POOL)" in out
    assert "Workers: 2/3 online" in out
    assert "10.50 kH/s" in out
    assert "PPLNS shares: 5 in window" in out


def test_status_syncing_beats_mining_flag():
    # While the whole stack is syncing, the reply says "holding", never "active".
    out = tc.format_status(_metrics(global_syncing=True), mining_active=True)
    assert "holding" in out
    assert "active" not in out


def test_status_node_down_and_not_mining():
    out = tc.format_status(_metrics(monero=_DOWN), mining_active=False)
    assert "Monero node: 🔴 down" in out
    assert "Mining: 🔴 not mining" in out


def test_status_xvb_split_line():
    # XvB on with routed history → one "24h split" line, same math as the daily summary.
    out = tc.format_status(_metrics(), mining_active=True)
    assert "24h split" in out
    assert "P2Pool 8.10 kH/s" in out
    assert "XvB 2.05 kH/s" in out
    assert "20% to XvB" in out  # 2050 / (8100 + 2050) ≈ 20%


def test_status_xvb_off_omits_split():
    out = tc.format_status(_metrics(xvb_enabled=False), mining_active=True)
    assert "to XvB" not in out


def test_status_xvb_no_history_omits_split():
    # No routed history yet (both 24h averages zero) → the line is absent, not "0%".
    out = tc.format_status(_metrics(p2pool_24h=0, xvb_routed_24h=0), mining_active=True)
    assert "24h split" not in out


def test_hashrate_lists_online_workers_desc():
    workers = [
        {"name": "rig-a", "status": "online", "h15": 3000},
        {"name": "rig-b", "status": "online", "h15": 7000},
        {"name": "rig-c", "status": "offline", "h15": 0},
    ]
    out = tc.format_hashrate_reply(_metrics(), workers)
    # Highest first, offline excluded.
    assert out.index("rig-b") < out.index("rig-a")
    assert "rig-c" not in out


def test_hashrate_no_online_workers():
    out = tc.format_hashrate_reply(_metrics(), [{"name": "x", "status": "offline"}])
    assert "No workers online." in out


def test_hashrate_uses_effective_rate_for_fresh_worker():
    # A just-connected rig has no 10m (h15) history yet but is mining — it must show its live 1m
    # rate (the same value the total counts), never 0.00. (This was the reported inconsistency.)
    workers = [{"name": "fresh", "status": "online", "h15": 0, "h60": 42000, "h10": 42000}]
    out = tc.format_hashrate_reply(_metrics(), workers)
    assert "42.00 kH/s" in out
    assert "0.00 H/s" not in out


def test_workers_hashrate_uses_effective_rate():
    workers = [{"name": "fresh", "status": "online", "h15": 0, "h60": 5000, "h10": 5000}]
    assert "5.00 kH/s" in tc.format_workers(workers)


def test_workers_online_first_with_offline_flagged():
    workers = [
        {"name": "off-1", "status": "offline", "h15": 0},
        {"name": "on-1", "status": "online", "h15": 5000, "uptime": 3661},
    ]
    out = tc.format_workers(workers)
    lines = out.splitlines()
    assert "🟢 on-1" in lines[1] and "up 1h 1m" in lines[1]  # online first, uptime shown
    assert "🔴 off-1 — offline" in lines[2]


def test_workers_empty():
    assert "No workers connected." in tc.format_workers([])


def test_status_node_syncing_percent():
    # _node_state's "syncing %" branch (not down, not done).
    out = tc.format_status(_metrics(monero=_SYNCING), mining_active=True)
    assert "Monero node: ⏳ syncing 42.5%" in out


def test_sync_line_variants():
    out = tc.format_sync(_metrics(monero=_SYNCING, tari=_DOWN))
    assert "Monero: ⏳ 42.5% (850/2,000)" in out
    assert "Tari: 🔴 node down" in out


def test_sync_line_no_target():
    # A chain that's syncing but hasn't discovered a target height yet.
    no_target = SyncMetric(
        percent=12.0, current=0, target=0, remaining=0, has_target=False, done=False, down=False
    )
    assert "Monero: ⏳ syncing 12.0%" in tc.format_sync(_metrics(monero=no_target))


def test_system_reads_snapshot():
    system = {
        "disk": {"used_gb": 120.4, "total_gb": 500.0, "percent_str": "24%"},
        "memory": {"used_gb": 3.2, "total_gb": 16.0, "percent_str": "20%"},
        "cpu_percent": "12.5%",
        "load": "0.50 0.40 0.30",
        "hugepages": ["Enabled", "status-ok", "3072/3072"],
    }
    out = tc.format_system(system)
    assert "Disk: 120.4/500.0 GB (24%)" in out
    assert "RAM: 3.2/16.0 GB (20%)" in out
    assert "CPU: 12.5%" in out
    assert "HugePages: Enabled (3072/3072)" in out


def test_system_disk_reads_in_tb_on_large_volumes():
    # Threshold mechanics live in test_utils.py; this proves /system wires the unit through.
    out = tc.format_system({"disk": {"used_gb": 408.6, "total_gb": 3666.4, "percent_str": "11.1%"}})
    assert "Disk: 0.4/3.6 TB (11.1%)" in out


@pytest.mark.parametrize(
    "n,expected",
    [
        (0, "0"),
        (42, "42"),
        (999, "999"),
        (1500, "1.50 K"),
        (380e9, "380.00 G"),
        (2.5e12, "2.50 T"),
        (3e18, "3.00 E"),  # beyond peta — the fallback branch
    ],
)
def test_human_count(n, expected):
    assert tc._human_count(n) == expected


def test_pool_reads_metrics():
    out = tc.format_pool(
        _metrics(pool_type="Mini", network_height=3210001, network_difficulty=380e9)
    )
    assert "P2Pool Mini" in out
    assert "height 3,210,001" in out
    assert "diff 380.00 G" in out
    assert "5 in window" in out  # shares_in_window from _BASE


def test_pool_share_health_and_best_when_present():
    # Proxy /summary + found blocks enrich /pool (#82): acceptance rate, best share, blocks.
    data = {
        "pool": {"pool": {"blocks_found": 3}},
        "proxy_summary": {"accepted": 125_000, "rejected": 40, "best": 2_345_678},
    }
    out = tc.format_pool(_metrics(), data)
    assert "Blocks found: 3" in out
    assert "125,000 ✓ / 40 ✗ (0.03% rejects)" in out
    assert "Best share: 💎 2,345,678" in out


def test_pool_omits_share_lines_before_first_poll():
    # No proxy data yet (fresh start) → no zeroed share/best/blocks lines, just the core figures.
    out = tc.format_pool(_metrics(), {})
    assert "Shares to pool" not in out
    assert "Best share" not in out
    assert "Blocks found" not in out
    assert "Effort" not in out  # no stratum data → no effort line


def test_pool_effort_when_stratum_present():
    # Effort is a luck indicator; shown only once stratum has been polled (the key is present).
    out = tc.format_pool(_metrics(), {"stratum": {"current_effort": 87.3}})
    assert "Effort: 87.3%" in out
    # Effort right after a block can legitimately be 0.0 — still shown (key present), not hidden.
    assert "Effort: 0.0%" in tc.format_pool(_metrics(), {"stratum": {"current_effort": 0.0}})


def test_xvb_enabled_with_share():
    out = tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=5, xvb_1h=2100, xvb_24h=2300))
    assert "Current tier: Donor" in out
    assert "raffle-eligible" in out
    # Credited averages (what XvB measures → sets the tier) are shown alongside routed.
    assert "Credited by XvB: 2.10 kH/s (1h) · 2.30 kH/s (24h)" in out


def test_xvb_tier_threshold_cost_and_not_a_payout_label():
    # #118: /xvb carries the target threshold, the cost framing (holding a tier ≈ donating its
    # threshold continuously), and the explicit not-a-payout labelling.
    out = tc.format_xvb(_metrics(target_threshold=10_000.0, target_sustainable=True))
    assert "Target threshold: 10.00 kH/s (sustainable)" in out
    assert "costs ~10.00 kH/s donated continuously" in out
    assert "not an XMR payout" in out


def test_xvb_unsustainable_target_flagged():
    out = tc.format_xvb(_metrics(target_threshold=10_000.0, target_sustainable=False))
    assert "NOT sustainable at your hashrate" in out


def test_xvb_no_sustainable_tier():
    # Auto mode with too little hashrate resolves to threshold 0 — say so instead of "0 H/s".
    out = tc.format_xvb(_metrics(target_threshold=0.0, target_sustainable=False))
    assert "No donor tier is sustainable" in out
    assert "Target threshold:" not in out


def test_xvb_stale_warns():
    out = tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=5, xvb_stale=True))
    assert "stale" in out
    assert "stale" not in tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=5))


def test_xvb_no_share_warns():
    out = tc.format_xvb(_metrics(xvb_enabled=True, shares_in_window=0))
    assert "wins skipped" in out


def test_xvb_disabled():
    assert "disabled" in tc.format_xvb(_metrics(xvb_enabled=False))


def test_status_merge_mining_line():
    linked = tc.format_status(_metrics(), True, merge_mining=True)
    assert "Merge-mining: 🟢 Tari linked" in linked
    down = tc.format_status(_metrics(), True, merge_mining=False)
    assert "Merge-mining: ⏸ Tari not linked" in down
    # None (Tari not yet polled / not in play) omits the line entirely.
    assert "Merge-mining" not in tc.format_status(_metrics(), True)


def test_earnings_estimate():
    # network reward present + a real difficulty → a positive daily figure, rendered with the
    # dashboard card's adaptive-precision XMR rule (#387): these figures sit in the 6-dp band.
    # coeff = 0.6 XMR / 380e9 * 86400 ≈ 1.364e-7 XMR per H/s per day.
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0, p2pool_24h=8100.0), {"reward": 600_000_000_000}
    )
    assert "1h avg" in out and "~0.001091 XMR/day" in out
    # The 24h average is shown once available and drives the steadier 30d projection.
    assert "24h avg" in out and "~0.001105 XMR/day" in out
    assert "~0.033150 XMR/30d" in out


def test_earnings_falls_back_to_1h_30d_without_24h_history():
    # A fresh node with no 24h average yet still gets a 30d figure (from the 1h rate).
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0, p2pool_24h=0.0), {"reward": 600_000_000_000}
    )
    assert "24h avg" not in out
    assert "XMR/30d" in out


def test_earnings_unavailable_without_network_data():
    out = tc.format_earnings(_metrics(), {})  # no reward → coeff 0
    assert "unavailable" in out


def test_earnings_includes_tari_line_when_merge_mining():
    # #117: live Tari figures → a second line from the SAME 1h-average hashrate (merge-mined
    # alongside the XMR), at the same rate the dashboard calculator publishes.
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0, tari_reward=13_000.0, tari_difficulty=420_000_000_000),
        {"reward": 600_000_000_000},
    )
    expected = 8000.0 * (13_000.0 / 420_000_000_000 * 86_400)
    assert f"Tari (merge-mined alongside): ~{expected:.2f} XTM/day" in out
    assert "excludes XvB-donated hashrate" in out  # Tari no longer listed as excluded


def test_earnings_omits_tari_line_without_tari_figures():
    # Tari inactive / still syncing (reward+difficulty at 0) → no phantom XTM line.
    out = tc.format_earnings(_metrics(p2pool_1h=8000.0), {"reward": 600_000_000_000})
    assert "XTM" not in out
    assert "XMR/day" in out  # the XMR estimate is unaffected


def test_earnings_appends_confirmed_running_totals():
    # A year of history with a payout in each window → yesterday / 7d / 30d land as actuals under
    # the estimate, all complete (history predates every window), so no marker and no footnote.
    now = time.time()
    day_start, _ = previous_local_day(now)
    payouts = [
        {"ts": now - 365 * 86_400, "amount_atomic": _ONE_XMR},  # old — dates the history
        {"ts": day_start + 3_600, "amount_atomic": 2 * _ONE_XMR},  # yesterday
        {"ts": now - 3 * 86_400, "amount_atomic": 4 * _ONE_XMR},  # inside 7d
        {"ts": now - 20 * 86_400, "amount_atomic": 8 * _ONE_XMR},  # inside 30d only
    ]
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0), _NET, confirmed=confirmed_payouts_summary(payouts, now=now)
    )
    assert "Confirmed XMR: yesterday 2.0000 XMR · 7d 6.0000 XMR · 30d 14.0000 XMR" in out
    assert "*" not in out.split("Confirmed XMR:")[1]  # nothing partial → no marker, no footnote
    assert out.index("1h avg") < out.index("Confirmed XMR:")  # estimate leads, actuals follow


def test_earnings_marks_partial_windows_with_history_start():
    # History starts 3 days ago: yesterday is covered, 7d and 30d reach behind it and must say so
    # rather than reading as full windows.
    now = time.time()
    payouts = [{"ts": now - 3 * 86_400, "amount_atomic": _ONE_XMR}]
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0), _NET, confirmed=confirmed_payouts_summary(payouts, now=now)
    )
    yesterday, seven, thirty = out.split("Confirmed XMR: ")[1].splitlines()[0].split(" · ")
    assert not yesterday.endswith("*") and seven.endswith("*") and thirty.endswith("*")
    assert "* partial — recorded payout history starts " in out


def test_earnings_partial_footnote_names_an_empty_history():
    # Wallet on, nothing confirmed yet: the zeros are honest, but every window is partial and the
    # footnote says the history is empty rather than naming a date it doesn't have.
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0), _NET, confirmed=confirmed_payouts_summary([], now=time.time())
    )
    assert "Confirmed XMR: yesterday 0 XMR* · 7d 0 XMR* · 30d 0 XMR*" in out
    assert "* partial — recorded payout history is empty — no payouts confirmed yet." in out


def test_earnings_includes_confirmed_tari_totals():
    # #462 side: the same roll-up over microTari, rendered with the XTM precision the card uses.
    now = time.time()
    payouts = [{"ts": now - 2 * 86_400, "amount_atomic": 4_552_150_000}]  # 4552.15 XTM
    out = tc.format_earnings(
        _metrics(p2pool_1h=8000.0),
        _NET,
        tari_confirmed=confirmed_payouts_summary(payouts, now=now, divisor=1_000_000, unit="xtm"),
    )
    # History starts two days back, so yesterday is covered (no marker) while 7d/30d are not.
    assert "Confirmed XTM: yesterday 0 XTM · 7d 4552.1500 XTM* · 30d 4552.1500 XTM*" in out


def test_earnings_confirmed_survives_missing_network_data():
    # The estimate needs live network figures; the confirmed totals come off the wallet and don't.
    # A stack waiting on network data can still report what it was actually paid.
    now = time.time()
    payouts = [{"ts": now - 40 * 86_400, "amount_atomic": _ONE_XMR}]
    out = tc.format_earnings(_metrics(), {}, confirmed=confirmed_payouts_summary(payouts, now=now))
    assert "unavailable" in out
    assert "Confirmed XMR: yesterday 0 XMR · 7d 0 XMR · 30d 0 XMR" in out


def test_earnings_omits_confirmed_when_wallet_feature_is_off():
    # None (the default — no view-only wallet configured) → the estimate stands alone, exactly as
    # it read before payout confirmation existed.
    out = tc.format_earnings(_metrics(p2pool_1h=8000.0), _NET, confirmed=None, tari_confirmed=None)
    assert "Confirmed" not in out


def test_luck_reads_the_cadence_metrics():
    # #84: the four figures come straight off Metrics — the same fields the dashboard card shows.
    out = tc.format_luck(
        _metrics(
            last_block_ts=1,  # ancient → the "since" duration renders (days), not "n/a"
            expected_share_sec=3600.0,
            luck_pct=123.4,
            own_pplns_weight=1_234_567.0,
        )
    )
    assert "Since pool's last block: " in out and "n/a" not in out
    assert "Est. time to a share: 1h 0m" in out
    assert "Luck: 123%" in out
    assert "Your PPLNS weight: 1,234,567" in out
