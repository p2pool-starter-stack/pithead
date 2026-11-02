import os

import pytest
import pytest_asyncio
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard import go_channel, go_worker_http
from mining_dashboard.config import config
from mining_dashboard.go_control_http import _NativeFailure
from mining_dashboard.service import control_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web import server

# ruff: noqa: S101

pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"),
]

HEADERS = {"X-Pithead-Control": "1", "X-Auth-User": "operator"}


@pytest_asyncio.fixture
async def worker_client(monkeypatch):
    go_worker_http.install(server)
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", True)
    state = StateManager(db_path=":memory:")
    client = TestClient(TestServer(server.create_app(state, {"workers": []})))
    await client.start_server()
    yield client
    await client.close()
    state.close()


async def test_native_detail_completion_failure_propagates(monkeypatch, worker_client):
    native_call = go_channel.call

    def unavailable(helper, payload):
        if helper == "control-http" and payload.get("operation") == "complete":
            raise RuntimeError("native helper unavailable")
        return native_call(helper, payload)

    monkeypatch.setattr(go_channel, "call", unavailable)
    monkeypatch.setattr(server, "build_worker_detail", lambda *args: {"found": True})
    response = await worker_client.get("/api/worker?name=rig")
    assert response.status == 500
    assert "Server got itself in trouble" in await response.text()


async def test_ordinary_detail_failure_stays_curated(monkeypatch, worker_client):
    def fail(*args):
        raise OSError("private detail")

    monkeypatch.setattr(server, "build_worker_detail", fail)
    response = await worker_client.get("/api/worker?name=rig")
    assert response.status == 500
    assert await response.json() == {"error": "Failed to build worker detail."}


@pytest.mark.parametrize(
    ("failure", "body"),
    [
        (_NativeFailure("native submit"), None),
        (OSError("private submit"), {"error": "Failed to submit the worker config change."}),
    ],
)
async def test_apply_submit_failure_boundary(monkeypatch, worker_client, failure, body):
    monkeypatch.setattr(control_service, "validate_worker_changes", lambda changes: None)

    def fail(*args):
        raise failure

    monkeypatch.setattr(control_service, "submit_worker_apply", fail)
    response = await worker_client.post(
        "/api/control/worker-apply",
        json={"worker": "rig", "changes": {"DONATION": 1}},
        headers=HEADERS,
    )
    assert response.status == 500
    if body is None:
        assert "Server got itself in trouble" in await response.text()
    else:
        assert await response.json() == body


async def test_native_upgrade_submit_failure_propagates(monkeypatch, worker_client):
    def fail(*args):
        raise _NativeFailure("native submit")

    monkeypatch.setattr(control_service, "submit_worker_upgrade", fail)
    response = await worker_client.post(
        "/api/control/worker-upgrade",
        json={"worker": "rig", "version": "v1.2.3"},
        headers=HEADERS,
    )
    assert response.status == 500
    assert "Server got itself in trouble" in await response.text()


async def test_native_background_predicate_failure_propagates(monkeypatch):
    native_call = go_channel.call

    def unavailable(helper, payload):
        if helper == "control-http" and payload.get("operation") == "worker-done":
            raise RuntimeError("native helper unavailable")
        return native_call(helper, payload)

    async def wait_result(rid, done, timeout_s):
        done({"status": "running"})

    monkeypatch.setattr(go_channel, "call", unavailable)
    monkeypatch.setattr(control_service, "wait_result", wait_result)
    with pytest.raises(_NativeFailure):
        await server._finalize_worker_upgrade(object(), "rig", "v1.2.3", "rid")


async def test_ordinary_background_wait_failure_is_swallowed(monkeypatch):
    async def wait_result(rid, done, timeout_s):
        done([])

    monkeypatch.setattr(control_service, "wait_result", wait_result)
    assert await server._finalize_worker_upgrade(object(), "rig", "v1.2.3", "rid") is None


async def test_nonrecordable_result_uses_native_ready_path():
    class State:
        def add_worker_config_version(self, *args, **kwargs):
            raise AssertionError("nonrecordable result was stored")

    assert server._record_worker_result(State(), "rig", {}, {"status": "running"}) is None


@pytest.mark.parametrize("operation", ["worker-name", "header"])
async def test_response_plan_cannot_continue_to_worker_submit(
    monkeypatch, worker_client, operation
):
    native_call = go_channel.call
    calls = []

    def malformed(helper, payload):
        if helper == "control-http" and payload.get("operation") == operation:
            return {"status": 500, "body": ["dict", []], "next": "ready"}
        return native_call(helper, payload)

    async def wait_result(*args, **kwargs):
        return None

    monkeypatch.setattr(go_channel, "call", malformed)
    monkeypatch.setattr(control_service, "validate_worker_changes", lambda changes: None)
    monkeypatch.setattr(control_service, "submit_worker_apply", lambda *args: calls.append(args))
    monkeypatch.setattr(control_service, "wait_result", wait_result)
    response = await worker_client.post(
        "/api/control/worker-apply",
        json={"worker": "rig", "changes": {"DONATION": 1}},
        headers=HEADERS,
    )
    assert response.status == 500
    assert "Server got itself in trouble" in await response.text()
    assert calls == []


async def test_response_plan_cannot_continue_to_history_record(monkeypatch):
    monkeypatch.setattr(
        go_channel,
        "call",
        lambda *args: {"status": 500, "body": ["dict", []], "next": "record"},
    )
    with pytest.raises(_NativeFailure, match="cannot continue"):
        server._record_worker_result(object(), "rig", {}, {"status": "applied"})
