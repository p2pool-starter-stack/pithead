"""Failure paths for the audited Tor circuit-refresh request."""

from unittest.mock import AsyncMock, patch

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)


async def test_pending_newnym_times_out_without_probing_or_restarting():
    now = [1000.0]
    probes = []
    docker = AsyncMock()
    healer = TorEgressHealer(
        docker, enabled=True, probe=lambda: probes.append(1) or False, clock=lambda: now[0]
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
    healer = TorEgressHealer(docker, enabled=True, probe=lambda: False, clock=lambda: now)
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
