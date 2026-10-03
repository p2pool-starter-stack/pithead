"""Failure paths for the audited Tor circuit-refresh request."""

from unittest.mock import AsyncMock, patch

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    MAX_ATTEMPTS,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)


async def test_unconfirmed_newnym_cannot_escalate_to_container_restart():
    now = [1000.0]
    docker = AsyncMock()
    healer = TorEgressHealer(
        docker, enabled=True, probe=lambda: (False, "test probe"), clock=lambda: now[0]
    )
    with (
        patch("mining_dashboard.service.health.tor_heal.control_service.submit", return_value="id"),
        patch(
            "mining_dashboard.service.health.tor_heal.control_service.result",
            return_value={"status": "rejected", "error": "NEWNYM cooldown"},
        ),
    ):
        await healer.check()
        for _ in range(MAX_ATTEMPTS + 1):
            now[0] += COOLDOWN_SEC
            await healer.check()
    docker.stop.assert_not_awaited()
    assert healer._attempts == 0


async def test_probe_is_throttled_to_the_interval():
    now = [1000.0]
    calls = []
    healer = TorEgressHealer(
        AsyncMock(),
        enabled=True,
        probe=lambda: (calls.append(1) or True, "test probe"),
        clock=lambda: now[0],
    )
    await healer.check()
    now[0] += PROBE_INTERVAL_SEC - 1
    await healer.check()
    assert len(calls) == 1
    now[0] += 1
    await healer.check()
    assert len(calls) == 2


async def test_pending_newnym_times_out_without_probing_or_restarting():
    now = [1000.0]
    probes = []
    docker = AsyncMock()
    healer = TorEgressHealer(
        docker,
        enabled=True,
        probe=lambda: (probes.append(1) or False, "test probe"),
        clock=lambda: now[0],
    )
    healer._pending_refresh = "id"
    healer._pending_since = now[0]
    healer._attempts = 1
    with patch(
        "mining_dashboard.service.health.tor_heal.control_service.result", return_value=None
    ):
        await healer.check()
        assert healer._pending_refresh == "id"
        now[0] += PROBE_INTERVAL_SEC
        await healer.check()
    assert healer._pending_refresh is None
    assert healer._attempts == 0
    assert healer._last_attempt == now[0]
    assert not probes
    docker.stop.assert_not_awaited()


async def test_failed_newnym_submission_refunds_attempt():
    now = 1000.0
    docker = AsyncMock()
    healer = TorEgressHealer(
        docker, enabled=True, probe=lambda: (False, "test probe"), clock=lambda: now
    )
    healer._failing_since = now - BROKEN_AFTER_SEC
    with patch(
        "mining_dashboard.service.health.tor_heal.control_service.submit",
        side_effect=OSError("control spool unavailable"),
    ):
        await healer.check()
    assert healer._attempts == 0
    assert healer._pending_refresh is None
    assert healer._last_attempt == now
    docker.stop.assert_not_awaited()


SATURATED = {"status": "applied", "saturated": True}


def _heal_patches(results, submits):
    """Route control results by request id: NEWNYM rounds get ``results["tor-newnym"]``."""

    def submit(action, **_):
        submits.append(action)
        return action if action == "tor-history" else "00000000-0000-4000-8000-000000000000"

    def result(rid):
        return results["tor-history" if rid == "tor-history" else "tor-newnym"]

    return (
        patch("mining_dashboard.service.health.tor_heal.control_service.submit", submit),
        patch("mining_dashboard.service.health.tor_heal.control_service.result", result),
    )


async def _run_rounds(healer, now, rounds):
    for _ in range(rounds):
        await healer.check()
        now[0] += max(COOLDOWN_SEC, BROKEN_AFTER_SEC)


async def test_unconfirmed_newnym_reads_saturated_history_and_alerts_once(caplog):
    now = [1000.0]
    notify = AsyncMock()
    submits = []
    results = {"tor-newnym": {"status": "rejected", "error": "NEWNYM budget or cooldown"}}
    healer = TorEgressHealer(
        AsyncMock(),
        enabled=True,
        probe=lambda: (False, "test probe"),
        notify=notify,
        clock=lambda: now[0],
    )
    results["tor-history"] = SATURATED
    p_submit, p_result = _heal_patches(results, submits)
    with p_submit, p_result, caplog.at_level("WARNING", logger="TorHeal"):
        await healer.check()  # starts the outage
        now[0] += BROKEN_AFTER_SEC
        await _run_rounds(healer, now, 4)
    assert "tor-history" in submits
    assert healer.saturated_history is True
    assert sum("tor-recover check" in r.message for r in caplog.records) >= 2
    notify.assert_awaited_once()
    assert "./pithead tor-recover" in notify.await_args.args[0]


async def test_unsaturated_history_stays_silent():
    now = [1000.0]
    notify = AsyncMock()
    submits = []
    results = {
        "tor-newnym": {"status": "failed", "error": "Tor control signal failed"},
        "tor-history": {"status": "applied", "saturated": False},
    }
    healer = TorEgressHealer(
        AsyncMock(),
        enabled=True,
        probe=lambda: (False, "test probe"),
        notify=notify,
        clock=lambda: now[0],
    )
    p_submit, p_result = _heal_patches(results, submits)
    with p_submit, p_result:
        await healer.check()
        now[0] += BROKEN_AFTER_SEC
        await _run_rounds(healer, now, 4)
    assert "tor-history" in submits
    assert healer.saturated_history is False
    notify.assert_not_awaited()


async def test_healthy_egress_never_requests_history():
    submits = []
    healer = TorEgressHealer(AsyncMock(), enabled=True, probe=lambda: (True, "ok"))
    p_submit, p_result = _heal_patches({}, submits)
    with p_submit, p_result:
        await healer.check()
    assert submits == []
