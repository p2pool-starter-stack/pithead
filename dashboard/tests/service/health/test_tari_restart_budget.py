"""Tari restart budget (#2464 review round 7): one hour between restarts and three per outage hold
when a stop's acknowledgement is lost and when the dashboard's monitor is recreated mid-outage.
Only sustained green refills the budget."""

import asyncio
import time
from unittest.mock import AsyncMock

from mining_dashboard.service.health import tari_health as th
from tests.service.health.test_tari_health import MIN, SYNCED, Clock, _monitor


class Tari:
    """A tari container on the host clock. Its stops land; ``ack`` says whether Docker says so."""

    def __init__(self, clock, ack=True):
        self.clock, self.ack = clock, ack
        self.running, self.started_at = True, time.time() - 3600
        self.stops = []  # monitor-clock times at which a stop landed
        self.docker = AsyncMock()
        self.docker.stop.side_effect = self._stop
        self.docker.start.side_effect = self._start

    async def _stop(self, name, **kw):
        self.running = False
        self.stops.append(self.clock.t)
        return self.ack

    async def _start(self, name, **kw):
        if not self.running:
            self.running, self.started_at = True, time.time() + 0.001
        return True

    async def inspect(self, name):
        return self.running, self.started_at


def _monitor_for(tari, state_dir):
    return _monitor(
        docker_control=tari.docker, clock=tari.clock, state_dir=state_dir, inspect=tari.inspect
    )


def _red(mon, tari, minutes):
    """A stale tip with no peers, polled once a minute; a stopped node does not answer."""
    for _ in range(minutes):
        asyncio.run(mon.check(SYNCED if tari.running else {"reachable": False}, 0))
        tari.clock.t += MIN


def _gaps(stops):
    return [b - a for a, b in zip(stops, stops[1:], strict=False)]


def test_lost_stop_acknowledgements_cannot_bypass_the_cooldown_or_the_cap(tmp_path):
    """Every stop lands but reports failure. Refunding on the report let the owed start bring the
    node back and the next cycle stop it again: six real restarts in 46 minutes."""
    tari = Tari(Clock(), ack=False)
    mon = _monitor_for(tari, str(tmp_path))
    _red(mon, tari, 5 * 60)
    assert [gap for gap in _gaps(tari.stops) if gap < th.COOLDOWN_SEC] == []
    assert len(tari.stops) == th.MAX_RESTARTS
    assert tari.running and tari.docker.start.await_count == th.MAX_RESTARTS  # each one completed
    assert mon.verdict["restarts"] == th.MAX_RESTARTS
    assert mon.verdict["advice"] == th.ESCALATED_ADVICE


def test_recreating_the_monitor_cannot_grant_a_fourth_restart_in_the_same_outage(tmp_path):
    tari = Tari(Clock())
    _red(_monitor_for(tari, str(tmp_path)), tari, 3 * 60)
    assert len(tari.stops) == th.MAX_RESTARTS
    tari.clock = Clock()  # a new dashboard: fresh clock, fresh history, the same outage
    mon = _monitor_for(tari, str(tmp_path))
    _red(mon, tari, 3 * 60)
    assert len(tari.stops) == th.MAX_RESTARTS
    assert mon.verdict["restarts"] == th.MAX_RESTARTS
    assert mon.verdict["advice"] == th.ESCALATED_ADVICE


def test_recreating_the_monitor_keeps_the_cooldown(tmp_path):
    tari = Tari(Clock())
    _red(_monitor_for(tari, str(tmp_path)), tari, 40)
    assert len(tari.stops) == 1
    tari.clock = Clock()
    mon = _monitor_for(tari, str(tmp_path))
    _red(mon, tari, 50)  # red again for 5 min would have restarted it, an hour had not passed
    assert len(tari.stops) == 1
    _red(mon, tari, 15)
    assert len(tari.stops) == 2 and mon.verdict["restarts"] == 2


def test_only_sustained_green_refills_the_budget_across_a_recreation(tmp_path):
    tari = Tari(Clock())
    mon = _monitor_for(tari, str(tmp_path))
    _red(mon, tari, 3 * 60)
    height = SYNCED["current"]
    for _ in range(th.GREEN_CONFIRM_SEC // MIN + 1):
        height += 1
        asyncio.run(mon.check({**SYNCED, "current": height}, 8))
        tari.clock.t += MIN
    assert mon.verdict["restarts"] == 0
    tari.clock = Clock()
    mon = _monitor_for(tari, str(tmp_path))
    _red(mon, tari, 40)
    assert len(tari.stops) == th.MAX_RESTARTS + 1  # a new outage, a full budget


def test_an_unreadable_budget_reads_as_spent(tmp_path):
    (tmp_path / th.BUDGET).write_text("{not json")
    tari = Tari(Clock())
    mon = _monitor_for(tari, str(tmp_path))
    _red(mon, tari, 2 * 60)
    assert tari.stops == [] and mon.verdict["advice"] == th.ESCALATED_ADVICE


def test_a_budget_that_cannot_be_recorded_stops_nothing(tmp_path):
    tari = Tari(Clock())
    mon = _monitor_for(tari, str(tmp_path / "missing"))
    _red(mon, tari, 60)
    assert tari.stops == [] and mon.verdict["action"] == "restart_unrecorded"
    assert mon.verdict["restarts"] == 0
