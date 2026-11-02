import asyncio
import threading
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from mining_dashboard import go_polling
from mining_dashboard.service.data_helpers import WorkerLifecycle
from mining_dashboard.service.worker_probe import WorkerProber

# ruff: noqa: S101


def _worker():
    return {"name": "rig", "ip": "192.0.2.1", "status": "online", "uptime": 0}


def test_early_imported_earnings_aliases_are_native():
    import dashboard_earnings_plugin

    from mining_dashboard.service.notify import telegram_commands, telegram_formatters

    for name in ("xmr_per_hs_day", "xtm_per_hs_day"):
        assert getattr(telegram_formatters, name) is dashboard_earnings_plugin.NATIVES[name]
    assert (
        telegram_commands.confirmed_payouts_summary
        is dashboard_earnings_plugin.NATIVES["confirmed_payouts_summary"]
    )


@pytest.mark.parametrize("plan", [None, [], ["true"], [1], {}])
@pytest.mark.asyncio
async def test_probe_invalid_plan_performs_no_network_call(monkeypatch, plan):
    monkeypatch.setattr(go_polling, "_run", lambda *args, **kwargs: plan)
    client = SimpleNamespace(get_stats=AsyncMock())
    with pytest.raises(RuntimeError, match="invalid plan"):
        await WorkerProber().probe(client, [_worker()])
    client.get_stats.assert_not_called()


@pytest.mark.parametrize(
    "reply",
    [None, {}, {"result_indices": [None], "answered": []}, {"result_indices": [1], "answered": []}],
)
@pytest.mark.asyncio
async def test_probe_rejects_bad_completion_without_replacing_answered(monkeypatch, reply):
    monkeypatch.setattr(
        go_polling,
        "_run",
        lambda operation, args: [True] if operation == "probe_plan" else reply,
    )
    prober = WorkerProber()
    original = prober._answered = {("prior", "192.0.2.2")}
    with pytest.raises(RuntimeError):
        await prober.probe(SimpleNamespace(get_stats=AsyncMock(return_value={})), [_worker()])
    assert prober._answered is original


@pytest.mark.asyncio
async def test_probe_helpers_run_off_loop_and_keep_result_identity(monkeypatch):
    caller = threading.get_ident()
    threads = []
    response = {"api_ok": True}

    def native(operation, args):
        threads.append(threading.get_ident())
        if operation == "probe_plan":
            return [True]
        assert args[2][0] is response
        return {"result_indices": [0], "answered": [["rig", "192.0.2.1"]]}

    async def fetch(ip, name):
        assert (ip, name) == ("192.0.2.1", "rig")
        assert threading.get_ident() == caller
        await asyncio.sleep(0)
        return response

    monkeypatch.setattr(go_polling, "_run", native)
    prober = WorkerProber()
    result = await prober.probe(SimpleNamespace(get_stats=fetch), [_worker()])
    assert len(threads) == 2 and all(thread != caller for thread in threads)
    assert result[0] is response
    assert prober._answered == {("rig", "192.0.2.1")}


@pytest.mark.asyncio
async def test_probe_fetch_failure_keeps_previous_answered(monkeypatch):
    operations = []

    def native(operation, _args):
        operations.append(operation)
        return [True]

    monkeypatch.setattr(go_polling, "_run", native)
    prober = WorkerProber()
    original = prober._answered = {("rig", "192.0.2.1")}
    with pytest.raises(OSError):
        await prober.probe(
            SimpleNamespace(get_stats=AsyncMock(side_effect=OSError("failed"))), [_worker()]
        )
    assert operations == ["probe_plan"]
    assert prober._answered is original


@pytest.mark.asyncio
async def test_probe_freezes_target_before_awaiting_native_plan(monkeypatch):
    started = threading.Event()
    proceed = threading.Event()
    worker = _worker()

    def native(operation, args):
        if operation == "probe_plan":
            started.set()
            if not proceed.wait(5):
                raise RuntimeError("plan did not resume")
            assert args[0] == [{"name": "rig", "ip": "192.0.2.1", "status": "online"}]
            return [True]
        return {"result_indices": [0], "answered": [["rig", "192.0.2.1"]]}

    monkeypatch.setattr(go_polling, "_run", native)
    client = SimpleNamespace(get_stats=AsyncMock(return_value={"api_ok": True}))
    prober = WorkerProber()
    task = asyncio.create_task(prober.probe(client, [worker]))
    try:
        assert await asyncio.to_thread(started.wait, 5)
        worker.update(name="changed", ip="192.0.2.2", status="offline")
    finally:
        proceed.set()
    await task
    client.get_stats.assert_awaited_once_with("192.0.2.1", "rig")
    assert prober._answered == {("rig", "192.0.2.1")}


@pytest.mark.parametrize(
    "records",
    [
        [["rig", {"connected_since": 50, "last_active": 100}], ["bad", {}]],
        [[[], {"connected_since": 50, "last_active": 100}]],
        [["rig", {"connected_since": 50, "last_active": 100}]] * 2,
    ],
)
def test_bad_lifecycle_reply_does_not_partially_mutate(monkeypatch, records):
    lifecycle = WorkerLifecycle(100)
    original = lifecycle._state = {"rig": {"connected_since": 0, "last_active": 0}}
    worker = _worker()
    monkeypatch.setattr(
        go_polling,
        "_run",
        lambda *args, **kwargs: {
            "patches": [{"uptime": 100}],
            "live_indices": [0],
            "state": records,
        },
    )
    with pytest.raises(RuntimeError):
        lifecycle.update([worker], 100)
    assert lifecycle._state is original
    assert original == {"rig": {"connected_since": 0, "last_active": 0}}
    assert worker["uptime"] == 0


def test_native_transport_failure_does_not_run_reference(monkeypatch):
    def fail(*_args, **_kwargs):
        raise RuntimeError("native unavailable")

    monkeypatch.setattr(go_polling.go_channel, "call", fail)
    with pytest.raises(RuntimeError, match="native unavailable"):
        go_polling._normalize_proxy_workers({"workers": []})
