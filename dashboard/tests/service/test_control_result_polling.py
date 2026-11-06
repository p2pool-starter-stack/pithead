from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, call

from mining_dashboard.service import control_service


async def test_result_poll_uses_injected_sleeper_and_production_interval(monkeypatch):
    sleep = AsyncMock()
    monkeypatch.setattr(control_service, "asyncio", SimpleNamespace(sleep=sleep))
    monkeypatch.setattr(
        control_service,
        "result",
        Mock(side_effect=[None, {"status": "previewed"}, {"status": "applied"}]),
    )

    result = await control_service.wait_result(
        "pending", done=lambda value: value["status"] == "applied", timeout_s=60
    )

    assert result == {"status": "applied"}
    assert sleep.await_args_list == [call(0.5), call(0.5)]
