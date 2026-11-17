from unittest.mock import AsyncMock, patch

import pytest

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    DISRUPTIVE_WINDOW_SEC,
    EXHAUSTED_PROBE_SEC,
    MAX_ATTEMPTS,
    MAX_DISRUPTIVE_PER_DAY,
    NEWNYM_ATTEMPTS,
    PROBE_INTERVAL_SEC,
    RE_ALERT_SEC,
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
        ({"circuit_established": True, "pending_circuits": 64}, True),
        ({"circuit_established": True, "pending_circuits": 63}, False),
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


async def test_wedged_control_port_never_overrides_a_responding_probe():
    now = [100000.0]
    healer = _healer(now, probe=lambda: (True, "answered"))
    healer._attempts = 1
    healer._failing_since = now[0] - 3600
    healer.circuits_wedged = True
    with (
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
        patch("mining_dashboard.service.control_service.result", return_value=None),
    ):
        for _ in range(3):
            await healer.check()
            now[0] += PROBE_INTERVAL_SEC
    assert healer._attempts == 0
    assert healer._failing_since is None


async def test_wedged_control_port_is_named_in_failed_probe_evidence():
    now = [100000.0]
    healer = _healer(now, probe=lambda: (False, "no answer"))
    healer.circuits_wedged = True
    with (
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
    ):
        await healer.check()
    assert healer._failure_evidence == "no answer; control port reports wedged circuits"


async def test_lost_newnym_transport_is_retried_once_then_the_ladder_advances():
    now = [100000.0]
    docker = AsyncMock()
    docker.stop.return_value = docker.start.return_value = True
    healer = _healer(now)
    healer._docker = docker
    submits = []
    with (
        patch(
            f"{TARGET}.control_service.submit",
            side_effect=lambda action, **_: submits.append(action) or action,
        ),
        patch(f"{TARGET}.control_service.result", return_value={"status": "failed"}),
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
    ):
        for _ in range(14):
            await healer.check()
            now[0] += COOLDOWN_SEC
    assert submits.count("tor-newnym") == 3
    assert submits.count("tor-recover") == 1
    docker.stop.assert_awaited_once()


def test_give_up_waits_for_the_last_action_cooldown():
    now = [100000.0]
    healer = _healer(now)
    healer._attempts = 4
    healer._failing_since = now[0] - 3600
    healer._last_attempt = now[0]
    assert healer.decide(False, now[0] + COOLDOWN_SEC - 1) is None
    assert healer.decide(False, now[0] + COOLDOWN_SEC) == "exhausted"


async def test_past_the_cap_probes_realerts_hourly_and_notices_recovery_once():
    now = [100000.0]
    probes = []
    healthy_from = []

    def probe():
        probes.append(now[0])
        if healthy_from and now[0] >= healthy_from[0]:
            return True, "answered"
        return False, "no answer"

    notices = []

    async def notify(text):
        notices.append(text)
        return text

    healer = _healer(now, probe=probe)
    healer._notify = notify
    healer._attempts = MAX_ATTEMPTS
    healer._failing_since = now[0] - BROKEN_AFTER_SEC
    submits = []
    with (
        patch(
            f"{TARGET}.control_service.submit",
            side_effect=lambda action, **_: submits.append(action) or action,
        ),
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
        patch("mining_dashboard.service.control_service.result", return_value=None),
    ):
        await healer.check()
        assert submits == ["tor-heal-exhausted"]
        assert len(notices) == 1
        assert "past its cap" in notices[0] and "outage" in notices[0]
        now[0] += EXHAUSTED_PROBE_SEC - 1
        await healer.check()
        assert len(probes) == 1
        now[0] += 1
        await healer.check()
        assert len(probes) == 2
        assert len(notices) == 1
        now[0] += RE_ALERT_SEC
        await healer.check()
        assert len(probes) == 3
        assert len(notices) == 2
        assert "past its cap" in notices[1]
        assert submits == ["tor-heal-exhausted"]
        healer._docker.stop.assert_not_awaited()
        healer._docker.start.assert_not_awaited()
        healthy_from.append(now[0])
        for _ in range(2):
            now[0] += EXHAUSTED_PROBE_SEC
            await healer.check()
    assert len(notices) == 3
    assert "recovered" in notices[-1]
    assert healer._attempts == 0
    assert not healer._warned_exhausted
    assert healer._exhausted_alerted_at is None
    assert not healer._past_cap
