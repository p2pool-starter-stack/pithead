import asyncio
import json
import os
import threading
from types import SimpleNamespace

import pytest

from mining_dashboard import go_bridge, go_state
from mining_dashboard.go_state_executor import StateExecutor

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


class Request:
    def __init__(self, prepared, app=None):
        self.prepared = prepared
        self.query = {}
        self.app = app or {}

    def clone(self, **_kwargs):
        return self

    async def json(self):
        return self.prepared


def valid_pairs():
    pairs = [[key, {"ref": 0}] for key in go_state.STATE_KEYS]
    set_pair(pairs, "page_title", "Pithead Dashboard")
    set_pair(pairs, "tari_gates_sync", False)
    set_pair(pairs, "window", None)
    return pairs


def set_pair(pairs, key, value):
    pair = next(pair for pair in pairs if pair[0] == key)
    pair[1] = value


def drop_pair(pairs):
    pairs.pop()


def replace_with_extra(pairs):
    pairs[0] = ["extra", pairs[0][1]]


def set_invalid_ref(pairs, value):
    set_pair(pairs, "host_ip", {"ref": value})


@pytest.mark.parametrize(
    "mutate",
    [
        drop_pair,
        replace_with_extra,
        lambda pairs: set_invalid_ref(pairs, True),
        lambda pairs: set_invalid_ref(pairs, 1),
        lambda pairs: set_pair(pairs, "page_title", "evil"),
        lambda pairs: set_pair(pairs, "window", {"from": {"ref": 0}}),
        lambda pairs: set_pair(pairs, "tari_gates_sync", 1),
    ],
)
def test_malformed_native_output_is_fatal(monkeypatch, mutate):
    pairs = valid_pairs()
    mutate(pairs)
    monkeypatch.setattr(go_state.go_channel, "call", lambda *_args, **_kwargs: pairs)
    with pytest.raises(RuntimeError, match="native state returned"):
        go_state._assemble(
            [object()],
            {},
            syncing=False,
            tari_required=False,
            monero_only=False,
            stratum=[],
            window=None,
        )


def test_native_output_retains_stratum_key_multiplicity(monkeypatch):
    pairs = valid_pairs() + [["version", {"ref": 0}]]
    monkeypatch.setattr(go_state.go_channel, "call", lambda *_args, **_kwargs: pairs)
    with pytest.raises(RuntimeError, match="native state returned incomplete fields"):
        go_state._assemble(
            [object()],
            {},
            syncing=False,
            tari_required=False,
            monero_only=False,
            stratum=[["new_key", 0]],
            window=None,
        )


@pytest.mark.parametrize("ok", [1, "false", None])
def test_channel_response_rejects_non_boolean_ok(ok):
    output = json.dumps({"ok": ok, "value": {}})
    with pytest.raises(RuntimeError, match="native state helper returned invalid data"):
        go_state.go_channel.response("state", output)


def prepared():
    return {
        "latest_data": {},
        "history": [],
        "metrics": {},
        "sections": {},
        "snapshot": {"storage": {}, "settings": {}},
    }


@pytest.mark.asyncio
async def test_native_builder_runs_off_loop(monkeypatch):
    loop_thread = threading.get_ident()
    called = []

    def native(*_args, **_kwargs):
        called.append(threading.get_ident())
        return {"thread": called[-1]}

    monkeypatch.setattr(go_bridge.go_domain, "restore", lambda _value: SimpleNamespace())
    monkeypatch.setattr(go_state, "build_state", native)
    monkeypatch.setattr(go_bridge.server, "build_state", native)
    executor = StateExecutor()
    try:
        result = await go_bridge._finish_state(Request(prepared(), {"go_state_executor": executor}))
    finally:
        await executor.close()
    assert called and called[0] != loop_thread
    assert result["state"] == {"thread": called[0]}


@pytest.mark.asyncio
async def test_explicit_builder_interposition_stays_on_loop(monkeypatch):
    loop_thread = threading.get_ident()
    called = []

    def native(*_args, **_kwargs):
        raise AssertionError("native builder used")

    def explicit(*_args, **_kwargs):
        called.append(threading.get_ident())
        return {"thread": called[-1]}

    monkeypatch.setattr(go_bridge.go_domain, "restore", lambda _value: SimpleNamespace())
    monkeypatch.setattr(go_state, "build_state", native)
    monkeypatch.setattr(go_bridge.server, "build_state", explicit)
    result = await go_bridge._finish_state(Request(prepared()))
    assert called == [loop_thread]
    assert result["state"] == {"thread": loop_thread}


@pytest.mark.asyncio
async def test_cancelled_assemblies_hold_capacity_until_workers_finish():
    executor = StateExecutor()
    started = threading.Event()
    released = threading.Event()
    finished = threading.Event()
    lock = threading.Lock()
    counts = {"started": 0, "finished": 0}
    tasks = []
    close_task = None
    running = None
    closing_released = threading.Event()

    def blocked():
        with lock:
            counts["started"] += 1
            if counts["started"] == 4:
                started.set()
        try:
            assert released.wait(5)
        finally:
            with lock:
                counts["finished"] += 1
                if counts["finished"] == 4:
                    finished.set()

    try:
        tasks = [asyncio.create_task(executor.run(blocked)) for _ in range(4)]
        assert await asyncio.to_thread(started.wait, 5)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        with pytest.raises(RuntimeError, match="native state assembly busy"):
            await executor.run(lambda: None)

        released.set()
        assert await asyncio.to_thread(finished.wait, 5)
        deadline = asyncio.get_running_loop().time() + 5
        while True:
            try:
                ready = await executor.run(lambda: "ready")
                break
            except RuntimeError as error:
                if (
                    str(error) != "native state assembly busy"
                    or asyncio.get_running_loop().time() >= deadline
                ):
                    raise
                await asyncio.sleep(0)
        assert ready == "ready"

        closing_started = threading.Event()

        def closing_blocked():
            closing_started.set()
            assert closing_released.wait(5)
            return "closed"

        running = asyncio.create_task(executor.run(closing_blocked))
        assert await asyncio.to_thread(closing_started.wait, 5)
        close_task = asyncio.create_task(executor.close())
        await asyncio.sleep(0)
        assert not close_task.done()
        closing_released.set()
        assert await running == "closed"
        await close_task
    finally:
        released.set()
        closing_released.set()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if running is not None:
            await asyncio.gather(running, return_exceptions=True)
        if close_task is not None:
            await asyncio.gather(close_task, return_exceptions=True)
        else:
            await executor.close()
