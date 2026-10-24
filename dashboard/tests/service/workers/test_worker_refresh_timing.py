from unittest.mock import AsyncMock, call

import pytest

from mining_dashboard.service.workers import worker_refresh


@pytest.mark.parametrize(
    ("timing", "overrides", "expected_attempts", "expected_delay"),
    [
        (None, {}, 6, 10.0),
        ((2, 0.125), {}, 2, 0.125),
        ((0, 0), {}, 0, 0),
        ((2, 0.125), {"attempts": 3, "delay_s": 0}, 3, 0),
    ],
)
async def test_refresh_timing_defaults_and_overrides(
    monkeypatch, timing, overrides, expected_attempts, expected_delay
):
    if timing is not None:
        monkeypatch.setattr(worker_refresh, "REFRESH_ATTEMPTS", timing[0])
        monkeypatch.setattr(worker_refresh, "REFRESH_DELAY_S", timing[1])
    client = AsyncMock()
    client.get_stats.return_value = {}
    sleep = AsyncMock()
    data = {"workers": [{"name": "rig1", "ip": "127.0.0.1"}]}

    assert not await worker_refresh.refresh_worker_after_upgrade(
        data, "rig1", "v1.12.0", worker_client=client, sleep=sleep, **overrides
    )

    assert client.get_stats.await_args_list == [call("127.0.0.1", "rig1")] * expected_attempts
    assert sleep.await_args_list == [call(expected_delay)] * expected_attempts
