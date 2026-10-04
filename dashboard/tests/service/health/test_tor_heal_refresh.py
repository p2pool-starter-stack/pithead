"""Failure paths for the audited Tor circuit-refresh request."""

from contextlib import ExitStack
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
        return action

    def result(rid):
        return results.get(rid)

    stack = ExitStack()
    stack.enter_context(
        patch("mining_dashboard.service.health.tor_heal.control_service.submit", submit)
    )
    stack.enter_context(
        patch(
            "mining_dashboard.service.health.tor_heal_history.request_spool.write",
            lambda req: submit(req["action"]),
        )
    )
    return stack, patch("mining_dashboard.service.health.tor_heal.control_service.result", result)


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


async def test_second_outage_alerts_again_and_late_reading_is_dropped_on_recovery():
    now = [1000.0]
    notify = AsyncMock()
    submits = []
    ok = [False]
    results = {"tor-newnym": {"status": "failed"}, "tor-history": SATURATED}
    healer = TorEgressHealer(
        AsyncMock(), enabled=True, probe=lambda: (ok[0], "p"), notify=notify, clock=lambda: now[0]
    )
    p_submit, p_result = _heal_patches(results, submits)
    with p_submit, p_result:
        await healer.check()
        now[0] += BROKEN_AFTER_SEC
        await _run_rounds(healer, now, 4)
        assert notify.await_count == 1
        # Recover, with a history request still unanswered: the late reading must stay silent.
        assert healer._attempts == 0
        ok[0] = True
        healer._pending_history = "tor-history"
        results["tor-history"] = None
        for _ in range(3):
            now[0] += PROBE_INTERVAL_SEC
            await healer.check()
        assert healer.saturated_history is False
        assert healer._warned_saturated is False
        results["tor-history"] = SATURATED
        # A fresh outage re-arms the once-per-outage alert.
        ok[0] = False
        await _run_rounds(healer, now, 6)
    assert notify.await_count >= 2


async def test_lost_history_request_is_dropped_after_one_probe_interval():
    now = [1000.0]
    healer = TorEgressHealer(
        AsyncMock(), enabled=True, probe=lambda: (True, "p"), clock=lambda: now[0]
    )
    submits = []
    p_submit, p_result = _heal_patches({"tor-history": None}, submits)
    with p_submit, p_result:
        healer._request_history()
        await healer._read_history()
        assert healer._pending_history == "tor-history"
        now[0] += PROBE_INTERVAL_SEC
        await healer._read_history()
    assert healer._pending_history is None


async def test_saturated_alert_retries_until_a_sink_delivers():
    healer = TorEgressHealer(
        AsyncMock(), enabled=True, notify=AsyncMock(side_effect=[None, "sent"])
    )
    submits = []
    p_submit, p_result = _heal_patches({"tor-history": SATURATED}, submits)
    with p_submit, p_result:
        for _ in range(3):
            healer._request_history()
            await healer._read_history()
    assert healer._notify.await_count == 2
    assert healer._warned_saturated is True


async def test_recovery_clear_is_retried_until_host_acknowledges():
    now = [1000.0]
    healer = TorEgressHealer(
        AsyncMock(), enabled=True, probe=lambda: (True, "p"), clock=lambda: now[0]
    )
    healer._clear_history = True
    submits = []
    results = {"tor-history": {"status": "failed"}}
    p_submit, p_result = _heal_patches(results, submits)
    with p_submit, p_result:
        await healer.check()
        now[0] += PROBE_INTERVAL_SEC
        await healer.check()
        assert healer._clear_history is True
        results["tor-history"] = {"status": "applied"}
        now[0] += PROBE_INTERVAL_SEC
        await healer.check()
    assert submits == ["tor-history", "tor-history"]
    assert healer._clear_history is False


async def test_exhausted_heal_keeps_history_and_undelivered_alerts_alive():
    now = [1000.0]
    docker = AsyncMock()
    docker.stop.return_value = docker.start.return_value = True
    notify = AsyncMock(side_effect=[None, None, "recovery delivered", "history delivered"])
    healer = TorEgressHealer(
        docker,
        enabled=True,
        restart_monerod=False,
        probe=lambda: (False, "p"),
        notify=notify,
        clock=lambda: now[0],
    )
    submits = []
    results = {"tor-newnym": {"status": "applied"}, "tor-history": SATURATED}
    p_submit, p_result = _heal_patches(results, submits)
    with p_submit, p_result:
        await _run_rounds(healer, now, 9)
    assert healer._attempts == MAX_ATTEMPTS
    assert submits.count("tor-newnym") == 2
    assert submits.count("tor-history") >= 3
    assert healer._warned_saturated is True
    assert notify.await_count == 4
    assert submits.count("tor-recover") == 1
    docker.stop.assert_not_awaited()
    docker.start.assert_not_awaited()
