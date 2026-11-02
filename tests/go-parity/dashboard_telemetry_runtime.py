import os
from types import MethodType, SimpleNamespace
from unittest.mock import MagicMock

import pytest

from mining_dashboard import go_polling
from mining_dashboard.service import telemetry_capture
from mining_dashboard.service.data_service import DataService

# ruff: noqa: S101

pytest_plugins = ["dashboard_telemetry_plugin"]
pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"),
]


def _service():
    state = SimpleNamespace(
        add_disk_growth=MagicMock(),
        add_network_history=MagicMock(),
        add_worker_history=MagicMock(),
    )
    service = SimpleNamespace(
        state_manager=state,
        _last_hourly_capture=0.0,
        _last_worker_capture=0.0,
        _telemetry_plan=None,
    )
    service._telemetry_plan = MethodType(DataService._telemetry_plan, service)
    return service, state


async def _capture(
    service, *, now=4000.0, monero=None, disk=None, network=None, pool=None, workers=None
):
    return await telemetry_capture.capture(
        service,
        now,
        {} if monero is None else monero,
        {} if disk is None else disk,
        {} if network is None else network,
        {} if pool is None else pool,
        [] if workers is None else workers,
    )


async def test_capture_preserves_write_and_stamp_order_across_interleaving():
    service, state = _service()
    events = []
    network = {"difficulty": 1, "height": 2, "reward": 3}
    workers = [{"name": "before", "status": "offline", "h15": 1}]

    def disk(*args, **kwargs):
        events.append(("disk", args, kwargs))
        network.update(difficulty=11, height=12, reward=13)

    def network_write(*args, **kwargs):
        events.append(("network", args, kwargs))
        workers[0].update(name="after", status="online", h15=21, accepted=22, rejected=23)

    def worker_write(rows):
        events.append(("workers", rows))

    state.add_disk_growth.side_effect = disk
    state.add_network_history.side_effect = network_write
    state.add_worker_history.side_effect = worker_write
    await _capture(
        service,
        monero={"db_size": 4},
        disk={"used_gb": 5, "total_gb": 6},
        network=network,
        pool={"hashrate": 14},
        workers=workers,
    )
    assert [event[0] for event in events] == ["disk", "network", "workers"]
    assert events[0][2] == {"monero_db_bytes": 4, "disk_used_gb": 5, "disk_total_gb": 6}
    assert events[1][2] == {"difficulty": 11, "height": 12, "reward": 13, "pool_hashrate": 14}
    assert events[2][1] == [
        {"ts": 4000.0, "name": "after", "h15": 21, "accepted": 22, "rejected": 23}
    ]
    assert service._last_hourly_capture == service._last_worker_capture == 4000.0


async def test_worker_interval_and_rows_are_read_after_hourly_writes(monkeypatch):
    from mining_dashboard.service import data_service

    service, state = _service()
    workers = [{"name": "before", "status": "offline"}]
    monkeypatch.setattr(data_service, "_WORKER_HISTORY_CAPTURE_SEC", 300)

    def network_write(*_args, **_kwargs):
        data_service._WORKER_HISTORY_CAPTURE_SEC = 5000
        workers[0].update(name="after", status="online")

    state.add_network_history.side_effect = network_write
    await _capture(service, workers=workers)
    state.add_disk_growth.assert_called_once()
    state.add_network_history.assert_called_once()
    state.add_worker_history.assert_not_called()
    assert service._last_hourly_capture == 4000.0
    assert service._last_worker_capture == 0.0


async def test_worker_not_due_does_not_read_or_transmit_workers(monkeypatch):
    service, state = _service()
    service._last_hourly_capture = 100.0
    calls = []
    native_call = go_polling.go_channel.call

    class UnreadableWorkers(list):
        def __iter__(self):
            raise AssertionError("workers read before due gate")

    def counted(helper, payload):
        calls.append((helper, payload["operation"], payload["args"]))
        return native_call(helper, payload)

    monkeypatch.setattr(go_polling.go_channel, "call", counted)
    await _capture(service, now=100.0, workers=UnreadableWorkers([object()]))
    assert calls == [
        ("fleet", "poll_telemetry_hourly", [100.0, 100.0, 3600, {}, {}]),
        ("fleet", "poll_telemetry_worker_due", [100.0, 0.0, 300]),
    ]
    state.add_disk_growth.assert_not_called()
    state.add_network_history.assert_not_called()
    state.add_worker_history.assert_not_called()


@pytest.mark.parametrize("reply", [None, 0, 1, [], {}])
async def test_invalid_worker_due_plan_fails_before_reading_workers(reply):
    service, state = _service()
    service._last_hourly_capture = 100.0
    native = service._telemetry_plan
    service._telemetry_plan = lambda phase, args: (
        reply if phase == "worker_due" else native(phase, args)
    )

    class UnreadableWorkers(list):
        def __iter__(self):
            raise AssertionError("workers read after invalid due plan")

    with pytest.raises(RuntimeError, match="invalid"):
        await _capture(service, now=100.0, workers=UnreadableWorkers([object()]))
    state.add_worker_history.assert_not_called()


@pytest.mark.parametrize("failed", ["disk", "network", "workers"])
async def test_writer_failures_stop_at_original_prefix_and_delay_stamps(failed):
    service, state = _service()
    events = []
    for name, method in (
        ("disk", state.add_disk_growth),
        ("network", state.add_network_history),
        ("workers", state.add_worker_history),
    ):
        method.side_effect = lambda *args, _name=name, **kwargs: (
            events.append(_name),
            (_ for _ in ()).throw(RuntimeError(_name)) if _name == failed else None,
        )[-1]
    with pytest.raises(RuntimeError, match=failed):
        await _capture(
            service,
            workers=[{"name": "rig", "status": "online"}],
        )
    expected = {
        "disk": (["disk"], 0.0, 0.0),
        "network": (["disk", "network"], 0.0, 0.0),
        "workers": (["disk", "network", "workers"], 4000.0, 0.0),
    }[failed]
    assert (events, service._last_hourly_capture, service._last_worker_capture) == expected


@pytest.mark.parametrize(
    ("phase", "reply", "calls"),
    [
        ("hourly", None, []),
        ("hourly", {"due": True, "values": [1, 2]}, []),
        ("network", [1, 2, 3], ["disk"]),
        ("workers", {"due": True, "rows": [[4000, "rig", 1, 2]]}, ["disk", "network"]),
    ],
)
async def test_invalid_plan_is_rejected_before_corresponding_write(phase, reply, calls):
    service, state = _service()
    events = []
    state.add_disk_growth.side_effect = lambda *_args, **_kwargs: events.append("disk")
    state.add_network_history.side_effect = lambda *_args, **_kwargs: events.append("network")
    state.add_worker_history.side_effect = lambda *_args, **_kwargs: events.append("workers")
    native = service._telemetry_plan
    service._telemetry_plan = lambda current, args: (
        reply if current == phase else native(current, args)
    )
    with pytest.raises(RuntimeError, match="invalid"):
        await _capture(service, workers=[{"name": "rig", "status": "online"}])
    assert events == calls


async def test_large_fleet_uses_one_native_call_per_phase_and_projects_fields(monkeypatch):
    service, state = _service()
    calls = []
    native_call = go_polling.go_channel.call

    def counted(helper, payload):
        calls.append((helper, payload["operation"], payload["args"]))
        return native_call(helper, payload)

    monkeypatch.setattr(go_polling.go_channel, "call", counted)
    opaque = object()
    workers = [
        {
            "name": f"rig-{index}",
            "status": "online",
            "h15": index,
            "accepted": index + 1,
            "rejected": index + 2,
            "opaque": opaque,
        }
        for index in range(1000)
    ]
    await _capture(
        service,
        monero={"db_size": 1, "opaque": opaque},
        disk={"used_gb": 2, "total_gb": 3, "opaque": opaque},
        network={"difficulty": 4, "height": 5, "reward": 6, "opaque": opaque},
        pool={"hashrate": 7, "opaque": opaque},
        workers=workers,
    )
    assert [operation for _helper, operation, _args in calls] == [
        "poll_telemetry_hourly",
        "poll_telemetry_network",
        "poll_telemetry_worker_due",
        "poll_telemetry_workers",
    ]
    assert len(state.add_worker_history.call_args.args[0]) == 1000
    assert calls[0][2][3:] == [{"db_size": 1}, {"used_gb": 2, "total_gb": 3}]
    assert calls[1][2] == [
        {"difficulty": 4, "height": 5, "reward": 6},
        {"hashrate": 7},
    ]
    assert calls[2][2] == [4000.0, 0.0, 300]
    worker_args = calls[3][2]
    assert len(worker_args[3]) == 1000
    assert all(
        set(worker).issubset({"status", "name", "h15", "accepted", "rejected"})
        and "opaque" not in worker
        for worker in worker_args[3]
    )
    assert opaque not in worker_args[3]
