from unittest.mock import AsyncMock, patch

import pytest

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    DISRUPTIVE_WINDOW_SEC,
    MAX_DISRUPTIVE_PER_DAY,
    NEWNYM_ATTEMPTS,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)

TARGET = "mining_dashboard.service.health.tor_heal"


def _healer(now, probe=lambda: (False, "p")):
    return TorEgressHealer(
        AsyncMock(), enabled=True, probe=probe, clock=lambda: now[0], restart_monerod=False
    )


async def test_daily_cap_stops_disruptive_rungs_and_audits_once(caplog):
    now = [100000.0]
    healer = _healer(now)
    healer._attempts = NEWNYM_ATTEMPTS
    healer._failing_since = now[0] - BROKEN_AFTER_SEC
    healer._disruptive = [now[0] - 60] * MAX_DISRUPTIVE_PER_DAY
    submits = []
    with (
        patch(f"{TARGET}.control_service.submit", side_effect=lambda a, **k: submits.append(a)),
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
        caplog.at_level("WARNING", logger="TorHeal"),
    ):
        for _ in range(3):
            await healer.check()
            now[0] += PROBE_INTERVAL_SEC
    assert submits == ["tor-heal-exhausted"]
    healer._docker.stop.assert_not_awaited()
    assert sum("No more automatic action" in r.message for r in caplog.records) == 1
    assert healer.decide(False, now[0] + DISRUPTIVE_WINDOW_SEC) == "heal"


async def test_failed_audit_submission_is_logged_not_raised(caplog):
    now = [100000.0]
    healer = _healer(now)
    healer._attempts = NEWNYM_ATTEMPTS
    healer._failing_since = now[0] - BROKEN_AFTER_SEC
    healer._disruptive = [now[0]] * MAX_DISRUPTIVE_PER_DAY
    with (
        patch(f"{TARGET}.control_service.submit", side_effect=OSError("spool")),
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
        caplog.at_level("WARNING", logger="TorHeal"),
    ):
        await healer.check()
    assert any("could not be audited" in r.message for r in caplog.records)


@pytest.mark.parametrize(
    "reading,wedged",
    [
        ({"circuit_established": False}, True),
        ({"circuit_established": True, "pending_circuits": 32}, True),
        ({"circuit_established": True, "pending_circuits": 31}, False),
        ({"circuit_established": True, "pending_circuits": True}, False),
        ({}, False),
    ],
)
async def test_control_port_reading_sets_wedged(reading, wedged):
    healer = _healer([0.0])
    healer._pending_history = "history"
    healer._history_since = 0.0
    with patch(
        "mining_dashboard.service.control_service.result",
        return_value={"status": "applied", "saturated": False, **reading},
    ):
        await healer._read_history()
    assert healer.circuits_wedged is wedged


async def test_wedged_control_port_counts_a_responding_probe_as_failed():
    now = [100000.0]
    healer = _healer(now, probe=lambda: (True, "answered"))
    healer._attempts = 1
    healer._failing_since = now[0] - 3600
    healer.circuits_wedged = True
    with (
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
    ):
        for _ in range(3):
            await healer.check()
            now[0] += PROBE_INTERVAL_SEC
    assert healer._attempts == 2
    assert healer._failing_since is not None
    assert healer._ok_streak == 0
    healer.circuits_wedged = False
    assert healer.decide(True, now[0]) is None
    assert healer.decide(True, now[0]) == "recovered"
