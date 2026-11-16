from unittest.mock import AsyncMock, patch

from mining_dashboard.service.health.tor_heal import (
    FAST_PROBE_SEC,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)

TARGET = "mining_dashboard.service.health.tor_heal"


class _Clock:
    t = 1000.0

    def __call__(self):
        return self.t


def _healer(clock):
    return TorEgressHealer(
        docker_control=None,
        enabled=True,
        probe=lambda: (False, "test probe"),
        clock=clock,
        restart_monerod=False,
    )


class TestFirstAction:
    def test_first_nondisruptive_action_comes_within_five_minutes(self):
        clock = _Clock()
        h = _healer(clock)
        h.decide(False, clock.t)
        clock.t += PROBE_INTERVAL_SEC
        assert h.decide(False, clock.t) == "heal"
        assert h._attempts == 1

    def test_a_ping_failing_for_five_minutes_counts_toward_the_first_action(self):
        clock = _Clock()
        ping_since = [clock.t - 4 * 60]
        h = TorEgressHealer(
            docker_control=None,
            enabled=True,
            probe=lambda: (False, "test probe"),
            clock=clock,
            restart_monerod=False,
            ping_failing_since=lambda: ping_since[0],
        )
        assert h.decide(False, clock.t) is None
        clock.t += 60
        assert h.decide(False, clock.t) == "heal"

    def test_no_ping_failure_leaves_the_probe_streak_alone(self):
        clock = _Clock()
        h = TorEgressHealer(
            docker_control=None,
            enabled=True,
            probe=lambda: (False, "test probe"),
            clock=clock,
            restart_monerod=False,
            ping_failing_since=lambda: None,
        )
        h.decide(False, clock.t)
        clock.t += 60
        assert h.decide(False, clock.t) is None


class TestProbeCadenceThroughCheck:
    async def _check(self, healer, clock, seconds):
        clock.t += seconds
        health = {"tor": {"running": True, "started_at": 5000.0}}
        with (
            patch(f"{TARGET}.get_container_health", AsyncMock(return_value=health)),
            patch(f"{TARGET}.control_service.submit", side_effect=lambda action, **kw: action),
            patch(f"{TARGET}.control_service.result", return_value={"status": "applied"}),
            patch("mining_dashboard.service.request_spool.write", lambda req: req["action"]),
        ):
            await healer.check()

    def _healer(self, clock, ping_since):
        return TorEgressHealer(
            docker_control=None,
            enabled=True,
            probe=lambda: (False, "test probe"),
            clock=clock,
            restart_monerod=False,
            ping_failing_since=lambda: ping_since[0],
        )

    async def test_failing_pings_speed_the_probe_and_the_first_newnym_lands_in_five_minutes(self):
        clock = _Clock()
        ping_since = [None]
        h = self._healer(clock, ping_since)
        h._probe = lambda: (True, "ok")
        await self._check(h, clock, 0)
        h._probe = lambda: (False, "test probe")
        ping_since[0] = clock.t + 10
        for _ in range(6):
            await self._check(h, clock, FAST_PROBE_SEC)
        assert h._attempts == 1
        assert h._pending_refresh == "tor-newnym"
        assert clock.t - 1000.0 <= 6 * 60 + 1

    async def test_a_fresh_ping_failure_starts_a_probe_without_waiting_for_the_cadence(self):
        clock = _Clock()
        ping_since = [None]
        h = self._healer(clock, ping_since)
        h._probe = lambda: (True, "ok")
        await self._check(h, clock, 0)
        assert h._last_probe == 1000.0
        ping_since[0] = clock.t + 10
        await self._check(h, clock, 20)
        assert h._last_probe == 1020.0

    async def test_healthy_pings_keep_the_five_minute_probe_cadence(self):
        clock = _Clock()
        h = self._healer(clock, [None])
        await self._check(h, clock, 0)
        await self._check(h, clock, FAST_PROBE_SEC)
        assert h._last_probe == 1000.0

    async def test_a_ping_failure_with_healthy_probes_never_acts(self):
        clock = _Clock()
        h = self._healer(clock, [clock.t])
        h._probe = lambda: (True, "ok")
        for _ in range(10):
            await self._check(h, clock, FAST_PROBE_SEC)
        assert h._attempts == 0
