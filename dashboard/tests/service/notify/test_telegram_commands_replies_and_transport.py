# ruff: noqa: F403, F405
from tests.service.notify._telegram_commands_support import *  # noqa: F403


def test_luck_na_before_hashrate_history():
    # Cold stack (#84 pitfall): no p2pool_1h / pool difficulty yet → n/a, never inf or "0s".
    out = tc.format_luck(_metrics())  # cadence fields at their 0.0 defaults
    assert "Since pool's last block: n/a" in out
    assert "Est. time to a share: n/a" in out
    assert "Luck: n/a" in out
    assert "Your PPLNS weight: 0" in out


def test_daily_summary_is_a_24h_retrospective():
    now = 1_000_000
    data = {
        "workers": [
            {"name": "miner-0", "status": "online", "h24h": 30000},
            {"name": "miner-1", "status": "online", "h24h": 20000},
            {"name": "old", "status": "offline", "h24h": 0},
        ],
        # 2 shares within 24h, 1 older.
        "shares": [{"ts": now - 100}, {"ts": now - 90000}, {"ts": now - 200}],
        "system": {"disk": {"percent_str": "42%"}},
        "network": {"reward": 600_000_000_000},
    }
    out = tc.format_daily_summary(
        _metrics(
            xvb_enabled=True,
            p2pool_24h=40000,
            xvb_routed_24h=10000,
            current_tier="Donor",
            workers_online=2,
            workers_total=3,
        ),
        data,
        now=now,
    )
    assert "Daily summary — " in out  # date+time stamped
    assert "24h hashrate: 50.00 kH/s" in out  # sum of per-rig h24h (30k + 20k)
    assert "20% to XvB" in out  # 10k / (40k + 10k)
    assert "P2Pool 40.00 kH/s" in out and "XvB 10.00 kH/s" in out  # apportioned, sums to fleet
    assert "XvB tier: Donor" in out
    assert "Shares (24h): 2" in out
    assert "Est. earnings" in out
    assert "miner-0: 30.00 kH/s" in out
    assert "old" not in out  # offline rig excluded
    assert "Disk: 42% used" in out
    # The retrospective drops live-status lines like node sync.
    assert "synced" not in out.lower()


def test_daily_summary_without_xvb_omits_split():
    data = {"workers": [{"name": "m", "status": "online", "h24h": 5000}], "shares": []}
    out = tc.format_daily_summary(_metrics(xvb_enabled=False), data, now=0)
    assert "24h hashrate: 5.00 kH/s" in out
    assert "to XvB" not in out


def test_daily_summary_incident_log():
    m, data = _metrics(xvb_enabled=False), {"workers": [], "shares": []}
    # Incidents present → a roll-up line, highest count first.
    out = tc.format_daily_summary(m, data, now=0, incidents={"worker_offline": 3, "node_down": 1})
    assert "Incidents (24h): 3× worker offline · 1× node down" in out
    # Empty tally → an explicit all-clear.
    assert "No incidents in the last 24h" in tc.format_daily_summary(m, data, now=0, incidents={})
    # Not tracked (None) → no incident line at all.
    none = tc.format_daily_summary(m, data, now=0, incidents=None)
    assert "Incidents" not in none and "No incidents" not in none


def test_host_label_prefix():
    assert tc.format_sync(_metrics(), host_label="rig-box").startswith("[rig-box] ")
    # The placeholder is never printed.
    assert not tc.format_sync(_metrics(), host_label="Unknown Host").startswith("[")


def test_reply_for_help_and_unknown_need_no_metrics():
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    bot = tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="1", host_label="")
    assert "/status" in bot.reply_for("/help")
    assert "Unknown command" in bot.reply_for("/nope")
    assert bot.reply_for("just chatting") is None


def test_reply_for_status_uses_mining_flag(monkeypatch):
    bot = _bot(monkeypatch, latest_data={"miner_released": True, "workers_rejected": False})
    assert "🟢 active" in bot.reply_for("/status")
    # Rejected workers (node-down failover) reads as not mining even when released.
    bot2 = _bot(monkeypatch, latest_data={"miner_released": True, "workers_rejected": True})
    assert "🔴 not mining" in bot2.reply_for("/status")


def test_reply_for_status_merge_mining_from_tari_snapshot(monkeypatch):
    # gRPC linked = connected AND active (the #313 rule) → the "linked" line.
    bot = _bot(monkeypatch, latest_data={"tari": {"connected": True, "active": True}})
    assert "Merge-mining: 🟢 Tari linked" in bot.reply_for("/status")
    # Node up but gRPC not ready (the exact gap that hid #313) → "not linked".
    bot2 = _bot(monkeypatch, latest_data={"tari": {"connected": False, "active": True}})
    assert "Merge-mining: ⏸ Tari not linked" in bot2.reply_for("/status")


def test_reply_for_pool_reads_share_snapshot(monkeypatch):
    data = {"proxy_summary": {"accepted": 999, "rejected": 1, "best": 555}}
    bot = _bot(monkeypatch, latest_data=data, pool_type="Mini")
    out = bot.reply_for("/pool")
    assert "Best share: 💎 555" in out and "999 ✓ / 1 ✗" in out


def test_reply_for_luck(monkeypatch):
    bot = _bot(monkeypatch, expected_share_sec=3600.0, luck_pct=100.0, own_pplns_weight=42.0)
    out = bot.reply_for("/luck")
    assert "Luck: 100%" in out and "Your PPLNS weight: 42" in out


def test_reply_for_workers_reads_snapshot(monkeypatch):
    workers = [{"name": "z", "status": "online", "h15": 1000}]
    bot = _bot(monkeypatch, latest_data={"workers": workers})
    assert "z" in bot.reply_for("/workers")


def test_reply_for_system_reads_snapshot_without_metrics():
    # /system reads only the raw snapshot — build_metrics must not be needed (left unstubbed).
    ds = SimpleNamespace(latest_data={"system": {"cpu_percent": "9%"}}, state_manager=None)
    bot = tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="1", host_label="")
    assert "CPU: 9%" in bot.reply_for("/system")


def test_reply_for_pool_and_xvb(monkeypatch):
    bot = _bot(monkeypatch, latest_data={}, pool_type="Nano")
    assert "P2Pool Nano" in bot.reply_for("/pool")
    assert "XvB" in bot.reply_for("/xvb")


def test_reply_for_earnings(monkeypatch):
    bot = _bot(monkeypatch, latest_data={"network": {"reward": 600_000_000_000}}, p2pool_1h=8000.0)
    reply = bot.reply_for("/earnings")
    assert "XMR/day" in reply
    # Payout confirmation is off by default, so the estimate stands alone and storage is never read
    # (the stub state_manager has no get_payouts — reaching for it would raise).
    assert "Confirmed" not in reply


def test_reply_for_earnings_rolls_up_stored_payouts(monkeypatch):
    # Feature on: /earnings reads the stored payouts per chain and appends the running totals.
    # The flags are read off the config MODULE at call time, so flipping them here takes effect
    # without a re-import — the same handling build_state uses.
    monkeypatch.setattr(tc.config, "PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(tc.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
    now = time.time()
    yday = previous_local_day(now)[0] + 3_600
    stored = {
        "monero": [{"ts": yday, "amount_atomic": _ONE_XMR}],
        "tari": [{"ts": yday, "amount_atomic": 2_000_000}],  # 2 XTM
    }
    bot = _bot(monkeypatch, latest_data={"network": {"reward": 600_000_000_000}}, p2pool_1h=8000.0)
    bot.data_service.state_manager.get_payouts = stored.get
    reply = bot.reply_for("/earnings")
    assert "Confirmed XMR: yesterday 1.0000 XMR" in reply  # piconero divisor
    assert "Confirmed XTM: yesterday 2.0000 XTM" in reply  # microTari divisor


def test_reply_for_earnings_skips_the_chain_whose_wallet_is_off(monkeypatch):
    # Monero confirmation on, Tari off → only the XMR totals appear, and Tari payouts are not read.
    monkeypatch.setattr(tc.config, "PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(tc.config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
    asked = []

    def _payouts(chain):
        asked.append(chain)
        return []

    bot = _bot(monkeypatch, latest_data={"network": {"reward": 600_000_000_000}}, p2pool_1h=8000.0)
    bot.data_service.state_manager.get_payouts = _payouts
    reply = bot.reply_for("/earnings")
    assert asked == ["monero"]
    assert "Confirmed XMR" in reply and "Confirmed XTM" not in reply


def test_reply_for_hashrate_and_sync(monkeypatch):
    workers = [{"name": "z", "status": "online", "h15": 1000}]
    bot = _bot(monkeypatch, latest_data={"workers": workers})
    assert "Hashrate" in bot.reply_for("/hashrate")
    assert "Sync status" in bot.reply_for("/sync")


def test_safe_reply_for_swallows_errors(monkeypatch):
    # A formatting/read bug in reply_for must never kill the poll loop — it just goes quiet.
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    bot = tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="1")

    def boom(_text):
        raise RuntimeError("kaboom")

    monkeypatch.setattr(bot, "reply_for", boom)
    assert bot._safe_reply_for("/status") is None


def test_disabled_without_token_or_chat():
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    assert not tc.TelegramCommandBot(ds, enabled=True, bot_token="", chat_id="1").enabled
    assert not tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="").enabled
    assert not tc.TelegramCommandBot(ds, enabled=False, bot_token="t", chat_id="1").enabled
    assert tc.TelegramCommandBot(ds, enabled=True, bot_token="t", chat_id="1").enabled


async def test_run_is_noop_when_disabled():
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    bot = tc.TelegramCommandBot(ds, enabled=False, bot_token="", chat_id="")
    # Returns immediately without touching the network — no session, no poll.
    await bot.run()


async def test_handle_update_ignores_foreign_chat(monkeypatch):
    bot = _bot(monkeypatch)
    sent = []
    monkeypatch.setattr(bot, "_send", sent.append)  # _send is sync now (run via to_thread)
    # chat_id 999 != configured 42 → dropped, nothing sent.
    await bot._handle_update({"message": {"chat": {"id": 999}, "text": "/help"}})
    assert sent == []


async def test_handle_update_replies_to_configured_chat(monkeypatch):
    bot = _bot(monkeypatch)
    sent = []
    monkeypatch.setattr(bot, "_send", sent.append)
    await bot._handle_update({"message": {"chat": {"id": 42}, "text": "/help"}})
    assert len(sent) == 1 and "/status" in sent[0]


def test_get_updates_parses_results_over_tor(monkeypatch):
    bot = _make_bot()
    bot._offset = 7
    seen = {}

    def fake_get(url, params=None, timeout=None, proxies=None):
        seen.update(url=url, params=params, proxies=proxies, timeout=timeout)
        return _Resp({"ok": True, "result": [{"update_id": 8}]})

    monkeypatch.setattr(tc, "bounded_get", fake_get)
    assert bot._get_updates(tc.LONG_POLL_SECONDS) == [{"update_id": 8}]
    assert "bottok" in seen["url"] and seen["params"]["offset"] == 7  # token + offset forwarded
    assert seen["proxies"] == {"http": "socks5h://tor:9050", "https": "socks5h://tor:9050"}
    # (connect, read) tuple with the read timeout outlasting Telegram's long-poll hold — drop the
    # tuple (or shrink the read side) and every legitimate long poll aborts mid-hold (#698).
    connect, read = seen["timeout"]
    assert read > seen["params"]["timeout"] >= 0 and connect > 0
    # Batch cap: without it, an over-cap batch could never be parsed, so the offset could never
    # advance past it and the poll loop would re-fetch it forever (#660 follow-up).
    assert seen["params"]["limit"] == tc.GETUPDATES_LIMIT


def test_get_updates_not_ok_returns_empty(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(tc, "bounded_get", lambda *a, **k: _Resp({"ok": False}))
    assert bot._get_updates(0) == []


def test_prime_offset_skips_backlog(monkeypatch):
    # Backlog spanning two limit-capped batches: prime drains both, then the empty batch stops it.
    bot = _make_bot()
    batches = iter(
        [
            _Resp({"ok": True, "result": [{"update_id": 3}, {"update_id": 9}]}),
            _Resp({"ok": True, "result": [{"update_id": 12}]}),
            _Resp({"ok": True, "result": []}),
        ]
    )
    monkeypatch.setattr(tc, "bounded_get", lambda *a, **k: next(batches))
    bot._prime_offset()
    assert bot._offset == 13  # past the last pending update, across batches


def test_prime_offset_swallows_error(monkeypatch):
    bot = _make_bot()

    def boom(*a, **k):
        raise OSError("offline")

    monkeypatch.setattr(tc, "bounded_get", boom)
    bot._prime_offset()  # must not raise
    assert bot._offset is None


def test_send_posts_over_tor(monkeypatch):
    bot = _make_bot()
    seen = {}

    def fake_post(url, json=None, timeout=None, proxies=None):
        seen.update(url=url, body=json, proxies=proxies)
        return _Resp({"ok": True})

    monkeypatch.setattr(tc.requests, "post", fake_post)
    bot._send("hi")
    assert (
        "bottok" in seen["url"] and seen["body"]["chat_id"] == "42" and seen["body"]["text"] == "hi"
    )
    assert seen["proxies"]["https"] == "socks5h://tor:9050"


def test_send_swallows_network_error(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(tc.requests, "post", lambda *a, **k: _Resp(raise_status=True))
    bot._send("hi")  # must not raise


async def test_run_processes_update_then_honours_cancel(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(bot, "_prime_offset", lambda: None)
    handled = []

    async def _fake_handle(update):
        handled.append(update)

    calls = {"n": 0}

    def _fake_get(poll_timeout):
        calls["n"] += 1
        if calls["n"] == 1:
            return [{"update_id": 1}]
        raise asyncio.CancelledError

    monkeypatch.setattr(bot, "_handle_update", _fake_handle)
    monkeypatch.setattr(bot, "_get_updates", _fake_get)
    with pytest.raises(asyncio.CancelledError):
        await bot.run()
    assert handled == [{"update_id": 1}] and bot._offset == 2


async def test_run_backs_off_on_poll_error(monkeypatch):
    bot = _make_bot()
    monkeypatch.setattr(bot, "_prime_offset", lambda: None)
    slept = []

    async def _sleep(secs):
        slept.append(secs)
        raise asyncio.CancelledError  # break out after the first backoff

    def _boom(poll_timeout):
        raise OSError("telegram unreachable")

    monkeypatch.setattr(tc.asyncio, "sleep", _sleep)
    monkeypatch.setattr(bot, "_get_updates", _boom)
    with pytest.raises(asyncio.CancelledError):
        await bot.run()
    assert slept == [tc.POLL_ERROR_BACKOFF_SECONDS]
