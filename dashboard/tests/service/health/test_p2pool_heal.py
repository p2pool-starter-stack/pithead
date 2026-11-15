import itertools
import logging
from unittest.mock import AsyncMock, patch

import pytest

from mining_dashboard.service.health.p2pool_heal import (
    DAY_SEC,
    MAX_REJOIN_WAIT_SEC,
    MAX_RESTARTS_PER_DAY,
    P2POOL_LATE_START_CYCLES,
    REJOIN_WAIT_SEC,
    STATS_STALE_SEC,
    ZERO_PEERS_AFTER_SEC,
    P2PoolPeerHealer,
)
from tests.service.health.test_tor_heal import _Clock, _FakeDocker

HEALTH = "mining_dashboard.service.health.p2pool_heal.get_container_health"


_UPTIME = itertools.count(1)


def _stats(peers=0, height=100, uptime=None):
    uptime = next(_UPTIME) if uptime is None else uptime
    return {
        "p2p": {"out_peers": peers, "in_peers": 0, "uptime": uptime},
        "pool": {"sidechain_height": height},
    }


@pytest.fixture(autouse=True)
def _p2pool_running():
    with (
        patch(HEALTH, AsyncMock(return_value={"p2pool": {"running": True}})) as health,
        patch("mining_dashboard.service.health.p2pool_heal.asyncio.sleep", AsyncMock()),
    ):
        yield health


def _healer(docker=None, audit=None):
    clock = _Clock()
    return P2PoolPeerHealer(docker or _FakeDocker(), audit=audit, clock=clock), clock


async def _peerless_for(healer, clock, seconds, step=60):
    end = clock.t + seconds
    while clock.t < end:
        await healer.check(_stats())
        clock.t += step
    await healer.check(_stats())


class TestPeerlessWindow:
    async def test_peerless_window_restarts_p2pool_and_audits(self, caplog):
        docker = _FakeDocker()
        audit = AsyncMock()
        healer, clock = _healer(docker, audit)
        with caplog.at_level(logging.WARNING, logger="P2PoolHeal"):
            await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        assert docker.calls == [("stop", "p2pool"), ("start", "p2pool")]
        audit.assert_awaited_once_with("restart", "applied", "p2pool")
        assert "has had no peers for" in caplog.text

    async def test_a_peerless_blip_never_restarts(self):
        docker = _FakeDocker()
        healer, clock = _healer(docker)
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC - 120)
        await healer.check(_stats(peers=3))
        clock.t += 600
        await healer.check(_stats())
        assert docker.calls == []

    async def test_an_unread_stats_file_is_not_a_zero_peer_reading(self):
        docker = _FakeDocker()
        healer, clock = _healer(docker)
        for _ in range(ZERO_PEERS_AFTER_SEC // 60 + 5):
            await healer.check(_stats(uptime=0))
            clock.t += 60
        assert docker.calls == []

    async def test_an_absent_or_stopped_p2pool_is_never_touched(self, _p2pool_running):
        docker = _FakeDocker()
        healer, clock = _healer(docker)
        for health in ({}, {"p2pool": {"running": False}}, {"p2pool": {"restarting": True}}):
            _p2pool_running.return_value = health
            await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        assert docker.calls == []

    async def test_a_failed_start_is_retried_and_the_attempt_is_kept(self):
        class _Down(_FakeDocker):
            async def start(self, container, **kwargs):
                await super().start(container, **kwargs)
                return False

        docker = _Down()
        audit = AsyncMock()
        healer, clock = _healer(docker, audit)
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        assert [c for c in docker.calls if c[0] == "start"] == [("start", "p2pool")] * 3
        audit.assert_awaited_once_with("restart", "unconfirmed", "p2pool")


class TestBackoffAndCap:
    async def test_still_peerless_waits_for_the_rejoin_window_then_restarts_again(self):
        docker = _FakeDocker()
        healer, clock = _healer(docker)
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        assert len(docker.calls) == 2
        await _peerless_for(healer, clock, REJOIN_WAIT_SEC - 2 * 60)
        assert len(docker.calls) == 2
        await _peerless_for(healer, clock, 3 * 60)
        assert len(docker.calls) == 4

    async def test_backoff_doubles_and_is_bounded(self):
        healer, clock = _healer()
        waits = []
        for _ in range(MAX_RESTARTS_PER_DAY):
            await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
            waits.append(healer._next_allowed - healer._restarts[-1])
            clock.t = healer._next_allowed
        assert waits == [REJOIN_WAIT_SEC, 2 * REJOIN_WAIT_SEC, MAX_REJOIN_WAIT_SEC]

    async def test_cap_stops_restarting_and_says_so_once(self, caplog):
        docker = _FakeDocker()
        healer, clock = _healer(docker)
        with caplog.at_level(logging.WARNING, logger="P2PoolHeal"):
            for _ in range(MAX_RESTARTS_PER_DAY + 2):
                await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC + MAX_REJOIN_WAIT_SEC)
        assert [c for c in docker.calls if c[0] == "stop"] == [("stop", "p2pool")] * (
            MAX_RESTARTS_PER_DAY
        )
        assert caplog.text.count("No more automatic action") == 1

    async def test_the_daily_cap_refills_after_a_day(self):
        docker = _FakeDocker()
        healer, clock = _healer(docker)
        for _ in range(MAX_RESTARTS_PER_DAY):
            await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC + MAX_REJOIN_WAIT_SEC)
        stops = len([c for c in docker.calls if c[0] == "stop"])
        clock.t += DAY_SEC
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        assert len([c for c in docker.calls if c[0] == "stop"]) == stops + 1


class TestRecovery:
    async def test_peers_alone_do_not_end_the_outage_until_the_tip_moves(self, caplog):
        healer, clock = _healer()
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        with caplog.at_level(logging.INFO, logger="P2PoolHeal"):
            await healer.check(_stats(peers=4, height=1))
            await healer.check(_stats(peers=4, height=1))
            assert healer._awaiting_tip
            assert "rejoined" not in caplog.text
            await healer.check(_stats(peers=4, height=7))
        assert not healer._awaiting_tip
        assert "rejoined the sidechain" in caplog.text
        assert healer._outage_restarts == 0

    async def test_recovery_resets_backoff_so_the_next_outage_starts_fresh(self):
        docker = _FakeDocker()
        healer, clock = _healer(docker)
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        await healer.check(_stats(peers=4, height=1))
        await healer.check(_stats(peers=4, height=2))
        clock.t += 5 * 60
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        assert [c for c in docker.calls if c[0] == "stop"] == [("stop", "p2pool")] * 2

    async def test_a_peerless_dip_after_restart_restarts_the_tip_baseline(self):
        healer, clock = _healer()
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        await healer.check(_stats(peers=4, height=50))
        await healer.check(_stats(peers=0, height=50))
        await healer.check(_stats(peers=4, height=10))
        assert healer._awaiting_tip


class TestGuards:
    async def test_a_stats_file_that_stopped_updating_is_not_a_zero_peer_reading(self):
        docker = _FakeDocker()
        healer, clock = _healer(docker)
        for _ in range((ZERO_PEERS_AFTER_SEC + 2 * STATS_STALE_SEC) // 60):
            await healer.check(_stats(uptime=500))
            clock.t += 60
        assert docker.calls == []

    async def test_a_zero_height_is_not_a_tip_baseline(self):
        healer, clock = _healer()
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        await healer.check(_stats(peers=4, height=0))
        await healer.check(_stats(peers=4, height=9))
        assert healer._awaiting_tip
        await healer.check(_stats(peers=4, height=12))
        assert not healer._awaiting_tip

    async def test_the_cap_warning_is_given_again_after_the_daily_cap_refills(self, caplog):
        healer, clock = _healer()
        with caplog.at_level(logging.WARNING, logger="P2PoolHeal"):
            for _ in range(MAX_RESTARTS_PER_DAY + 1):
                await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC + MAX_REJOIN_WAIT_SEC)
            clock.t += DAY_SEC
            for _ in range(MAX_RESTARTS_PER_DAY + 1):
                await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC + MAX_REJOIN_WAIT_SEC)
        assert caplog.text.count("No more automatic action") == 2

    async def test_a_restart_whose_start_was_unconfirmed_is_started_on_a_later_cycle(
        self, _p2pool_running
    ):
        class _SlowStart(_FakeDocker):
            def __init__(self):
                super().__init__()
                self.refuse = True

            async def start(self, container, **kwargs):
                await super().start(container, **kwargs)
                return not self.refuse

        docker = _SlowStart()
        healer, clock = _healer(docker)
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        calls = len(docker.calls)
        docker.refuse = False
        _p2pool_running.return_value = {"p2pool": {"running": False}}
        await healer.check(_stats())
        assert docker.calls[calls:] == [("start", "p2pool")]
        await healer.check(_stats())
        assert len(docker.calls) == calls + 1

    async def test_late_start_attempts_are_bounded(self, _p2pool_running):
        class _Refuse(_FakeDocker):
            async def start(self, container, **kwargs):
                await super().start(container, **kwargs)
                return False

        docker = _Refuse()
        healer, clock = _healer(docker)
        await _peerless_for(healer, clock, ZERO_PEERS_AFTER_SEC)
        calls = len(docker.calls)
        _p2pool_running.return_value = {"p2pool": {"running": False}}
        for _ in range(P2POOL_LATE_START_CYCLES + 3):
            await healer.check(_stats())
        assert len(docker.calls) == calls + P2POOL_LATE_START_CYCLES
