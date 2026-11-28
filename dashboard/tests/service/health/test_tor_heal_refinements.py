from unittest.mock import AsyncMock, patch

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    DISRUPTIVE_SPACING_SEC,
    NEWNYM_ATTEMPTS,
    TorEgressHealer,
)

TARGET = "mining_dashboard.service.health.tor_heal"
RESULT = "mining_dashboard.service.control_service.result"


def _healer(now, probe=lambda: (False, "p")):
    return TorEgressHealer(
        AsyncMock(), enabled=True, probe=probe, clock=lambda: now[0], restart_monerod=False
    )


async def _read(healer, reading):
    healer._pending_history = "history"
    healer._history_since = 0.0
    with patch(RESULT, return_value={"status": "applied", "saturated": False, **reading}):
        await healer._read_history()


async def test_completing_circuits_hold_the_disruptive_rung_until_they_stop():
    now = [100000.0]
    healer = _healer(now)
    healer._attempts = NEWNYM_ATTEMPTS
    healer._failing_since = now[0] - BROKEN_AFTER_SEC
    await _read(healer, {"built_circuits": [1, 2]})
    assert not healer.circuits_completing
    await _read(healer, {"built_circuits": [1, 2, 3]})
    assert healer.circuits_completing
    assert healer.decide(False, now[0]) is None
    assert healer._attempts == NEWNYM_ATTEMPTS
    await _read(healer, {"built_circuits": [1, 2, 3]})
    assert not healer.circuits_completing
    assert healer.decide(False, now[0]) == "heal"


async def test_completing_circuits_never_hold_a_newnym_rung():
    now = [100000.0]
    healer = _healer(now)
    healer._failing_since = now[0] - BROKEN_AFTER_SEC
    healer.circuits_completing = True
    assert healer.decide(False, now[0]) == "heal"


async def test_missing_built_list_is_no_evidence_of_completion():
    healer = _healer([0.0])
    await _read(healer, {"built_circuits": [1]})
    await _read(healer, {})
    assert not healer.circuits_completing


async def test_lock_refused_history_is_a_distinct_logged_result(caplog):
    healer = _healer([0.0])
    healer.circuits_wedged = True
    healer._pending_history = "history"
    healer._history_since = 0.0
    with (
        patch(RESULT, return_value={"status": "lock_refused"}),
        caplog.at_level("WARNING", logger="TorHeal"),
    ):
        await healer._read_history()
    assert any("refused by the host mutation lock" in r.message for r in caplog.records)
    assert not any("refused or unavailable" in r.message for r in caplog.records)
    assert healer.circuits_wedged is True
    assert healer._pending_history is None


async def test_no_history_is_requested_in_a_disruptive_round():
    now = [100000.0]
    healer = _healer(now)
    healer._docker.stop.return_value = healer._docker.start.return_value = True
    healer._attempts = NEWNYM_ATTEMPTS + 1
    healer._disruptive = [now[0] - 2 * DISRUPTIVE_SPACING_SEC]
    healer._failing_since = now[0] - BROKEN_AFTER_SEC
    with (
        patch(f"{TARGET}.control_service.submit"),
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", return_value="history") as write,
        patch(RESULT, return_value=None),
    ):
        await healer.check()
        healer._docker.stop.assert_awaited_once()
        write.assert_not_called()
        now[0] += COOLDOWN_SEC
        healer._attempts = 1
        await healer.check()
    assert write.call_count == 1


def test_disruptive_rungs_are_an_hour_apart_and_newnym_keeps_thirty_minutes():
    now = [100000.0]
    healer = _healer(now)
    healer._attempts = 1
    healer._failing_since = now[0] - 4 * BROKEN_AFTER_SEC
    healer._last_attempt = now[0]
    assert healer.decide(False, now[0] + COOLDOWN_SEC - 1) is None
    assert healer.decide(False, now[0] + COOLDOWN_SEC) == "heal"
    healer = _healer(now)
    healer._attempts = NEWNYM_ATTEMPTS + 1
    healer._failing_since = now[0] - 4 * BROKEN_AFTER_SEC
    healer._last_attempt = now[0]
    healer._disruptive = [now[0]]
    assert healer.decide(False, now[0] + DISRUPTIVE_SPACING_SEC - 1) is None
    assert healer.decide(False, now[0] + DISRUPTIVE_SPACING_SEC) == "heal"
    assert healer._attempts == NEWNYM_ATTEMPTS + 2


async def test_unwritable_spool_still_reaches_the_restart_rung_and_the_past_cap_alert():
    now = [100000.0]
    notices = []

    async def notify(text):
        notices.append(text)
        return text

    healer = _healer(now)
    healer._notify = notify
    healer._docker.stop.return_value = healer._docker.start.return_value = True
    with (
        patch(f"{TARGET}.control_service.submit", side_effect=OSError("spool")) as submit,
        patch(f"{TARGET}.get_container_health", AsyncMock(return_value={})),
        patch("mining_dashboard.service.request_spool.write", side_effect=OSError("spool")),
        patch(RESULT, return_value=None),
    ):
        for _ in range(40):
            await healer.check()
            now[0] += COOLDOWN_SEC
    actions = [c.args[0] for c in submit.call_args_list]
    assert actions.count("tor-recover") == 1
    assert "tor-heal-exhausted" in actions
    healer._docker.stop.assert_awaited_once()
    assert any("past its cap" in n for n in notices)
    assert healer._attempts >= 4
