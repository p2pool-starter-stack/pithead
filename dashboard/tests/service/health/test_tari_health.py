"""Tari chain health (#2464): the stale-tip / zero-peer / explorer-lag verdict and its guarded restart.

The production incident, replayed on a fake clock: a reachable node, gRPC answering, its tip frozen and
every peer banned. Each signal alone is amber, two are red, explorer lag alone is red, and the restart
guards (sustain, cooldown, budget, migration) hold exactly as documented.
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
    kw.setdefault("auto_restart", True)
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


def test_unreachable_cycles_feed_nothing_and_do_not_reset_the_stall():
    mon = _monitor()
    mon.observe(SYNCED, 0, 0)
    for t in range(1, 30):
        mon.observe({"reachable": False}, None, t * MIN)
    v = mon.observe(SYNCED, 0, 30 * MIN)
    assert v["level"] == "red"


def test_a_missing_peer_count_is_not_a_zero():
    v = _run(_monitor(), 30, connections=None)
    assert v["reasons"] == ["tip 342574 unchanged for 30 min"] and v["level"] == "amber"


def test_recovery_to_green_after_catch_up():
    mon = _monitor()
    assert _run(mon, 30)["level"] == "red"
    v = mon.observe({**SYNCED, "current": 342575}, 6, 31 * MIN)
    assert v["level"] == "green"


# --- restart decision --------------------------------------------------------------------------


def _red(mon, now):
    mon.verdict = {"level": "red", "reasons": ["x", "y"], "advice": th.RESTART_ADVICE}
    return mon.decide(True, now)


def test_restart_waits_for_sustained_red_then_honours_cooldown_and_budget():
    mon = _monitor()
    assert _red(mon, 0) is None
    assert _red(mon, th.RED_SUSTAIN_SEC - 1) is None
    assert _red(mon, th.RED_SUSTAIN_SEC) == "restart"
    t = th.RED_SUSTAIN_SEC
    assert _red(mon, t + th.COOLDOWN_SEC - 1) is None
    assert _red(mon, t + th.COOLDOWN_SEC) == "restart"
    assert _red(mon, t + 2 * th.COOLDOWN_SEC) == "restart"
    assert _red(mon, t + 3 * th.COOLDOWN_SEC) == "exhausted"
    assert mon._restarts == th.MAX_RESTARTS


def test_amber_never_restarts():
    mon = _monitor()
    mon.verdict = {"level": "amber", "reasons": ["x"], "advice": th.RESTART_ADVICE}
    assert mon.decide(True, 0) is None and mon.decide(True, 10 * th.COOLDOWN_SEC) is None


def test_restart_is_withheld_while_grpc_is_not_answering():
    """minotari_node opens gRPC only after its migrations; a restart mid-migration is unsafe (#2593)."""
    mon = _monitor()
    _red(mon, 0)
    mon.verdict = {"level": "red", "reasons": ["x"], "advice": ""}
    assert mon.decide(False, th.RED_SUSTAIN_SEC) == "withheld"
    assert mon._restarts == 0


def test_disabled_or_remote_never_restarts():
    mon = _monitor(auto_restart=False)
    _red(mon, 0)
    assert _red(mon, 10 * th.COOLDOWN_SEC) is None


def test_budget_refills_only_after_sustained_green():
    mon = _monitor()
    _red(mon, 0)
    assert _red(mon, th.RED_SUSTAIN_SEC) == "restart"
    mon.verdict = {"level": "green", "reasons": [], "advice": ""}
    assert mon.decide(True, 1000) is None
    assert mon.decide(True, 1000 + th.GREEN_CONFIRM_SEC - 1) is None
    assert mon._restarts == 1  # a brief green does not refill
    assert mon.decide(True, 1000 + th.GREEN_CONFIRM_SEC) == "recovered"
    assert mon._restarts == 0


# --- check(): I/O, alerts, escalation ----------------------------------------------------------


def _docker(ok=True):
    d = AsyncMock()
    d.stop.return_value = ok
    d.start.return_value = ok
    return d


def test_check_restarts_the_tari_container_and_alerts_on_red():
    clock, docker, notify = Clock(), _docker(), AsyncMock()
    mon = _monitor(docker_control=docker, notify=notify, clock=clock)
    for _ in range(36):
        v = asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    assert v["level"] == "red"
    docker.stop.assert_awaited_once()
    assert docker.stop.await_args.args[0] == "tari"
    docker.start.assert_awaited_once_with("tari", request_timeout=60)
    text = notify.await_args_list[0].args[0]
    assert "Tari node is not following the chain" in text and "restart the Tari node" in text
    assert notify.await_count == 1  # red is alerted once, not every cycle


def test_failed_restart_refunds_the_budget():
    clock = Clock()
    mon = _monitor(docker_control=_docker(ok=False), clock=clock)
    for _ in range(36):
        v = asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    assert v["restarts"] == 0


def test_escalates_after_the_third_restart_without_green():
    clock, notify = Clock(), AsyncMock()
    mon = _monitor(docker_control=_docker(), notify=notify, clock=clock)
    for _ in range(36 + 3 * 60):
        v = asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    assert v["restarts"] == th.MAX_RESTARTS
    assert "a restart cannot fix this" in v["advice"]
    assert "a restart cannot fix this" in notify.await_args_list[-1].args[0]


def test_recovery_note_after_a_red_alert():
    clock, notify = Clock(), AsyncMock()
    mon = _monitor(docker_control=_docker(), notify=notify, clock=clock)
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
