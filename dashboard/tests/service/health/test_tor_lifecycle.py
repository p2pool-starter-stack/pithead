import json
import logging
from unittest.mock import AsyncMock, patch

import pytest

from mining_dashboard.service.health.tor_heal import BROKEN_AFTER_SEC, COOLDOWN_SEC, TorEgressHealer
from tests.service.health.test_tor_heal_restart import _FlakyDocker, _heal_to_restart

MODULE = "mining_dashboard.service.health.tor_lifecycle"


def receipts(caplog):
    return [
        json.loads(record.message.split("pithead-tor-lifecycle ", 1)[1])
        for record in caplog.records
        if "pithead-tor-lifecycle " in record.message
    ]


async def test_real_healer_branch_receipts_include_failed_calls_and_retries(caplog):
    docker = _FlakyDocker(fail_starts=1)
    docker.identity = AsyncMock(return_value="a" * 64)
    with caplog.at_level(logging.INFO):
        healer = await _heal_to_restart(docker, AsyncMock(return_value={}))
    rows = receipts(caplog)
    assert [(row["action"], row["result"]) for row in rows] == [
        ("stop", "requested"),
        ("stop", "unconfirmed"),
        ("start", "requested"),
        ("start", "unconfirmed"),
        ("start", "requested"),
        ("start", "confirmed"),
    ]
    assert len({row["operation"] for row in rows}) == 1
    assert all(row["container"] == "a" * 64 for row in rows)
    assert all(
        set(row) == {"timestamp", "caller", "operation", "container", "action", "result"}
        for row in rows
    )
    assert all(row["caller"] == "tor-heal" for row in rows)
    assert healer._recovery_step == "Tor start (stop unconfirmed)"


@pytest.mark.parametrize("failure", ["identity", "logger", "uuid"])
async def test_receipt_failures_cannot_change_healer_calls(failure):
    docker = _FlakyDocker(fail_starts=1)
    docker.identity = AsyncMock(side_effect=OSError("private diagnostic"))
    target = {"identity": "json.dumps", "logger": "logger.info", "uuid": "uuid.uuid4"}[failure]

    def fail(*args, **kwargs):
        if failure != "logger" or args[0].startswith("pithead-tor-lifecycle "):
            raise OSError("private diagnostic")

    with patch(f"{MODULE}.{target}", side_effect=fail):
        healer = await _heal_to_restart(docker, AsyncMock(return_value={}))
    assert docker.calls == [("stop", "tor"), ("start", "tor"), ("start", "tor")]
    assert healer._recovery_step == "Tor start (stop unconfirmed)"


async def test_unsafe_identity_is_withheld_and_call_exception_preserved(caplog):
    docker = _FlakyDocker()
    docker.identity = AsyncMock(return_value="private.onion key=value")
    docker.stop = AsyncMock(side_effect=ValueError("private diagnostic"))
    healer = TorEgressHealer(docker, enabled=False)
    with caplog.at_level(logging.INFO), pytest.raises(ValueError, match="private diagnostic"):
        await healer._tor_call("stop")
    rows = receipts(caplog)
    assert [row["result"] for row in rows] == ["requested", "unconfirmed"]
    assert all(row["container"] == "unavailable" for row in rows)
    assert "private" not in caplog.text


@pytest.mark.parametrize("outcome", ["applied", "failed", "timeout", "submit-error"])
async def test_host_gated_recovery_receipts_include_terminal_failures(outcome, caplog):
    docker = _FlakyDocker()
    docker.identity = AsyncMock(return_value="a" * 64)
    now = COOLDOWN_SEC * 10
    healer = TorEgressHealer(
        docker,
        enabled=True,
        clock=lambda: now,
        probe=lambda: (False, "test probe"),
        restart_monerod=False,
    )
    healer._failing_since = now - BROKEN_AFTER_SEC
    healer._last_attempt = now - COOLDOWN_SEC
    healer._attempts = 2
    healer.saturated_history = True
    result = None if outcome == "timeout" else {"status": outcome, "error": "private.onion"}
    with (
        caplog.at_level(logging.INFO),
        patch(
            "mining_dashboard.service.health.tor_heal.get_container_health",
            AsyncMock(return_value={}),
        ),
        patch("mining_dashboard.service.request_spool.write", return_value="history"),
        patch(
            "mining_dashboard.service.control_service.submit",
            side_effect=OSError() if outcome == "submit-error" else None,
            return_value="recovery",
        ) as submit,
        patch("mining_dashboard.service.control_service.result", return_value=result),
    ):
        await healer.check()
        if outcome != "submit-error":
            await healer._read_recovery(now + 15 * 60)
    rows = receipts(caplog)
    assert [r["action"] for r in rows] == ["recover", "recover"]
    assert [r["result"] for r in rows] == [
        "requested",
        "confirmed" if outcome == "applied" else "unconfirmed",
    ]
    assert rows[0]["operation"] == rows[1]["operation"] != "unavailable"
    assert all(r["container"] == "a" * 64 for r in rows)
    assert "private" not in json.dumps(rows)
    submit.assert_called_once_with("tor-recover", actor="tor-heal")
    assert not docker.calls
