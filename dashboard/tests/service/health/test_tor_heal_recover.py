"""Early diagnosis and host-gated automatic saturated-state recovery."""

from unittest.mock import AsyncMock, patch

import pytest

from mining_dashboard.service.health.tor_heal import (
    BROKEN_AFTER_SEC,
    COOLDOWN_SEC,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)


@pytest.mark.parametrize("saturated", [True, False])
async def test_first_round_reads_history_and_final_step_selects_host_recovery(saturated):
    now = [1000.0]
    docker = AsyncMock()
    docker.stop.return_value = docker.start.return_value = True
    healer = TorEgressHealer(
        docker,
        enabled=True,
        restart_monerod=False,
        probe=lambda: (False, "isolated failures"),
        clock=lambda: now[0],
    )
    requests = []
    results = {
        "tor-history": {"status": "applied", "saturated": saturated},
        "tor-newnym": {"status": "applied"},
    }

    def submit(action, **kwargs):
        requests.append(action)
        return action

    with (
        patch("mining_dashboard.service.control_service.submit", submit),
        patch("mining_dashboard.service.control_service.result", lambda rid: results.get(rid)),
        patch("mining_dashboard.service.request_spool.write", lambda req: submit(req["action"])),
    ):
        await healer.check()
        now[0] += BROKEN_AFTER_SEC
        await healer.check()
        assert requests == ["tor-history", "tor-newnym"]
        for _ in range(2):
            now[0] += COOLDOWN_SEC
            await healer.check()
        if saturated:
            assert requests.count("tor-recover") == 1
            docker.stop.assert_not_awaited()
            docker.start.assert_not_awaited()
        else:
            assert "tor-recover" not in requests
            docker.stop.assert_awaited_once()
            docker.start.assert_awaited_once()


@pytest.mark.parametrize(
    "result",
    [
        {"status": "applied"},
        {"status": "failed", "error": "six-hour cooldown"},
        {"status": "rejected", "error": "signature or evidence refused"},
        None,
    ],
)
async def test_recovery_result_alerts_once_without_fallback_or_resubmission(result, caplog):
    now = [1000.0]
    docker, notify = AsyncMock(), AsyncMock(return_value=True)
    healer = TorEgressHealer(
        docker,
        enabled=True,
        notify=notify,
        clock=lambda: now[0],
        probe=lambda: (False, "failed"),
    )
    healer._pending_recovery = "recovery"
    healer._recovery_requested_at = now[0]
    healer._attempts = 3
    healer._last_attempt = now[0]
    with (
        patch("mining_dashboard.service.control_service.result", return_value=result),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
        patch("mining_dashboard.service.control_service.submit") as submit,
        caplog.at_level("WARNING", logger="TorHeal"),
    ):
        await healer.check()
        if result is None:
            notify.assert_not_awaited()
            now[0] += 15 * 60
            await healer.check()
        for _ in range(2):
            now[0] += PROBE_INTERVAL_SEC
            await healer.check()
    submit.assert_not_called()
    docker.stop.assert_not_awaited()
    docker.start.assert_not_awaited()
    notify.assert_awaited_once()
    message = notify.await_args.args[0]
    if result and result["status"] == "applied":
        assert "reset saturated circuit history and guards" in message
    else:
        assert (result or {}).get("error", "host result unconfirmed") in message
        assert "No fallback restart" in message
    assert any(message in record.message for record in caplog.records)


async def test_auto_heal_off_never_requests_recovery_even_if_saturated():
    healer = TorEgressHealer(AsyncMock(), enabled=False)
    healer.saturated_history = True
    healer._attempts = 2
    with patch("mining_dashboard.service.control_service.submit") as submit:
        await healer.check()
    submit.assert_not_called()


async def test_recovery_notice_retries_failed_delivery():
    healer = TorEgressHealer(AsyncMock(), enabled=True, notify=AsyncMock(side_effect=[False, True]))
    healer._pending_recovery = "recovery"
    healer._recovery_requested_at = 0
    with patch(
        "mining_dashboard.service.control_service.result", return_value={"status": "applied"}
    ):
        await healer._read_recovery(1000)
        await healer._read_recovery(1300)
        await healer._read_recovery(1600)
    assert healer._notify.await_count == 2
