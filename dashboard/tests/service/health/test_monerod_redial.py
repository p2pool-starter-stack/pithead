import pytest

from mining_dashboard.service.health import monerod_redial as mr
from mining_dashboard.service.health.monerod_redial import MonerodRedial

TARGET = "mining_dashboard.service.health.monerod_redial"


class _Docker:
    def __init__(self, ok=True):
        self.calls = []
        self.ok = ok

    async def stop(self, container, **kwargs):
        self.calls.append(("stop", container))
        return self.ok

    async def start(self, container, **kwargs):
        self.calls.append(("start", container))
        return self.ok


async def _no_sleep(_):
    return None


class _Rig:
    def __init__(self, monkeypatch, enabled=True, ok=True):
        self.t = 1000.0
        self.docker = _Docker(ok)
        self.audits = []
        self.tor = {"running": True, "health": "healthy", "started_at": 100.0}
        self.monerod = {"running": True, "started_at": 50.0}
        self.redial = MonerodRedial(
            self.docker, audit=self._audit, enabled=enabled, clock=lambda: self.t
        )

        async def health():
            return {"tor": self.tor, "monerod": self.monerod}

        monkeypatch.setattr(f"{TARGET}.get_container_health", health)

    async def _audit(self, reason, status):
        self.audits.append((reason, status))

    async def step(self, peers_out=0, peerless=False, seconds=mr.CHECK_INTERVAL_SEC):
        self.t += seconds
        await self.redial.check(
            {"peers_visible": peers_out is not None, "peers_out": peers_out, "peerless": peerless}
        )

    async def run(self, seconds, **verdict):
        end = self.t + seconds
        while self.t < end:
            await self.step(**verdict)

    @property
    def restarts(self):
        return self.docker.calls.count(("stop", "monerod"))


@pytest.mark.asyncio
async def test_external_tor_start_redials_peerless_monerod_once(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.step(peers_out=8)
    rig.tor["started_at"] = 900.0
    await rig.run(mr.REDIAL_SETTLE_SEC + mr.CHECK_INTERVAL_SEC, peers_out=0)
    assert rig.docker.calls == [("stop", "monerod"), ("start", "monerod")]
    assert rig.audits == [("tor-start", "applied")]
    await rig.run(mr.COOLDOWN_SEC * 2, peers_out=0)
    assert rig.restarts == 1


@pytest.mark.asyncio
async def test_no_redial_before_tor_reports_a_circuit(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.step(peers_out=8)
    rig.tor.update(started_at=900.0, health="starting")
    await rig.run(mr.REDIAL_SETTLE_SEC * 3, peers_out=0)
    assert rig.restarts == 0
    rig.tor["health"] = "healthy"
    await rig.run(mr.REDIAL_SETTLE_SEC + mr.CHECK_INTERVAL_SEC, peers_out=0)
    assert rig.restarts == 1


@pytest.mark.asyncio
async def test_monerod_that_recovers_by_itself_is_left_alone(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.step(peers_out=8)
    rig.tor["started_at"] = 900.0
    await rig.step(peers_out=0)
    await rig.run(mr.REDIAL_SETTLE_SEC, peers_out=5)
    await rig.run(mr.REDIAL_SETTLE_SEC * 3, peers_out=0)
    assert rig.restarts == 0


@pytest.mark.asyncio
async def test_monerod_restarted_after_tor_gets_its_own_settle_window(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.step(peers_out=8)
    rig.tor["started_at"] = 900.0
    await rig.run(mr.REDIAL_SETTLE_SEC - mr.CHECK_INTERVAL_SEC * 2, peers_out=0)
    rig.monerod["started_at"] = 950.0
    await rig.run(mr.REDIAL_SETTLE_SEC - mr.CHECK_INTERVAL_SEC, peers_out=0)
    assert rig.restarts == 0
    await rig.run(mr.CHECK_INTERVAL_SEC * 3, peers_out=0)
    assert rig.restarts == 1


@pytest.mark.asyncio
async def test_monerod_restarted_after_tor_that_gets_peers_is_left_alone(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.step(peers_out=8)
    rig.tor["started_at"] = 900.0
    rig.monerod["started_at"] = 950.0
    await rig.step(peers_out=0)
    await rig.run(mr.REDIAL_SETTLE_SEC * 3, peers_out=4)
    assert rig.restarts == 0


@pytest.mark.asyncio
async def test_start_that_fails_is_retried(monkeypatch):
    rig = _Rig(monkeypatch)
    starts = iter([False, False, True])

    async def start(container, **kwargs):
        rig.docker.calls.append(("start", container))
        return next(starts)

    rig.docker.start = start
    monkeypatch.setattr(f"{TARGET}.asyncio.sleep", _no_sleep)
    await rig.run(mr.WATCHDOG_GRACE_SEC + mr.CHECK_INTERVAL_SEC * 2, peers_out=0, peerless=True)
    assert rig.docker.calls.count(("start", "monerod")) == 3
    assert rig.audits == [("peerless", "applied")]


@pytest.mark.asyncio
async def test_stopped_monerod_is_never_started(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.step(peers_out=8)
    rig.tor["started_at"] = 900.0
    rig.monerod["running"] = False
    await rig.run(mr.REDIAL_SETTLE_SEC * 3, peers_out=0, peerless=True)
    assert rig.docker.calls == []


@pytest.mark.asyncio
async def test_disabled_for_a_remote_node(monkeypatch):
    rig = _Rig(monkeypatch, enabled=False)
    await rig.run(mr.WATCHDOG_GRACE_SEC * 3, peers_out=0, peerless=True)
    assert rig.docker.calls == []


@pytest.mark.asyncio
async def test_peerless_verdict_restarts_after_the_grace(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.run(mr.WATCHDOG_GRACE_SEC - mr.CHECK_INTERVAL_SEC, peers_out=0, peerless=True)
    assert rig.restarts == 0
    await rig.run(mr.CHECK_INTERVAL_SEC * 2, peers_out=0, peerless=True)
    assert rig.restarts == 1
    assert rig.audits == [("peerless", "applied")]


@pytest.mark.asyncio
async def test_peerless_watchdog_waits_for_a_healthy_tor(monkeypatch):
    rig = _Rig(monkeypatch)
    rig.tor["health"] = "unhealthy"
    await rig.run(mr.WATCHDOG_GRACE_SEC * 3, peers_out=0, peerless=True)
    assert rig.restarts == 0
    rig.tor["health"] = "healthy"
    await rig.step(peers_out=0, peerless=True)
    assert rig.restarts == 0
    await rig.run(mr.WATCHDOG_GRACE_SEC + mr.CHECK_INTERVAL_SEC, peers_out=0, peerless=True)
    assert rig.restarts == 1


@pytest.mark.asyncio
async def test_tor_health_flap_restarts_the_peerless_grace(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.run(mr.WATCHDOG_GRACE_SEC - mr.CHECK_INTERVAL_SEC, peers_out=0, peerless=True)
    rig.tor["health"] = "starting"
    await rig.step(peers_out=0, peerless=True)
    rig.tor["health"] = "healthy"
    await rig.step(peers_out=0, peerless=True)
    assert rig.restarts == 0
    await rig.run(mr.WATCHDOG_GRACE_SEC + mr.CHECK_INTERVAL_SEC, peers_out=0, peerless=True)
    assert rig.restarts == 1


@pytest.mark.asyncio
async def test_cap_lifts_after_a_day(monkeypatch):
    rig = _Rig(monkeypatch)
    await rig.run(mr.COOLDOWN_SEC * (mr.DAILY_CAP + 2), peers_out=0, peerless=True)
    assert rig.restarts == mr.DAILY_CAP
    await rig.run(mr.DAY_SEC, peers_out=0, peerless=True)
    assert rig.restarts > mr.DAILY_CAP


@pytest.mark.asyncio
async def test_cap_warning_is_logged_once(monkeypatch, caplog):
    rig = _Rig(monkeypatch)
    await rig.run(mr.COOLDOWN_SEC * (mr.DAILY_CAP + 4), peers_out=0, peerless=True)
    assert rig.restarts == mr.DAILY_CAP
    assert sum("no more automatic action" in r.getMessage() for r in caplog.records) == 1


@pytest.mark.asyncio
async def test_unconfirmed_restart_is_audited_failed(monkeypatch):
    rig = _Rig(monkeypatch, ok=False)
    monkeypatch.setattr(f"{TARGET}.asyncio.sleep", _no_sleep)
    await rig.run(mr.WATCHDOG_GRACE_SEC + mr.CHECK_INTERVAL_SEC * 2, peers_out=0, peerless=True)
    assert rig.audits == [("peerless", "failed")]
    assert rig.docker.calls.count(("start", "monerod")) == mr.MONEROD_START_ATTEMPTS
