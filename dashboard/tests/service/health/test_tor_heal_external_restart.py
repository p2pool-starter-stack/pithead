"""A Tor restart the healer did not perform opens a fresh outage window."""

from unittest.mock import AsyncMock, patch

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    MAX_ATTEMPTS,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)

TARGET = "mining_dashboard.service.health.tor_heal"


class _Clock:
    t = 1000.0

    def __call__(self):
        return self.t


class _Docker:
    def __init__(self):
        self.calls = []

    async def stop(self, container, **kwargs):
        self.calls.append(("stop", container))
        return True

    async def start(self, container, **kwargs):
        self.calls.append(("start", container))
        return True


class _Rig:
    """A healer whose probe result and Tor start time the test sets."""

    def __init__(self):
        self.clock = _Clock()
        self.docker = _Docker()
        self.ok = False
        self.tor_started = 5000.0
        self.healer = TorEgressHealer(
            self.docker,
            enabled=True,
            probe=lambda: (self.ok, "test probe"),
            clock=self.clock,
            restart_monerod=False,
        )

    async def step(self, ok, seconds=PROBE_INTERVAL_SEC):
        self.clock.t += seconds
        self.ok = ok
        health = {"tor": {"running": True, "started_at": self.tor_started}}
        with (
            patch(f"{TARGET}.get_container_health", AsyncMock(return_value=health)),
            patch(f"{TARGET}.control_service.submit", return_value="i"),
            patch(
                f"{TARGET}.control_service.result",
                return_value={"status": "applied"},
            ),
            patch(f"{TARGET}.asyncio.sleep", AsyncMock()),
        ):
            await self.healer.check()

    async def spend_newnyms(self):
        await self.step(False)  # observes Tor and starts the outage clock
        await self.step(False, BROKEN_AFTER_SEC)
        await self.step(False)  # confirms NEWNYM 1
        await self.step(False, COOLDOWN_SEC)
        await self.step(False)  # confirms NEWNYM 2
        assert self.healer._attempts == MAX_ATTEMPTS - 1


async def test_external_restart_resets_clock_budget_and_cooldown():
    rig = await _Rig.spend_and_return()
    h = rig.healer
    rig.tor_started += 3600
    await rig.step(True)
    assert (h._failing_since, h._attempts, h._last_attempt) == (None, 0, None)
    await rig.step(False)
    assert h._failing_since is not None
    assert rig.docker.calls == []
    assert h._attempts == 0


async def test_failed_probe_after_external_restart_waits_for_fresh_threshold():
    rig = await _Rig.spend_and_return()
    rig.tor_started += 3600
    await rig.step(True)
    await rig.step(False)
    await rig.step(False, BROKEN_AFTER_SEC - PROBE_INTERVAL_SEC - 1)
    assert rig.docker.calls == []
    assert rig.healer._attempts == 0


async def test_healer_restart_keeps_counting():
    rig = _Rig()
    await rig.spend_newnyms()
    await rig.step(False, COOLDOWN_SEC)  # third attempt: the healer's own Tor restart
    assert ("stop", "tor") in rig.docker.calls
    rig.tor_started += 3600  # the start time its own restart produced
    await rig.step(False)
    assert rig.healer._attempts == MAX_ATTEMPTS
    assert rig.healer._failing_since is not None


async def _spend_and_return():
    rig = _Rig()
    await rig.spend_newnyms()
    return rig


_Rig.spend_and_return = staticmethod(_spend_and_return)
