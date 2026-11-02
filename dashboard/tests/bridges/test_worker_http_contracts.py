import json
from types import SimpleNamespace

import pytest

from mining_dashboard import go_worker_http
from mining_dashboard.go_control_http import _NativeFailure


class Request:
    def __init__(self, body=None, *, headers=None, query=None, app=None, failure=None):
        self.body = body
        self.headers = headers or {}
        self.query = query or {}
        self.app = app or {}
        self.failure = failure

    async def json(self):
        if self.failure:
            raise self.failure
        return self.body


def body(response):
    return json.loads(response.body)


def test_value_done_and_record_contracts(monkeypatch):
    plans = {
        "worker-live": {"next": "ready", "value": {"version": "v1"}},
        "worker-done": {"done": True},
        "worker-record": {
            "next": "record",
            "value": {"change_id": "cid", "status": "applied", "reason": "ok"},
        },
    }
    monkeypatch.setattr(go_worker_http, "_plan", lambda operation, **values: plans[operation])
    assert go_worker_http._value("worker-live") == {"version": "v1"}
    assert go_worker_http._done({"status": "applied"}) is True
    calls = []
    state = SimpleNamespace(
        add_worker_config_version=lambda *args, **kwargs: calls.append((args, kwargs))
    )
    go_worker_http._record_worker_result(state, "rig", {"x": 1}, {"status": "applied"})
    assert calls[0][0][:5] == ("rig", "cid", "applied", {"x": 1}, "ok")


@pytest.mark.parametrize(
    "plan",
    [
        {"next": "ready"},
        {"next": "record"},
        {"next": "record", "value": {}},
    ],
)
def test_record_rejects_incomplete_plans(monkeypatch, plan):
    monkeypatch.setattr(go_worker_http, "_plan", lambda *args, **kwargs: plan)
    state = SimpleNamespace(add_worker_config_version=lambda *args, **kwargs: None)
    if plan == {"next": "ready"}:
        assert go_worker_http._record_worker_result(state, "rig", {}, {}) is None
    else:
        with pytest.raises(_NativeFailure):
            go_worker_http._record_worker_result(state, "rig", {}, {})


def test_value_and_done_reject_malformed_plans(monkeypatch):
    monkeypatch.setattr(go_worker_http, "_plan", lambda *args, **kwargs: {"next": "ready"})
    with pytest.raises(_NativeFailure, match="missing"):
        go_worker_http._value("worker-live")
    monkeypatch.setattr(go_worker_http, "_plan", lambda *args, **kwargs: {"done": "yes"})
    with pytest.raises(_NativeFailure, match="predicate"):
        go_worker_http._done({"status": "running"})


def planner(operation, *, route="", error="", **values):
    if operation in {"worker-detail-name", "worker-name", "version", "validation"}:
        return {"next": "ready"}
    if operation == "worker-strip":
        return {"next": "ready", "value": values["value"]}
    if operation == "worker-live":
        return {"next": "ready", "value": values["value"].get("rigforge", {})}
    if operation == "worker-noop":
        return {"next": "ready"}
    if operation == "worker-done":
        return {"done": values["value"] in {"applied", "accepted", "failed"}}
    if operation == "worker-record":
        value = values["value"]
        return {
            "next": "record",
            "value": {
                "change_id": value.get("change_id"),
                "status": value["status"],
                "reason": value.get("reason"),
            },
        }
    if operation == "complete":
        return {
            "status": 202 if values.get("value") is None else 200,
            "body": {"route": route, **values},
        }
    if operation == "error":
        if error == "json":
            return {"status": 400, "text": "invalid JSON"}
        return {"status": 500, "body": {"error": error, "route": route}}
    raise AssertionError(operation)


async def test_worker_detail_reference_provider_and_error(monkeypatch):
    from mining_dashboard.web import server

    monkeypatch.setattr(go_worker_http, "_plan", planner)
    monkeypatch.setattr(server, "parse_window", lambda start, end: (start, end))
    events = []

    def detail(name, data, state, range_arg, window):
        events.append((name, data, state, range_arg, window))
        if name == "bad":
            raise ValueError("private")
        return {"name": name}

    monkeypatch.setattr(server, "build_worker_detail", detail)
    app = {"latest_data": {"workers": []}, "state_manager": object()}
    good = await go_worker_http.handle_worker_detail(
        Request(query={"name": "rig", "range": "1h", "from": "a", "to": "b"}, app=app)
    )
    bad = await go_worker_http.handle_worker_detail(Request(query={"name": "bad"}, app=app))
    assert body(good)["value"] == {"name": "rig"}
    assert bad.status == 500
    assert events[0][3:] == ("1h", ("a", "b"))


async def test_worker_detail_native_capture_path(monkeypatch):
    from mining_dashboard import go_worker_detail
    from mining_dashboard.web import server

    events = []
    monkeypatch.setattr(go_worker_http, "_plan", planner)
    monkeypatch.setattr(server, "build_worker_detail", go_worker_detail.build_worker_detail)
    monkeypatch.setattr(
        go_worker_detail,
        "capture",
        lambda name, data: events.append(("capture", name, data)) or ("frozen", 10),
    )
    monkeypatch.setattr(go_worker_detail, "build_captured", lambda *args, **kwargs: None)

    async def to_thread(function, *args, **kwargs):
        events.append(("thread", function, args, kwargs))
        return {"native": True}

    monkeypatch.setattr(server.asyncio, "to_thread", to_thread)
    monkeypatch.setattr(server, "parse_window", lambda *args: None)
    response = await go_worker_http.handle_worker_detail(
        Request(query={"name": "rig"}, app={"latest_data": {}, "state_manager": "state"})
    )
    assert body(response)["value"] == {"native": True}
    assert [event[0] for event in events] == ["capture", "thread"]


async def test_worker_apply_preserves_record_refresh_order(monkeypatch):
    from mining_dashboard.web import server

    events = []
    monkeypatch.setattr(go_worker_http, "_plan", planner)
    monkeypatch.setattr(server, "_require_control_header", lambda request: events.append("header"))
    monkeypatch.setattr(server.control_service, "validate_worker_changes", lambda value: None)
    monkeypatch.setattr(
        server.control_service,
        "submit_worker_apply",
        lambda worker, changes, actor: events.append(("submit", worker, changes, actor)) or "rid",
    )

    async def wait(rid, done):
        events.append(("wait", rid, done({"status": "applied"})))
        return {"status": "applied", "change_id": "cid", "reason": "ok"}

    monkeypatch.setattr(server.control_service, "wait_result", wait)
    monkeypatch.setattr(
        server.worker_refresh,
        "maybe_refresh_after_apply",
        lambda *args: events.append(("refresh",)),
    )
    state = SimpleNamespace(
        add_worker_config_version=lambda *args, **kwargs: events.append(("record", args, kwargs))
    )
    request = Request(
        {"worker": "rig", "changes": {"pool": "example.test"}},
        headers={"X-Auth-User": "operator"},
        app={"state_manager": state},
    )
    response = await go_worker_http.handle_worker_apply(request)
    assert response.status == 200
    assert [event[0] if isinstance(event, tuple) else event for event in events] == [
        "header",
        "submit",
        "wait",
        "record",
        "refresh",
    ]


async def test_worker_apply_json_and_submit_failures(monkeypatch):
    from mining_dashboard.web import server

    monkeypatch.setattr(go_worker_http, "_plan", planner)
    monkeypatch.setattr(server, "_require_control_header", lambda request: None)
    with pytest.raises(Exception):
        await go_worker_http.handle_worker_apply(Request(failure=ValueError("bad")))
    monkeypatch.setattr(server.control_service, "validate_worker_changes", lambda value: None)
    monkeypatch.setattr(
        server.control_service,
        "submit_worker_apply",
        lambda *args: (_ for _ in ()).throw(OSError("private")),
    )
    response = await go_worker_http.handle_worker_apply(
        Request({"worker": "rig", "changes": {}}, app={"state_manager": object()})
    )
    assert response.status == 500
    assert b"private" not in response.body


async def test_finalize_upgrade_records_and_refreshes(monkeypatch):
    from mining_dashboard.web import server

    events = []
    monkeypatch.setattr(go_worker_http, "_plan", planner)

    async def wait(*args, **kwargs):
        assert kwargs["done"]({"status": "accepted"}) is True
        return {"status": "accepted", "change_id": "cid", "reason": "ok"}

    monkeypatch.setattr(server.control_service, "wait_result", wait)
    monkeypatch.setattr(
        server.worker_refresh,
        "maybe_refresh_after_upgrade",
        lambda *args: async_event(events, "refresh"),
    )
    state = SimpleNamespace(
        add_worker_config_version=lambda *args, **kwargs: events.append(("record", args, kwargs))
    )
    await go_worker_http._finalize_worker_upgrade(state, "rig", "v2", "rid", {})
    assert [event[0] for event in events] == ["record", "refresh"]


async def test_finalize_upgrade_wait_failure_is_sanitized(monkeypatch):
    from mining_dashboard.web import server

    monkeypatch.setattr(
        server.control_service,
        "wait_result",
        lambda *args, **kwargs: async_failure(OSError("private")),
    )
    assert await go_worker_http._finalize_worker_upgrade(object(), "rig", "v2", "rid") is None


async def test_worker_upgrade_schedules_background_finalize(monkeypatch):
    from mining_dashboard.web import server

    events = []
    monkeypatch.setattr(go_worker_http, "_plan", planner)
    monkeypatch.setattr(server, "_require_control_header", lambda request: None)
    monkeypatch.setattr(server, "feed_stale", lambda value: False)
    monkeypatch.setattr(
        server.control_service,
        "submit_worker_upgrade",
        lambda worker, version, actor: events.append((worker, version, actor)) or "rid",
    )

    async def finalize(*args):
        events.append(("finalize", args))

    monkeypatch.setattr(server, "_finalize_worker_upgrade", finalize)
    app = {
        "latest_data": {"rigforge": {"version": "v1"}},
        "state_manager": object(),
        "_bg_tasks": set(),
    }
    response = await go_worker_http.handle_worker_upgrade(
        Request({"worker": "rig", "version": "v2"}, headers={"X-Auth-User": "op"}, app=app)
    )
    assert response.status == 202
    await next(iter(app["_bg_tasks"]))
    assert events[0] == ("rig", "v2", "op")
    assert events[1][0] == "finalize"


async def test_worker_upgrade_noop_and_submit_failure(monkeypatch):
    from mining_dashboard.web import server

    monkeypatch.setattr(server, "_require_control_header", lambda request: None)
    monkeypatch.setattr(server, "feed_stale", lambda value: False)
    plans = {"worker-noop": {"status": 200, "body": {"noop": True}}}

    def plan(operation, **values):
        if operation in plans:
            return plans[operation]
        return planner(operation, **values)

    monkeypatch.setattr(go_worker_http, "_plan", plan)
    app = {"latest_data": {"rigforge": {"version": "v2"}}}
    response = await go_worker_http.handle_worker_upgrade(
        Request({"worker": "rig", "version": "v2"}, app=app)
    )
    assert body(response) == {"noop": True}
    plans["worker-noop"] = {"next": "ready"}
    monkeypatch.setattr(
        server.control_service,
        "submit_worker_upgrade",
        lambda *args: (_ for _ in ()).throw(OSError("private")),
    )
    response = await go_worker_http.handle_worker_upgrade(
        Request({"worker": "rig", "version": "v3"}, app=app)
    )
    assert response.status == 500


def test_install_replaces_worker_handlers(monkeypatch):
    from mining_dashboard import go_worker_detail

    names = (
        "handle_worker_detail",
        "handle_worker_apply",
        "handle_worker_upgrade",
        "_record_worker_result",
        "_finalize_worker_upgrade",
    )
    fake = SimpleNamespace(**{name: object() for name in names})
    called = []
    monkeypatch.setattr(go_worker_detail, "install", lambda: called.append(True))
    go_worker_http.install(fake)
    assert fake.handle_worker_apply is go_worker_http.handle_worker_apply
    assert called == [True]


async def async_event(events, name):
    events.append((name,))


async def async_failure(error):
    raise error
