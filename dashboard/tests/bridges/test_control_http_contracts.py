import json
import math
from types import SimpleNamespace

import pytest
from aiohttp import web

from mining_dashboard import go_control_http


class Request:
    def __init__(self, body=None, *, headers=None, query=None, app=None, failure=None):
        self.body = body
        self.headers = headers or {}
        self.query = query or {}
        self.app = app or {}
        self.failure = failure

    async def json(self, **kwargs):
        if self.failure:
            raise self.failure
        return self.body


def body(response):
    return json.loads(response.body)


def test_plan_projects_values_and_restores_identity(monkeypatch):
    captured = []
    marker = float("nan")

    def call(helper, payload):
        captured.append((helper, payload))
        encoded = payload["value"]
        return {"next": "ready", "value": encoded}

    monkeypatch.setattr(go_control_http.go_channel, "call", call)
    result = go_control_http._plan("phase", route="route", error="error", value=marker)
    assert result["value"] is marker
    assert math.isnan(result["value"])
    assert captured[0][0] == "control-http"
    assert captured[0][1]["route"] == "route"


@pytest.mark.parametrize("reply", [None, [], "bad"])
def test_plan_rejects_non_mapping(monkeypatch, reply):
    monkeypatch.setattr(go_control_http.go_channel, "call", lambda *args: reply)
    with pytest.raises(
        go_control_http._NativeFailure, match="invalid native control HTTP response"
    ):
        go_control_http._plan("phase")


def test_plan_wraps_transport_and_value_failures(monkeypatch):
    monkeypatch.setattr(
        go_control_http.go_channel,
        "call",
        lambda *args: (_ for _ in ()).throw(RuntimeError("transport")),
    )
    with pytest.raises(go_control_http._NativeFailure, match="transport"):
        go_control_http._plan("phase")
    monkeypatch.setattr(
        go_control_http.go_channel,
        "call",
        lambda *args: {"next": "ready", "value": ["ref", 99]},
    )
    with pytest.raises(go_control_http._NativeFailure, match="invalid native control HTTP value"):
        go_control_http._plan("phase")


@pytest.mark.parametrize(
    ("operation", "plan", "message"),
    [
        ("phase", {"status": 201, "body": {}}, "status"),
        ("phase", {"status": 200, "next": "ready", "body": {}}, "cannot continue"),
        ("phase", {"status": 200, "body": {}, "text": "x"}, "body"),
        ("phase", {"status": 200, "text": "x"}, "text status"),
        ("phase", {"status": 400, "body": {}}, "JSON status"),
        ("complete", {"next": "ready"}, "missing"),
        ("approval", {"value": {}, "next": "approval"}, "approval"),
        ("request", {"next": "ready", "action": "x"}, "action"),
        ("done", {"done": 1}, "predicate"),
        ("phase", {"next": None}, "phase"),
    ],
)
def test_validate_plan_rejects_malformed_shapes(operation, plan, message):
    with pytest.raises(go_control_http._NativeFailure, match=message):
        go_control_http._validate_plan(operation, plan)


def test_reply_and_check_contracts():
    response = go_control_http._reply({"status": 202, "body": {"ok": True}})
    assert response.status == 202
    assert body(response) == {"ok": True}
    with pytest.raises(web.HTTPBadRequest) as raised:
        go_control_http._reply({"status": 400, "text": "bad"})
    assert raised.value.text == "bad"
    assert go_control_http._check({"next": "ready"}) == {"next": "ready"}
    with pytest.raises(go_control_http._NativeFailure, match="phase"):
        go_control_http._check({"next": "wrong"})
    with pytest.raises(web.HTTPForbidden):
        go_control_http._check({"status": 403, "text": "denied"})


def test_control_header_projects_configured_header(monkeypatch):
    from mining_dashboard.web import server

    captured = []
    monkeypatch.setattr(
        go_control_http,
        "_plan",
        lambda operation, **values: captured.append((operation, values)) or {"next": "ready"},
    )
    go_control_http._require_control_header(Request(headers={server.CONTROL_HEADER: "expected"}))
    assert captured == [("header", {"value": "expected"})]


async def test_config_request_and_approval_contracts(monkeypatch):
    calls = []

    def plan(operation, **values):
        calls.append((operation, values))
        if operation == "request-body":
            return {"next": "placeholders"}
        if operation == "approval":
            return {"next": "approval", "value": {"payout_suffixes": {}}}
        return {"status": 400, "text": "invalid JSON"}

    monkeypatch.setattr(go_control_http, "_plan", plan)
    from mining_dashboard.config import documents

    rejected = []
    monkeypatch.setattr(documents, "reject_placeholders", lambda value: rejected.append(value))
    value = await go_control_http.config_request(Request({"config": {"ok": True}}))
    assert value == {"config": {"ok": True}}
    assert rejected == [{"ok": True}]
    approval = go_control_http.approval_envelope(
        {"approve": True, "payout_suffixes": {"monero": "1234"}}
    )
    assert approval["payout_suffixes"] == {"monero": "1234"}
    with pytest.raises(web.HTTPBadRequest):
        await go_control_http.config_request(Request(failure=ValueError("bad")))


async def test_config_request_rejects_native_bad_phase(monkeypatch):
    monkeypatch.setattr(go_control_http, "_plan", lambda *args, **kwargs: {"next": "wrong"})
    with pytest.raises(go_control_http._NativeFailure, match="body phase"):
        await go_control_http.config_request(Request({"config": {}}))


def planner(operation, *, route="", error="", **values):
    if operation in {"header", "proposed", "version"}:
        return {"next": "ready"}
    if operation == "validation":
        return {"next": "existing" if route == "fleet" else "ready"}
    if operation == "request":
        return {"next": "submit", "action": route or "commit"}
    if operation == "os-action":
        return {"next": "ready", "action": f"os-{values['value']}"}
    if operation == "done":
        return {"done": values["value"] == "applied"}
    if operation == "complete":
        return {
            "status": 202 if route in {"preview", "upgrade", "os-update", "backup"} else 200,
            "body": {"route": route, **values},
        }
    if operation == "error":
        if error in {"json", "uuid"}:
            return {"status": 400, "text": "invalid id"}
        return {"status": 500, "body": {"error": error, "route": route}}
    raise AssertionError(operation)


async def test_control_handlers_preserve_submit_and_wait_order(monkeypatch):
    from mining_dashboard.web import server

    events = []
    monkeypatch.setattr(go_control_http, "_plan", planner)
    monkeypatch.setattr(server, "_require_control_header", lambda request: events.append("header"))
    monkeypatch.setattr(server, "config_request", lambda request: async_value({"config": {"x": 1}}))
    monkeypatch.setattr(server, "approval_envelope", lambda value: {"approved": True})
    monkeypatch.setattr(server.worker_adopt, "validate_fleet_api_port", lambda value: None)
    monkeypatch.setattr(server.worker_adopt, "validate_new_worker_entries", lambda *args: None)
    monkeypatch.setattr(server.control_service, "read_config", lambda: {"live": True})

    def submit(action, *args, **kwargs):
        events.append(("submit", action, args, kwargs))
        return f"rid-{action}"

    async def wait(rid, **kwargs):
        events.append(("wait", rid, sorted(kwargs)))
        if "done" in kwargs:
            assert kwargs["done"]({"status": "applied"}) is True
        return {"status": "applied"}

    monkeypatch.setattr(server.control_service, "submit", submit)
    monkeypatch.setattr(server.control_service, "wait_result", wait)
    headers = {"X-Auth-User": "operator"}
    preview = await go_control_http.handle_control_preview(Request(headers=headers))
    commit = await go_control_http.handle_control_commit(
        Request(headers=headers, body={"id": "intent", "confirm": "APPLY"})
    )
    upgrade = await go_control_http.handle_control_upgrade(
        Request({"version": "v1.2.3"}, headers=headers)
    )
    os_update = await go_control_http.handle_control_os_update(
        Request({"action": "check", "version": "v1.2.3"}, headers=headers)
    )
    backup = await go_control_http.handle_control_backup(Request(headers=headers))
    assert [value.status for value in (preview, commit, upgrade, os_update, backup)] == [
        202,
        200,
        202,
        202,
        202,
    ]
    assert [event[0] for event in events if isinstance(event, tuple)] == [
        "submit",
        "wait",
        "submit",
        "wait",
        "submit",
        "submit",
        "submit",
    ]


async def test_config_and_result_handlers(monkeypatch):
    from mining_dashboard.web import server

    monkeypatch.setattr(go_control_http, "_plan", planner)
    monkeypatch.setattr(server.control_service, "read_config", lambda: {"config": True})
    assert body(await go_control_http.handle_config(Request()))["value"] == {"config": True}
    monkeypatch.setattr(server.control_service, "result", lambda rid: {"id": rid})
    assert body(await go_control_http.handle_control_result(Request(query={"id": "rid"})))[
        "value"
    ] == {"id": "rid"}
    monkeypatch.setattr(
        server.control_service, "result", lambda rid: (_ for _ in ()).throw(ValueError("bad"))
    )
    with pytest.raises(web.HTTPBadRequest):
        await go_control_http.handle_control_result(Request(query={"id": "bad"}))


async def test_config_generic_failure_is_sanitized(monkeypatch):
    from mining_dashboard.web import server

    monkeypatch.setattr(go_control_http, "_plan", planner)
    monkeypatch.setattr(
        server.control_service,
        "read_config",
        lambda: (_ for _ in ()).throw(RuntimeError("private")),
    )
    response = await go_control_http.handle_config(Request())
    assert response.status == 500
    assert body(response) == {"error": "config-read", "route": ""}


@pytest.mark.parametrize(
    ("handler", "case"),
    [
        (go_control_http.handle_control_preview, Request(headers={"X-Auth-User": "op"})),
        (go_control_http.handle_control_upgrade, Request({"version": "v1"})),
        (go_control_http.handle_control_os_update, Request({"action": "check", "version": "v1"})),
        (go_control_http.handle_control_backup, Request()),
    ],
)
async def test_submit_failures_are_sanitized(monkeypatch, handler, case):
    from mining_dashboard.web import server

    monkeypatch.setattr(go_control_http, "_plan", planner)
    monkeypatch.setattr(server, "_require_control_header", lambda value: None)
    monkeypatch.setattr(server, "config_request", lambda value: async_value({"config": {}}))
    monkeypatch.setattr(server.worker_adopt, "validate_fleet_api_port", lambda value: None)
    monkeypatch.setattr(server.worker_adopt, "validate_new_worker_entries", lambda *args: None)
    monkeypatch.setattr(server.control_service, "read_config", lambda: {})
    monkeypatch.setattr(
        server.control_service,
        "submit",
        lambda *args, **kwargs: (_ for _ in ()).throw(OSError("private")),
    )
    response = await handler(case)
    assert response.status == 500
    assert b"private" not in response.body


@pytest.mark.parametrize(
    "handler",
    [go_control_http.handle_control_upgrade, go_control_http.handle_control_os_update],
)
async def test_plain_json_failures_use_native_error(monkeypatch, handler):
    from mining_dashboard.web import server

    monkeypatch.setattr(go_control_http, "_plan", planner)
    monkeypatch.setattr(server, "_require_control_header", lambda value: None)
    with pytest.raises(web.HTTPBadRequest):
        await handler(Request(failure=ValueError("bad")))


def test_install_replaces_server_and_config_commit(monkeypatch):
    from mining_dashboard import go_worker_http
    from mining_dashboard.web import config_commit

    names = (
        "_require_control_header",
        "handle_config",
        "handle_control_preview",
        "handle_control_commit",
        "handle_control_upgrade",
        "handle_control_os_update",
        "handle_control_backup",
        "handle_control_result",
        "config_request",
        "approval_envelope",
    )
    fake = SimpleNamespace(**{name: object() for name in names})
    called = []
    monkeypatch.setattr(go_worker_http, "install", lambda server: called.append(server))
    go_control_http.install(fake)
    assert fake.handle_config is go_control_http.handle_config
    assert config_commit.config_request is go_control_http.config_request
    assert called == [fake]


async def async_value(value):
    return value
