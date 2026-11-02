import os

import pytest
import pytest_asyncio
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard import go_channel, go_control_http
from mining_dashboard.config import config
from mining_dashboard.service import control_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web import server

# ruff: noqa: S101

pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"),
]

HEADERS = {"X-Pithead-Control": "1", "X-Auth-User": "operator"}
RID = "00000000-0000-0000-0000-000000000006"


@pytest_asyncio.fixture
async def control_client(monkeypatch):
    go_control_http.install(server)
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(control_service, "read_config", lambda: {})
    state = StateManager(db_path=":memory:")
    client = TestClient(TestServer(server.create_app(state, {"workers": []})))
    await client.start_server()
    yield client
    await client.close()
    state.close()


@pytest.mark.parametrize(
    ("operation", "path", "body"),
    [
        ("request-body", "/api/control/preview", {"config": {}}),
        ("approval", "/api/control/commit", {"id": RID, "approve": True}),
        ("request", "/api/control/preview", {"config": {}}),
    ],
)
async def test_native_policy_failure_is_not_reclassified_as_bad_input(
    monkeypatch, control_client, operation, path, body
):
    calls = []
    native_call = go_channel.call

    def unavailable(helper, payload):
        if helper == "control-http" and payload.get("operation") == operation:
            raise RuntimeError("native helper unavailable")
        return native_call(helper, payload)

    def submit(*args, **kwargs):
        calls.append([args, kwargs])
        return RID

    monkeypatch.setattr(go_channel, "call", unavailable)
    monkeypatch.setattr(control_service, "submit", submit)
    response = await control_client.post(path, json=body, headers=HEADERS)
    text = await response.text()
    assert response.status == 500
    assert "Server got itself in trouble" in text
    assert "Body must be JSON" not in text
    assert "valid intent" not in text
    assert "Failed to submit" not in text
    assert calls == []


async def test_invalid_native_phase_fails_closed(monkeypatch, control_client):
    calls = []
    native_call = go_channel.call

    def invalid(helper, payload):
        if helper == "control-http" and payload.get("operation") == "request-body":
            return {"next": "unexpected"}
        return native_call(helper, payload)

    def submit(*args, **kwargs):
        calls.append([args, kwargs])
        return RID

    monkeypatch.setattr(go_channel, "call", invalid)
    monkeypatch.setattr(control_service, "submit", submit)
    response = await control_client.post(
        "/api/control/preview", json={"config": {}}, headers=HEADERS
    )
    text = await response.text()
    assert response.status == 500
    assert "Server got itself in trouble" in text
    assert "Body must be JSON" not in text
    assert calls == []


@pytest.mark.parametrize(
    ("operation", "route", "native_result", "method", "path", "body"),
    [
        ("complete", "config", {}, "get", "/api/config", None),
        (
            "request",
            "preview",
            {"next": "submit"},
            "post",
            "/api/control/preview",
            {"config": {}},
        ),
        (
            "approval",
            "",
            {"next": "approval", "value": ["list", []]},
            "post",
            "/api/control/commit",
            {"id": RID, "approve": True},
        ),
    ],
)
async def test_malformed_native_envelope_is_not_reclassified(
    monkeypatch, control_client, operation, route, native_result, method, path, body
):
    calls = []
    native_call = go_channel.call

    def malformed(helper, payload):
        if (
            helper == "control-http"
            and payload.get("operation") == operation
            and payload.get("route", "") == route
        ):
            return native_result
        return native_call(helper, payload)

    def submit(*args, **kwargs):
        calls.append([args, kwargs])
        return RID

    monkeypatch.setattr(go_channel, "call", malformed)
    monkeypatch.setattr(control_service, "submit", submit)
    kwargs = {"headers": HEADERS}
    if body is not None:
        kwargs["json"] = body
    response = await getattr(control_client, method)(path, **kwargs)
    text = await response.text()
    assert response.status == 500
    assert "Server got itself in trouble" in text
    assert "Body must be JSON" not in text
    assert "valid intent" not in text
    assert "Failed to submit" not in text
    assert "Failed to read the stack config" not in text
    assert calls == []
