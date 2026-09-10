# ruff: noqa: F401
"""Unit tests for the on-demand Telegram command interface (Issue #45).

Covers command parsing, the pure reply formatters (fed hand-built Metrics), reply routing
(``build_metrics`` stubbed so no DB is touched), single-chat access control, and the
enabled/disabled gating. No network — the transport is stubbed throughout.
"""

import asyncio
import time
from dataclasses import replace
from types import SimpleNamespace

import pytest

from mining_dashboard.service.metrics import Metrics, SyncMetric
from mining_dashboard.service.notify import telegram_commands as tc
from mining_dashboard.service.xvb.earnings import confirmed_payouts_summary, previous_local_day

_SYNCED = SyncMetric(
    percent=100, current=10, target=10, remaining=0, has_target=True, done=True, down=False
)

_DOWN = SyncMetric(
    percent=0, current=0, target=0, remaining=0, has_target=False, done=False, down=True
)

_SYNCING = SyncMetric(
    percent=42.5, current=850, target=2000, remaining=1150, has_target=True, done=False, down=False
)

_BASE = Metrics(
    total_h15=10500.0,
    p2pool_1h=8000.0,
    p2pool_24h=8100.0,
    xvb_1h=2100.0,
    xvb_24h=2300.0,
    xvb_routed_1h=2000.0,
    xvb_routed_24h=2050.0,
    stratum_h15=10300.0,
    stratum_h1h=10400.0,
    stratum_h24h=10200.0,
    mode="P2POOL",
    xvb_enabled=True,
    current_tier="Donor",
    target_tier="Donor",
    target_threshold=1000.0,
    target_sustainable=True,
    low_hr_warning=False,
    xvb_fail_count=0,
    xvb_last_update=0,
    workers_online=2,
    workers_total=3,
    shares_in_window=5,
    pplns_window=2160,
    block_time=10,
    pool_type="Mini",
    pool_hashrate=120_000_000.0,
    pool_difficulty=250_000_000.0,
    network_difficulty=380_000_000_000.0,
    network_height=3210001,
    global_syncing=False,
    monero=_SYNCED,
    tari=_SYNCED,
    monero_mode="Unknown",
    tari_mining=True,
)


def _metrics(**over):
    return replace(_BASE, **over)


_NET = {"reward": 600_000_000_000}

_ONE_XMR = 1_000_000_000_000


def _bot(monkeypatch, latest_data=None, db_healthy=True, **over):
    monkeypatch.setattr(tc, "build_metrics", lambda data, sm: _metrics(**over))
    sm = SimpleNamespace(is_db_healthy=lambda: db_healthy)
    ds = SimpleNamespace(latest_data=latest_data or {}, state_manager=sm)
    return tc.TelegramCommandBot(ds, enabled=True, bot_token="tok", chat_id="42", host_label="")


class _Resp:
    """Minimal stand-in for a requests.Response."""

    def __init__(self, payload=None, raise_status=False):
        self._payload = payload or {}
        self._raise = raise_status

    def raise_for_status(self):
        if self._raise:
            raise RuntimeError("http error")

    def json(self):
        return self._payload


def _make_bot(tor_proxy="socks5h://tor:9050"):
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    return tc.TelegramCommandBot(
        ds, enabled=True, bot_token="tok", chat_id="42", tor_proxy=tor_proxy
    )


def _control_bot(monkeypatch, allowed=("7",), latest_data=None, **over):
    monkeypatch.setattr(tc, "build_metrics", lambda d, sm: _metrics(**over))
    sm = SimpleNamespace(is_db_healthy=lambda: True)
    ds = SimpleNamespace(latest_data=latest_data or {}, state_manager=sm)
    return tc.TelegramCommandBot(
        ds,
        enabled=True,
        bot_token="tok",
        chat_id="42",
        host_label="",
        control_enabled=True,
        allowed_ids=allowed,
        confirm_timeout=60,
    )


class _Transport:
    """Records every Telegram POST and returns an OK response, so the real _send / _send_confirm /
    _answer_callback run. ``token`` pulls the confirm token straight out of the sent inline button."""

    def __init__(self):
        self.posts = []

    def install(self, monkeypatch):
        def fake_post(url, json=None, **kw):
            self.posts.append((url, json or {}))
            return _Resp({"ok": True})

        monkeypatch.setattr(tc.requests, "post", fake_post)
        return self

    @property
    def token(self):
        for _url, body in self.posts:
            markup = body.get("reply_markup") or {}
            for row in markup.get("inline_keyboard", []):
                for btn in row:
                    if str(btn.get("callback_data", "")).startswith("confirm:"):
                        return btn["callback_data"][len("confirm:") :]
        return None

    def texts(self):
        return [b.get("text", "") for _u, b in self.posts if "text" in b]


__all__ = [name for name in globals() if not name.startswith("__")]
