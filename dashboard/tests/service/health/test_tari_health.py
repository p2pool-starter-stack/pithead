"""Tari chain health (#2464): the stale-tip / zero-peer / explorer-lag verdict and its alerts.

The production incident, replayed on a fake clock: a reachable node, gRPC answering, its tip frozen and
every peer banned. Each signal alone is amber, two are red, explorer lag alone is red, and each entry
into red alerts once, with the operator's restart as the next step. Detection only: remediation is #2827.
"""

import asyncio
from unittest.mock import AsyncMock

import pytest

from mining_dashboard.service.health import tari_health as th
from mining_dashboard.service.health.tari_health import TariChainHealth

MIN = 60
SYNCED = {"reachable": True, "is_syncing": False, "current": 342574}


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def _monitor(**kw):
    kw.setdefault("explorer_url", "")
    return TariChainHealth(**kw)


def _run(mon, minutes, sync=SYNCED, connections=0, start=0, step=MIN):
    """Observe once a minute from ``start`` for ``minutes``; return the last verdict."""
    for t in range(int(start * MIN), int((start + minutes) * MIN) + 1, step):
        v = mon.observe(sync, connections, t)
    return v


def test_green_while_the_tip_advances_with_peers():
    mon = _monitor()
    for i in range(120):
        v = mon.observe({**SYNCED, "current": 100 + i // 2}, 8, i * MIN)
    assert v["level"] == "green" and v["reasons"] == [] and v["advice"] == ""


def test_zero_peers_alone_is_amber_within_ten_minutes():
    mon = _monitor()
    assert _run(mon, 9, sync={**SYNCED, "current": 1}, connections=0)["level"] == "green"
    v = mon.observe({**SYNCED, "current": 1}, 0, 10 * MIN)
    assert v["level"] == "amber"
    assert v["reasons"] == ["0 peer connections for 10 min"]
    assert "restart the Tari node" in v["advice"]


def test_stale_tip_alone_is_amber_at_thirty_minutes():
    mon = _monitor()
    assert _run(mon, 29, connections=5)["level"] == "green"
    v = mon.observe(SYNCED, 5, 30 * MIN)
    assert v["level"] == "amber" and v["reasons"] == ["tip 342574 unchanged for 30 min"]


def test_stale_tip_and_zero_peers_together_are_red():
    """The #2465 incident: tip frozen, every peer banned, gRPC answering throughout."""
    v = _run(_monitor(), 30, connections=0)
    assert v["level"] == "red"
    assert v["reasons"] == ["tip 342574 unchanged for 30 min", "0 peer connections for 30 min"]


def test_explorer_lag_alone_is_red_and_logs_both_heights():
    """A node on a dead fork keeps peers and a creeping tip; only the explorer disagrees."""
    mon = _monitor()
    mon._explorer_tip = 342574 + th.LAG_BLOCKS + 1
    v = mon.observe(SYNCED, 3, 0)
    assert v["level"] == "red"
    assert v["reasons"] == [f"{th.LAG_BLOCKS + 1} blocks behind the public explorer (342625)"]
    assert (v["height"], v["explorer_tip"]) == (342574, 342625)


def test_explorer_within_the_lag_allowance_is_no_signal():
    mon = _monitor()
    mon._explorer_tip = 342574 + th.LAG_BLOCKS
    assert mon.observe(SYNCED, 3, 0)["level"] == "green"


def test_explorer_lag_during_initial_sync_is_not_counted():
    """A multi-day Tor initial sync is always behind the explorer; that is the sync view's job."""
    mon = _monitor()
    mon._explorer_tip = 400000
    v = mon.observe({"reachable": True, "is_syncing": True, "current": 1000, "target": 0}, 4, 0)
    assert v["level"] == "green"


def test_unreachable_cycles_keep_the_stall_but_not_the_zero_peer_clock():
    """A stall is measured across unreachable cycles; sustained zero peers is not, because a
    missing reading does not show zero peers (#2464 review round 11)."""
    mon = _monitor()
    mon.observe(SYNCED, 0, 0)
    for t in range(1, 30):
        mon.observe({"reachable": False}, None, t * MIN)
    v = mon.observe(SYNCED, 0, 30 * MIN)
    assert v["level"] == "amber" and v["reasons"] == ["tip 342574 unchanged for 30 min"]
    assert mon.observe(SYNCED, 0, 40 * MIN)["level"] == "red"  # ten observed zero-peer minutes


def test_a_missing_peer_count_is_not_a_zero():
    v = _run(_monitor(), 30, connections=None)
    assert v["reasons"] == ["tip 342574 unchanged for 30 min"] and v["level"] == "amber"


def test_recovery_to_green_after_catch_up():
    mon = _monitor()
    assert _run(mon, 30)["level"] == "red"
    v = mon.observe({**SYNCED, "current": 342575}, 6, 31 * MIN)
    assert v["level"] == "green"


# --- check(): I/O and alerts ----------------------------------------------------------


def test_check_alerts_once_on_red_and_names_the_operator_restart():
    clock, notify = Clock(), AsyncMock()
    mon = _monitor(notify=notify, clock=clock)
    for _ in range(36):
        v = asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    assert v["level"] == "red" and v["advice"] == th.RESTART_ADVICE
    text = notify.await_args_list[0].args[0]
    assert "Tari node is not following the chain" in text and "./pithead restart tari" in text
    assert notify.await_count == 1  # red is alerted once, not every cycle


def test_the_monitor_detects_only_it_holds_no_container_control():
    """Remediation (restart, merge-mining pause) is #2827's: nothing here can stop a container."""
    mon = _monitor()
    assert not any("docker" in name or "restart" in name for name in vars(mon))


def test_recovery_note_after_a_red_alert():
    clock, notify = Clock(), AsyncMock()
    mon = _monitor(notify=notify, clock=clock)
    for _ in range(31):
        asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    asyncio.run(mon.check({**SYNCED, "current": 342575}, 5))
    assert (
        notify.await_args_list[-1].args[0] == "\U0001f7e2 ⛓️ Tari node is following the chain again."
    )


def test_explorer_is_fetched_hourly_and_a_failure_contributes_nothing():
    clock, calls = Clock(), []

    def explorer(url):
        calls.append(url)
        return None

    mon = _monitor(explorer_url="https://example.invalid/?json", explorer=explorer, clock=clock)
    for i in range(61):
        v = asyncio.run(mon.check({**SYNCED, "current": 1 + i}, 4))
        clock.t += MIN
    assert len(calls) == 2  # t=0 and t=60 min
    assert v["explorer_tip"] is None and v["level"] == "green"


def test_explorer_tip_parses_the_text_explorer_json(monkeypatch):
    class Resp:
        def json(self):
            return {"tipInfo": {"metadata": {"best_block_height": 350958}}}

    seen = {}

    def fake_get(url, **kw):
        seen.update(kw, url=url)
        return Resp()

    monkeypatch.setattr(th, "bounded_get", fake_get)
    assert th._explorer_tip("https://textexplore.tari.com/?json") == 350958
    assert seen["proxies"]["https"] == th.TOR_SOCKS_PROXY  # never a clearnet call


@pytest.mark.parametrize("body", [{}, {"tipInfo": None}, "not json"])
def test_explorer_tip_is_none_on_a_bad_body(monkeypatch, body):
    class Resp:
        def json(self):
            if isinstance(body, str):
                raise ValueError(body)
            return body

    monkeypatch.setattr(th, "bounded_get", lambda url, **kw: Resp())
    assert th._explorer_tip("u") is None


def test_explorer_failure_logs_no_url(monkeypatch, caplog):
    secret = "https://user:hunter2@example.invalid/tok-abc123/?json"

    def boom(url, **kw):
        raise ValueError(f"failed to fetch {url}")

    monkeypatch.setattr(th, "bounded_get", boom)
    with caplog.at_level("INFO"):
        assert th._explorer_tip(secret) is None
    assert "hunter2" not in caplog.text and "tok-abc123" not in caplog.text
    assert "ValueError" in caplog.text


# --- forward progress only; each entry into red alerts (#2464 review round 3) -------------------


def test_a_falling_height_is_not_progress_and_does_not_reset_the_stall():
    mon = _monitor()
    mon.observe({**SYNCED, "current": 500}, 0, 0)
    mon.observe({**SYNCED, "current": 490}, 0, 10 * MIN)  # a rewind or reset
    mon.observe({**SYNCED, "current": 500}, 0, 20 * MIN)  # back to, not past, the best
    assert mon._height_since == 0
    v = mon.observe({**SYNCED, "current": 500}, 0, 30 * MIN)
    assert v["level"] == "red" and v["reasons"][0] == "tip 500 unchanged for 30 min"
    v = mon.observe({**SYNCED, "current": 495}, 0, 31 * MIN)
    assert v["reasons"][0] == "tip 495 has not passed 500 for 31 min"
    mon.observe({**SYNCED, "current": 501}, 5, 32 * MIN)
    assert mon._height_since == 32 * MIN


def test_red_amber_red_with_the_same_advice_alerts_on_each_entry_into_red():
    clock, notify = Clock(), AsyncMock()
    mon = _monitor(notify=notify, clock=clock)
    for _ in range(31):  # stale tip + 0 peers: red
        asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    assert notify.await_count == 1
    asyncio.run(mon.check(SYNCED, 4))  # peers back: tip still stale, amber, same advice
    assert mon.verdict["level"] == "amber"
    for _ in range(11):  # peers gone again for 10 min: red again
        clock.t += MIN
        asyncio.run(mon.check(SYNCED, 0))
    assert mon.verdict["level"] == "red"
    assert notify.await_count == 2
    assert all("not following the chain" in c.args[0] for c in notify.await_args_list)


# --- missing peer readings; alert delivery (#2464 review round 11) -----------------------------


def test_missing_peer_readings_restart_the_zero_peer_clock():
    """One zero sample, then ten cycles without a peer count while the tip advances, is no
    evidence of ten minutes at zero peers."""
    mon = _monitor()
    mon.observe({**SYNCED, "current": 100}, 0, 0)
    for i in range(1, 11):
        v = mon.observe({**SYNCED, "current": 100 + i}, None, i * MIN)
    assert v["level"] == "green" and v["reasons"] == []
    v = mon.observe({**SYNCED, "current": 111}, 0, 11 * MIN)  # zero again: the clock starts now
    assert v["level"] == "green"
    assert mon.observe({**SYNCED, "current": 112}, 0, 21 * MIN)["reasons"] == [
        "0 peer connections for 10 min"
    ]


def test_an_unreachable_cycle_restarts_the_zero_peer_clock():
    mon = _monitor()
    mon.observe(SYNCED, 0, 0)
    mon.observe({"reachable": False}, None, 5 * MIN)
    assert mon.observe(SYNCED, 0, 10 * MIN)["level"] == "green"


def test_a_failed_red_alert_is_retried_while_red_and_counts_once_delivered():
    clock, notify = (
        Clock(),
        AsyncMock(side_effect=[OSError("sink down"), OSError("sink down"), "sent"]),
    )
    mon = _monitor(notify=notify, clock=clock)
    for _ in range(40):
        asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    assert notify.await_count == 3  # two failures retried on the next cycles, then delivered once
    assert "not following the chain" in notify.await_args_list[-1].args[0]
    asyncio.run(mon.check({**SYNCED, "current": 342575}, 5))
    assert notify.await_args_list[-1].args[0].startswith("\U0001f7e2")


def test_no_recovery_note_without_a_delivered_red_alert():
    clock = Clock()
    notify = AsyncMock(side_effect=OSError("sink down"))
    mon = _monitor(notify=notify, clock=clock)
    for _ in range(35):
        asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    failed = notify.await_count
    notify.side_effect = None
    asyncio.run(mon.check({**SYNCED, "current": 342575}, 5))  # green before any red got through
    assert notify.await_count == failed  # nothing to recover from: no note


def test_the_verdict_carries_this_cycles_peer_reading():
    """The stranded leg measures amber from the node's first zero-peer report, so it is served."""
    mon = _monitor()
    assert mon.observe(SYNCED, 0, 0)["connections"] == 0
    assert mon.observe(SYNCED, None, MIN)["connections"] is None
    assert mon.observe({"reachable": False}, None, 2 * MIN)["connections"] is None
