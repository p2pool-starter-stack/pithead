"""Tor self-heal restart must end with Tor running even when the stop call fails (#3032)."""

from unittest.mock import AsyncMock, patch

from mining_dashboard.service.health.tor_heal import (
    COOLDOWN_SEC,
    MAX_ATTEMPTS,
    TorEgressHealer,
)
from tests.service.health.test_tor_heal import _Clock, _FakeDocker


class _FlakyDocker(_FakeDocker):
    """Stop times out (False); the first `fail_starts` starts are unconfirmed too."""

    def __init__(self, fail_starts=0):
        super().__init__()
        self.fail_starts = fail_starts
        self.kwargs = {}

    async def stop(self, container, **kwargs):
        self.kwargs["stop"] = kwargs
        await super().stop(container, **kwargs)
        return False

    async def start(self, container, **kwargs):
        await super().start(container, **kwargs)
        if self.fail_starts > 0:
            self.fail_starts -= 1
            return False
        return True


async def _heal_to_restart(docker, health):
    clock = _Clock()
    h = TorEgressHealer(
        docker,
        enabled=True,
        probe=lambda: (False, "test probe"),
        clock=clock,
        restart_monerod=False,
    )
    with (
        patch("mining_dashboard.service.health.tor_heal.TOR_START_RETRY_DELAY_SEC", 0),
        patch("mining_dashboard.service.health.tor_heal.asyncio.sleep", AsyncMock()),
        patch("mining_dashboard.service.health.tor_heal.get_container_health", health),
        patch("mining_dashboard.service.health.tor_heal.control_service.submit", return_value="i"),
        patch(
            "mining_dashboard.service.health.tor_heal.control_service.result",
            return_value={"status": "applied"},
        ),
    ):
        await h.check()
        for _ in range(MAX_ATTEMPTS):
            clock.t += COOLDOWN_SEC
            await h.check()
    return h


class TestTorRestartEndsRunning:
    async def test_stop_timeout_still_starts_tor_with_long_stop_budget(self):
        docker = _FlakyDocker()
        await _heal_to_restart(docker, AsyncMock(return_value={}))
        assert docker.calls == [("stop", "tor"), ("start", "tor")]
        # HTTP timeout must outlast the grace period plus the kill time (#3032).
        kw = docker.kwargs["stop"]
        assert kw["stop_timeout"] == 15
        assert kw["request_timeout"] == 120  # 15 s grace + SIGKILL + a wedged daemon's slack

    async def test_unconfirmed_start_is_retried_until_it_lands(self):
        docker = _FlakyDocker(fail_starts=2)
        h = await _heal_to_restart(docker, AsyncMock(return_value={}))
        assert [c for c in docker.calls if c[0] == "start"] == [("start", "tor")] * 3
        assert h._recovery_step == "Tor start (stop unconfirmed)"

    async def test_a_running_inspect_does_not_stand_in_for_a_confirmed_start(self):
        # After a timed-out stop the container may still read "running" while the stop is in flight.
        docker = _FlakyDocker(fail_starts=5)
        h = await _heal_to_restart(docker, AsyncMock(return_value={"tor": {"running": True}}))
        assert len([c for c in docker.calls if c[0] == "start"]) == 3
        assert h._recovery_step == "Tor restart unconfirmed"

    async def test_start_retries_are_bounded(self):
        docker = _FlakyDocker(fail_starts=99)
        h = await _heal_to_restart(docker, AsyncMock(return_value={}))
        assert len([c for c in docker.calls if c[0] == "start"]) == 3
        assert h._recovery_step == "Tor restart unconfirmed"


class _AnswersAlreadyRunning(_FlakyDocker):
    """A start while the stop is in flight gets 304 (True) and is then undone by that stop."""

    def __init__(self, tor_state):
        super().__init__()
        self.tor_state = tor_state  # list of polled "running" values, popped per inspect
        self.polls_at_start = None

    async def start(self, container, **kwargs):
        self.polls_at_start = len(self.tor_state)
        return await _FakeDocker.start(self, container, **kwargs)


async def test_start_waits_for_an_in_flight_stop_to_finish():
    states = [True, True, False]
    docker = _AnswersAlreadyRunning(states)

    async def health():
        return {"tor": {"running": states.pop(0) if states else False}}

    await _heal_to_restart(docker, health)
    assert docker.polls_at_start == 0  # all three inspects happened before the one start
    assert docker.calls == [("stop", "tor"), ("start", "tor")]


async def test_settle_wait_is_bounded_when_tor_never_reads_down():
    docker = _FlakyDocker()
    health = AsyncMock(return_value={"tor": {"running": True}})
    await _heal_to_restart(docker, health)
    assert docker.calls == [("stop", "tor"), ("start", "tor")]
    # One start-time read per check (4), then TOR_SETTLE_SEC // TOR_SETTLE_POLL_SEC polls, then start.
    assert health.await_count == 4 + 6


async def test_confirmed_stop_starts_without_waiting():
    docker = _FakeDocker()
    health = AsyncMock(return_value={"tor": {"running": True}})
    await _heal_to_restart(docker, health)
    assert docker.calls == [("stop", "tor"), ("start", "tor")]
    assert health.await_count == 4  # only the per-check start-time reads; no settle polls
