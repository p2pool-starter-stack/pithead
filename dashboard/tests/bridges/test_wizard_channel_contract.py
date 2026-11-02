import asyncio
import json
from types import SimpleNamespace

import pytest
from aiohttp import web

from mining_dashboard import (
    go_wizard,
    go_wizard_policy,
    go_wizard_submission,
    go_wizard_terminal,
    go_wizard_transaction,
)


def test_wizard_call_uses_spool_and_handoff(monkeypatch):
    captured = []
    monkeypatch.setenv("WIZARD_SPOOL", "/spool")
    monkeypatch.setenv("WIZARD_HANDOFF", "/handoff")
    monkeypatch.setattr(
        go_wizard.go_channel,
        "call",
        lambda helper, payload: captured.append((helper, payload)) or "result",
    )
    assert go_wizard._spool_read("name", "/other") == "result"
    assert captured == [
        (
            "wizard",
            {
                "operation": "read",
                "spool": "/spool",
                "handoff": "/handoff",
                "name": "name",
                "directory": "/other",
            },
        )
    ]


def test_wizard_object_accessors_forward_operations(monkeypatch):
    calls = []
    monkeypatch.setattr(
        go_wizard, "_call", lambda operation, **extra: calls.append(operation) or {}
    )
    assert go_wizard.wizard_stage() == {}
    assert go_wizard.installer_mode() == {}
    assert go_wizard._reference() == {}
    assert go_wizard._last_attempt() == {}
    assert go_wizard._rig_defaults() == {}
    assert go_wizard._data_wiped() == {}
    assert go_wizard._saved_role() == {}
    assert calls == [
        "stage",
        "installer",
        "reference",
        "last-attempt",
        "rig-defaults",
        "data-wiped",
        "saved-role",
    ]


async def test_status_coalesces_reads_and_closes(monkeypatch):
    started = asyncio.Event()
    release = asyncio.Event()
    calls = 0

    async def run(self):
        nonlocal calls
        calls += 1
        started.set()
        await release.wait()
        return "ready"

    monkeypatch.setattr(go_wizard.Status, "_run", run)
    status = go_wizard.Status()
    first = asyncio.create_task(status.read())
    await started.wait()
    second = asyncio.create_task(status.read())
    release.set()
    assert await first == "ready"
    assert await second == "ready"
    assert calls == 1
    await status.close({})


async def test_status_close_waits_for_active_task(monkeypatch):
    release = asyncio.Event()

    async def run(self):
        await release.wait()
        return "done"

    monkeypatch.setattr(go_wizard.Status, "_run", run)
    status = go_wizard.Status()
    task = asyncio.create_task(status.read())
    await asyncio.sleep(0)
    closing = asyncio.create_task(status.close({}))
    release.set()
    await closing
    assert await task == "done"


def test_prepare_app_registers_state_and_cleanup():
    app = web.Application()
    go_wizard.prepare_app(app)
    assert isinstance(app[go_wizard.STATUS], go_wizard.Status)
    assert isinstance(app[go_wizard.STATE], go_wizard.State)
    assert [callback.__self__ for callback in app.on_cleanup[-2:]] == [
        app[go_wizard.STATUS],
        app[go_wizard.STATE],
    ]


def test_policy_fields_preserve_metadata_and_digit_state():
    class Value:
        def __str__(self):
            return " 42 "

        def __bool__(self):
            return True

    fields = go_wizard_policy._fields(
        {"monero_remote_rpc": Value(), "wipe": ""},
        ("monero_remote_rpc", "missing", "wipe"),
    )
    assert fields["monero_remote_rpc"] == {
        "text": "42",
        "raw_string": None,
        "present": True,
        "truth": True,
        "lower": " 42 ",
        "digit": True,
        "integer": 42,
    }
    assert fields["missing"]["present"] is False
    assert fields["wipe"]["text"] == ""


def test_policy_build_config_applies_ordered_plan(monkeypatch):
    base = {"dashboard": {"host": "old"}, "monero": {"mode": "local"}}
    monkeypatch.setattr(go_wizard_policy, "new_install_defaults", lambda platform: base)
    monkeypatch.setattr(go_wizard_policy, "default_of", lambda path, platform: path)
    monkeypatch.setattr(
        go_wizard_policy.go_channel,
        "call",
        lambda helper, payload: [
            {"path": ["dashboard", "host"], "value": "new"},
            {"path": ["monero", "mode"], "pairs": [["kind", "remote"]]},
        ],
    )
    result = go_wizard_policy.build_config({}, tari_default="off", platform="test")
    assert result == {"dashboard": {"host": "new"}, "monero": {"mode": {"kind": "remote"}}}


def test_transaction_payload_and_simple_operations(monkeypatch):
    calls = []
    monkeypatch.setenv("WIZARD_SPOOL", "/spool")
    monkeypatch.setenv("WIZARD_RESTORE", "/restore")
    monkeypatch.setattr(
        go_wizard_transaction.go_channel,
        "call",
        lambda helper, payload: calls.append((helper, payload)) or True,
    )
    assert go_wizard_transaction.spool_exists("name") is True
    go_wizard_transaction.spool_remove("name", "/other")
    go_wizard_transaction.clear_submission_sidecars()
    assert [payload["operation"] for _, payload in calls] == [
        "exists",
        "remove",
        "clear-sidecars",
    ]
    assert calls[1][1]["directory"] == "/other"


def test_transaction_writer_contract(monkeypatch):
    captured = []

    def run(command, **kwargs):
        captured.append((command, kwargs))
        return SimpleNamespace(returncode=0, stdout=b'{"ok":true,"value":null}')

    monkeypatch.setattr(go_wizard_transaction.go_channel, "binary", lambda: "/go-dashboard")
    monkeypatch.setattr(go_wizard_transaction.subprocess, "run", run)
    monkeypatch.setattr(go_wizard_transaction.go_channel, "response", lambda *args: None)
    go_wizard_transaction.spool_write("name", "text", "/target")
    header, body = captured[0][1]["input"].split(b"\n", 1)
    assert json.loads(header) | {"length": 4} == json.loads(header)
    assert json.loads(header)["directory"] == "/target"
    assert body == b"text"
    assert captured[0][1]["env"]["PITHEAD_DASHBOARD_HELPER"] == "wizard-write"


def test_transaction_preserves_filesystem_provider_hooks(monkeypatch):
    calls = []
    monkeypatch.setattr(
        go_wizard_transaction,
        "REFERENCE_FUNCTIONS",
        {
            "spool_write": lambda *args: calls.append(("write", args)),
            "spool_remove": lambda *args: calls.append(("remove", args)),
            "spool_exists": lambda *args: calls.append(("exists", args)) or True,
            "clear_page_temps": lambda: calls.append(("clear-temps",)) or False,
        },
    )
    monkeypatch.setattr(go_wizard_transaction.os, "replace", lambda *args: None)
    go_wizard_transaction._run("write", data=b"data", name="name", directory="")
    assert calls == [("write", ("name", b"data", None))]

    monkeypatch.setattr(go_wizard_transaction.os, "replace", go_wizard_transaction._OS_REPLACE)
    monkeypatch.setattr(go_wizard_transaction.os, "unlink", lambda *args: None)
    go_wizard_transaction._run("remove", name="name", directory="/other")
    assert calls[-1] == ("remove", ("name", "/other"))
    assert go_wizard_transaction._run("exists", name="name") is True
    assert go_wizard_transaction._run("clear-temps") is False
    assert calls[-2:] == [("exists", ("name",)), ("clear-temps",)]


@pytest.mark.parametrize("failure", ["oserror", "timeout", "returncode", "response"])
def test_transaction_writer_failures(monkeypatch, failure):
    monkeypatch.setattr(go_wizard_transaction.go_channel, "binary", lambda: "/go-dashboard")

    def run(*args, **kwargs):
        if failure == "oserror":
            raise OSError("missing")
        if failure == "timeout":
            raise go_wizard_transaction.subprocess.TimeoutExpired(args[0], 30)
        return SimpleNamespace(returncode=7 if failure == "returncode" else 0, stdout=b"bad")

    monkeypatch.setattr(go_wizard_transaction.subprocess, "run", run)
    if failure == "response":
        monkeypatch.setattr(
            go_wizard_transaction.go_channel,
            "response",
            lambda *args: (_ for _ in ()).throw(RuntimeError("bad")),
        )
    with pytest.raises(OSError, match="native wizard writer"):
        go_wizard_transaction.spool_write("name", b"data")


def test_submission_conflict_response(monkeypatch):
    monkeypatch.setattr(go_wizard_transaction, "_run", lambda operation: None)
    assert go_wizard_transaction.submission_conflict() is None
    monkeypatch.setattr(
        go_wizard_transaction,
        "_run",
        lambda operation: {"error": "busy", "status": 409},
    )
    response = go_wizard_transaction.submission_conflict()
    assert response.status == 409
    assert json.loads(response.body) == {"error": "busy"}
    reference = web.json_response({"error": "reference"}, status=423)
    monkeypatch.setattr(go_wizard_transaction, "_run", lambda operation: reference)
    assert go_wizard_transaction.submission_conflict() is reference


def test_terminal_call_and_responses(monkeypatch):
    calls = []
    monkeypatch.setenv("WIZARD_SPOOL", "/spool")
    monkeypatch.setattr(
        go_wizard_terminal.go_channel,
        "call",
        lambda helper, payload: calls.append((helper, payload)) or {},
    )
    go_wizard_terminal._call("retry", True, stage="install")
    assert calls[0][1]["spool"] is None
    response = go_wizard_terminal._response(
        {"raw": '{"ok":true}', "status": 202, "headers": {"X-Test": "yes"}}
    )
    assert response.status == 202
    assert json.loads(response.body) == {"ok": True}
    with pytest.raises(web.HTTPFound):
        go_wizard_terminal._response({"redirect": "/next"})


def test_terminal_retry_requests_spool_only_when_needed(monkeypatch):
    calls = []

    def call(operation, authenticated, **values):
        calls.append((operation, authenticated, values))
        if len(calls) == 1:
            return {"need_spool": True}
        return {"body": {"ok": True}, "status": 200}

    monkeypatch.setattr(go_wizard_terminal, "_call", call)
    result = go_wizard_terminal._retry(True, lambda: "install", lambda: "/spool")
    assert result["body"] == {"ok": True}
    assert calls == [
        ("retry", True, {"stage": "install"}),
        ("retry", True, {"stage": "install", "spool": "/spool"}),
    ]


def test_submission_execute_preserves_action_order(monkeypatch):
    from mining_dashboard.wizard import server

    events = []
    monkeypatch.setattr(server, "_spool_clear_host_verdict", lambda: events.append("host"))
    monkeypatch.setattr(server, "clear_submission_sidecars", lambda: events.append("sidecars"))
    monkeypatch.setattr(server, "spool_remove", lambda name: events.append(("remove", name)))
    monkeypatch.setattr(server, "_spool_write_text", lambda *args: events.append(("text", *args)))
    monkeypatch.setattr(server, "_spool_write_bytes", lambda *args: events.append(("bytes", *args)))
    monkeypatch.setattr(server, "restore_dir", lambda: "/restore")
    go_wizard_submission._execute(
        {
            "actions": [
                {"operation": "clear-host"},
                {"operation": "clear-sidecars"},
                {"operation": "remove", "name": "old"},
                {"operation": "text", "name": "a", "text": "b"},
                {"operation": "json", "name": "j", "pairs": [["x", 1]]},
                {"operation": "passphrase"},
                {"operation": "archive", "volatile": True},
            ]
        },
        data=b"archive",
        passphrase="secret",
    )
    assert events[0:3] == ["host", "sidecars", ("remove", "old")]
    assert events[-1] == ("bytes", "restore-archive", b"archive", "/restore")
    with pytest.raises(RuntimeError, match="unsupported"):
        go_wizard_submission._execute({"actions": [{"operation": "unknown"}]})
