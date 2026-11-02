import json
from io import BytesIO
from types import SimpleNamespace

import pytest
from aiohttp import web
from multidict import CIMultiDict, CIMultiDictProxy

from mining_dashboard import (
    go_wizard,
    go_wizard_policy,
    go_wizard_submission,
    go_wizard_terminal,
)


class Request:
    def __init__(self, form=None, **app):
        self._form = form or {}
        self.app = app
        self.cookies = {}

    async def post(self):
        return self._form


def test_auth_helpers_forward_cookie_and_token(monkeypatch):
    from mining_dashboard.wizard import server

    calls = []
    monkeypatch.setenv("WIZARD_TOKEN", "token")
    monkeypatch.setattr(
        go_wizard_policy.go_channel,
        "call",
        lambda helper, payload: calls.append((helper, payload)) or True,
    )
    request = Request()
    request.cookies[server.COOKIE] = "cookie"
    assert go_wizard_policy._canon_token(" raw ") is True
    assert go_wizard_policy._authed(request) is True
    assert calls == [
        ("wizard-auth", {"operation": "canon", "token": " raw "}),
        (
            "wizard-auth",
            {"operation": "cookie", "token": "token", "cookie": "cookie"},
        ),
    ]


async def test_auth_accepts_or_rejects_and_updates_failures(monkeypatch):
    monkeypatch.setenv("WIZARD_TOKEN", "token")
    request = Request({"token": " token "}, failures=1, secure_cookie=True)
    monkeypatch.setattr(
        go_wizard_policy,
        "_auth_call",
        lambda *args, **kwargs: {"accepted": True, "failures": 0, "status": 200},
    )
    with pytest.raises(web.HTTPFound) as accepted:
        await go_wizard_policy.auth(request)
    assert accepted.value.cookies

    monkeypatch.setattr(
        go_wizard_policy,
        "_auth_call",
        lambda *args, **kwargs: {"accepted": False, "failures": 2, "status": 403},
    )
    response = await go_wizard_policy.auth(request)
    assert response.status == 403
    assert request.app["failures"] == 2


async def test_auth_lockout_prepares_response_before_exit(monkeypatch):
    events = []

    class Response:
        async def prepare(self, request):
            events.append("prepare")

        async def write_eof(self):
            events.append("eof")

    request = Request({"token": "bad"}, failures=4, secure_cookie=False)
    request.app["exit"] = lambda code: events.append(("exit", code))
    monkeypatch.setattr(
        go_wizard_policy,
        "_auth_call",
        lambda *args, **kwargs: {"accepted": False, "failures": 5, "status": 429},
    )
    monkeypatch.setattr(go_wizard_policy.web, "json_response", lambda *args, **kwargs: Response())
    response = await go_wizard_policy.auth(request)
    assert isinstance(response, Response)
    assert events[0:2] == ["prepare", "eof"]
    assert events[2][0] == "exit"


def test_validate_install_request_forwards_fields_and_disks(monkeypatch):
    calls = []
    monkeypatch.setattr(
        go_wizard_policy.go_channel,
        "call",
        lambda helper, payload: calls.append((helper, payload)) or {"ok": True},
    )
    disks = [{"name": "disk"}]
    assert go_wizard_policy.validate_install_request({"disk": "disk"}, disks) == {"ok": True}
    assert calls[0][1]["operation"] == "install"
    assert calls[0][1]["disks"] is disks


async def test_terminal_handle_auth_contract(monkeypatch):
    from mining_dashboard.wizard import server

    request = Request()
    monkeypatch.setattr(server, "_authed", lambda request: False)
    response = await go_wizard_terminal._handle(request, "handoff")
    assert response.status == 401
    with pytest.raises(web.HTTPFound):
        await go_wizard_terminal._handle(request, "ack")

    monkeypatch.setattr(server, "_authed", lambda request: True)
    monkeypatch.setattr(
        go_wizard_terminal,
        "_call",
        lambda *args, **kwargs: {"body": {"ok": True}, "status": 200},
    )
    response = await go_wizard_terminal.handoff_ack(request)
    assert json.loads(response.body) == {"ok": True}


async def test_retry_handler_auth_and_response(monkeypatch):
    request = Request()
    retry = go_wizard_terminal.retry_handler(
        lambda request: False, lambda: "stage", lambda: "/spool"
    )
    with pytest.raises(web.HTTPFound):
        await retry(request)

    monkeypatch.setattr(
        go_wizard_terminal,
        "_retry",
        lambda *args: {"body": {"retried": True}, "status": 202},
    )
    retry = go_wizard_terminal.retry_handler(
        lambda request: True, lambda: "stage", lambda: "/spool"
    )
    response = await retry(request)
    assert response.status == 202


async def test_status_and_state_http_contract(monkeypatch):
    class Reader:
        async def read(self, *args):
            return "status"

    response = await go_wizard.status(SimpleNamespace(app={go_wizard.STATUS: Reader()}))
    assert response.text == "status"

    from mining_dashboard.wizard import server

    request = SimpleNamespace(app={go_wizard.STATE: Reader()})
    monkeypatch.setattr(server, "_authed", lambda request: False)
    response = await go_wizard.wizard_state(request)
    assert response.status == 401

    native = web.json_response({"ok": True}, status=202, headers={"X-Test": "yes"})

    class StateReader:
        async def read(self, request, builder):
            return native

    request.app[go_wizard.STATE] = StateReader()
    monkeypatch.setattr(server, "_authed", lambda request: True)
    response = await go_wizard.wizard_state(request)
    assert response.status == 202
    assert response.headers["X-Test"] == "yes"


def test_submit_rig_routes_and_executes(monkeypatch):
    from mining_dashboard.wizard import server

    calls = []

    def call(operation, phase, **values):
        calls.append((operation, phase, values))
        if phase == "start":
            return {"next": "install"}
        return {"body": {"ok": True}, "status": 201, "actions": []}

    monkeypatch.setattr(go_wizard_submission, "_call", call)
    monkeypatch.setattr(server, "installer_mode", lambda: True)
    monkeypatch.setattr(server, "_disks", lambda: [{"name": "disk"}])
    response = go_wizard_submission._submit_rig(
        {"rig_pool": "host:3333", "disk": "disk", "confirm": "yes", "wipe": "keep"}
    )
    assert response.status == 201
    assert calls[1][2]["installer"] is True
    assert calls[1][2]["disks"] == [{"name": "disk"}]


async def test_restore_short_circuits_conflict_and_native_rejection(monkeypatch):
    from mining_dashboard.wizard import server

    conflict = web.json_response({"error": "busy"}, status=409)
    monkeypatch.setattr(server, "submission_conflict", lambda: conflict)
    assert await go_wizard_submission._submit_restore_locked(Request()) is conflict

    monkeypatch.setattr(server, "submission_conflict", lambda: None)
    monkeypatch.setattr(
        go_wizard_submission,
        "_call",
        lambda *args, **kwargs: {"next": "done", "body": {"error": "bad"}, "status": 400},
    )
    response = await go_wizard_submission._submit_restore_locked(Request())
    assert response.status == 400


@pytest.mark.parametrize("write_failure", [False, True])
async def test_restore_runs_native_phases_and_cleanup(monkeypatch, write_failure):
    from mining_dashboard.wizard import server

    upload = web.FileField(
        "archive",
        "backup.tar",
        BytesIO(b"Salted__archive"),
        "application/octet-stream",
        CIMultiDictProxy(CIMultiDict()),
    )
    request = Request({"archive": upload, "passphrase": "secret"})
    phases = []

    def call(operation, phase, **values):
        phases.append((operation, phase, values))
        next_phase = {
            "start": "read-upload",
            "validate": "passphrase",
            "passphrase": "install",
        }.get(phase)
        if next_phase:
            return {"next": next_phase, "actions": []}
        if operation == "failure":
            return {"body": {"error": "cleaned"}, "status": 500}
        return {"body": {"ok": True}, "status": 200, "actions": []}

    executions = []

    def execute(result, **values):
        executions.append(values)
        if write_failure and values.get("data"):
            raise OSError("write failed")

    monkeypatch.setattr(server, "submission_conflict", lambda: None)
    monkeypatch.setattr(server, "installer_mode", lambda: False)
    monkeypatch.setattr(server, "clear_failed_restore", lambda: True)
    monkeypatch.setattr(go_wizard_submission, "_call", call)
    monkeypatch.setattr(go_wizard_submission, "_execute", execute)

    response = await go_wizard_submission._submit_restore_locked(request)

    assert response.status == (500 if write_failure else 200)
    assert [phase for _, phase, _ in phases[:4]] == [
        "start",
        "validate",
        "passphrase",
        "publish",
    ]
    assert phases[3][2]["encrypted"] is True
    assert executions[-1] == {"data": b"Salted__archive", "passphrase": "secret"}
