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
        self.saturated = False
        self.recover_result = {"status": "applied"}
        self.healer = TorEgressHealer(
            self.docker,
            enabled=True,
            probe=lambda: (self.ok, "test probe"),
            clock=self.clock,
            restart_monerod=False,
        )

    def _result(self, request_id):
        if request_id == "tor-history":
            return {"status": "applied", "saturated": self.saturated}
        if request_id == "tor-recover":
            return self.recover_result
        return {"status": "applied"}

    async def step(self, ok, seconds=PROBE_INTERVAL_SEC):
        self.clock.t += seconds
        self.ok = ok
        health = {"tor": {"running": True, "started_at": self.tor_started}}
        with (
            patch(f"{TARGET}.get_container_health", AsyncMock(return_value=health)),
            patch(f"{TARGET}.control_service.submit", side_effect=lambda action, **kw: action),
            patch("mining_dashboard.service.request_spool.write", lambda req: req["action"]),
            patch(f"{TARGET}.control_service.result", side_effect=self._result),
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


async def _spend_and_return():
    rig = _Rig()
    await rig.spend_newnyms()
    return rig


async def test_external_restart_resets_clock_budget_and_cooldown():
    rig = await _spend_and_return()
    h = rig.healer
    rig.tor_started += 3600
    await rig.step(True)
    assert (h._failing_since, h._attempts, h._last_attempt) == (None, 0, None)
    await rig.step(False)
    assert h._failing_since is not None
    assert rig.docker.calls == []
    assert h._attempts == 0


async def test_failed_probe_after_external_restart_waits_for_fresh_threshold():
    rig = await _spend_and_return()
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


async def _recover_submitted(recover_result):
    """Saturated history: both NEWNYMs spent, then the final step submits tor-recover."""
    rig = _Rig()
    rig.saturated = True
    rig.recover_result = recover_result
    await rig.spend_newnyms()
    await rig.step(False, COOLDOWN_SEC)
    assert rig.healer._pending_recovery == "tor-recover"
    assert rig.healer._attempts == MAX_ATTEMPTS
    return rig


async def test_host_recovery_restart_keeps_counting():
    rig = await _recover_submitted({"status": "applied"})
    await rig.step(False)  # result read
    rig.tor_started += 3600  # the host-run recovery restarted Tor
    await rig.step(False)
    assert rig.healer._attempts == MAX_ATTEMPTS
    assert rig.healer._failing_since is not None
    assert rig.healer._last_attempt is not None


async def test_refused_host_recovery_does_not_hide_a_later_external_restart():
    rig = await _recover_submitted({"status": "refused", "error": "cooldown"})
    await rig.step(False)  # refusal read: nothing restarted Tor
    rig.tor_started += 3600  # now the operator restarts it
    await rig.step(False)
    assert rig.healer._attempts == 0
    assert rig.healer._last_attempt is None
    assert rig.healer._failing_since == rig.clock.t


async def test_external_restart_after_an_adopted_healer_restart_still_resets():
    rig = _Rig()
    await rig.spend_newnyms()
    await rig.step(False, COOLDOWN_SEC)  # the healer's own Tor restart
    assert ("stop", "tor") in rig.docker.calls
    rig.tor_started += 3600
    await rig.step(True)  # adopts the healer's own start time
    await rig.step(True)  # second OK probe confirms recovery
    assert rig.healer._attempts == 0
    await rig.spend_newnyms()  # a new outage spends two NEWNYMs
    rig.tor_started += 3600  # the operator restarts Tor
    await rig.step(True)
    h = rig.healer
    assert (h._failing_since, h._attempts, h._last_attempt) == (None, 0, None)
