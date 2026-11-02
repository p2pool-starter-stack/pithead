import json
import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from aiohttp import web

# ruff: noqa: S101, S106, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, directory, implementation="python"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        PYTHONPATH=str(ROOT / "dashboard"),
        WIZARD_SPOOL=str(directory / "spool"),
        WIZARD_HANDOFF=str(directory / "handoff"),
        WIZARD_TOKEN="pit-fixture-token",
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=40,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.splitlines()[-1])


def _paired(tmp_path, script):
    expected = _run(script, tmp_path / "reference")
    actual = _run(script, tmp_path / "native", "go")
    assert actual == expected
    return actual


def test_handoff_http_json_boundaries_match(tmp_path):
    result = _paired(
        tmp_path,
        r"""
import asyncio, json, os
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_terminal import install
    install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
handoff = Path(os.environ["WIZARD_HANDOFF"])
spool.mkdir(parents=True)
handoff.mkdir(parents=True)
async def response(client):
    value = await client.get("/api/handoff")
    return {
        "status": value.status,
        "body": (await value.read()).hex(),
        "location": value.headers.get("Location"),
        "cache": value.headers.get("Cache-Control"),
    }
async def run():
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None))) as client:
        path = handoff / "handoff.json"
        path.write_text('{"ready":true}')
        values = [["unauthenticated", await response(client)]]
        await client.post("/auth", data={"token":"pit-fixture-token"}, allow_redirects=False)
        path.unlink()
        values.append(["missing", await response(client)])
        cases = [
            ("empty", b""),
            ("whitespace", b" \n\t "),
            ("corrupt", b"{"),
            ("nonobject", b"[1,2]"),
            ("numeric", b"NaN"),
            ("surrogate", b'"\\ud800"'),
            ("newlines", b'\n {"line":"one\\ntwo"} \r\n'),
        ]
        for name, raw in cases:
            path.write_bytes(raw)
            values.append([name, await response(client)])
        return values
print(json.dumps(asyncio.run(run()), separators=(",", ":")))
""",
    )
    assert [item[0] for item in result] == [
        "unauthenticated",
        "missing",
        "empty",
        "whitespace",
        "corrupt",
        "nonobject",
        "numeric",
        "surrogate",
        "newlines",
    ]
    assert result[0][1]["status"] == 401
    assert result[1][1]["status"] == result[2][1]["status"] == result[3][1]["status"] == 404
    assert result[4][1]["status"] == 500
    assert all(item[1]["cache"] == "no-store" for item in result[5:])


def test_ack_and_keep_role_http_and_atomic_files_match(tmp_path):
    result = _paired(
        tmp_path,
        r"""
import asyncio, json, os, stat
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_terminal import install
    install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
handoff = Path(os.environ["WIZARD_HANDOFF"])
spool.mkdir(parents=True)
handoff.mkdir(parents=True)
def tree(root):
    return {
        str(path.relative_to(root)): [path.read_bytes().hex(), stat.S_IMODE(path.stat().st_mode)]
        for path in root.rglob("*") if path.is_file()
    }
async def capture(client, route):
    value = await client.post(route, allow_redirects=False)
    return [value.status, (await value.read()).hex(), value.headers.get("Location"),
            value.headers.get("Cache-Control")]
async def run():
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None))) as client:
        values = [["ack-unauth", await capture(client, "/handoff-ack")],
                  ["keep-unauth", await capture(client, "/keep-role")]]
        await client.post("/auth", data={"token":"pit-fixture-token"}, allow_redirects=False)
        values.append(["ack-missing", await capture(client, "/handoff-ack")])
        (handoff / "handoff.json").write_bytes(b"")
        values.append(["ack-empty", await capture(client, "/handoff-ack")])
        malformed = [b"{", b"[]", b"{}", b'{"role":""}', b'{"role":3}']
        for raw in malformed:
            (spool / "saved-role.json").write_bytes(raw)
            values.append(["keep-malformed", await capture(client, "/keep-role")])
        (spool / "saved-role.json").write_text('{"role":"rig","worker":"placeholder"}')
        values.append(["keep-valid", await capture(client, "/keep-role")])
        return {"responses": values, "spool": tree(spool), "handoff": tree(handoff)}
print(json.dumps(asyncio.run(run()), separators=(",", ":")))
""",
    )
    responses = result["responses"]
    redirect_body = b"302: Found".hex()
    assert responses[0][1][:3] == [302, redirect_body, "/"]
    assert responses[1][1][:3] == [302, redirect_body, "/"]
    assert responses[2][1][0] == 400
    assert responses[3][1][0] == 200
    assert all(item[1][0] == 400 for item in responses[4:9])
    assert responses[9][1][0] == 200
    assert result["spool"]["handoff-ack"] == ["31", 0o600]
    assert result["spool"]["keep-role"] == ["31", 0o600]


def test_explicit_empty_handoff_directory_matches_spool_fallback(tmp_path):
    result = _paired(
        tmp_path,
        r"""
import asyncio, json, os
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_terminal import install
    install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
spool.mkdir(parents=True)
cwd = spool.parent / "isolated-cwd"
cwd.mkdir()
os.chdir(cwd)
os.environ["WIZARD_HANDOFF"] = ""
(cwd / "handoff.json").write_text('{"location":"wrong"}')
(spool / "handoff.json").write_text('{"location":"placeholder"}')
async def capture(client, method, route):
    value = await getattr(client, method)(route, allow_redirects=False)
    return [value.status, (await value.read()).hex(), value.headers.get("Cache-Control")]
async def run():
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token":"pit-fixture-token"}, allow_redirects=False)
        handoff = await capture(client, "get", "/api/handoff")
        ack = await capture(client, "post", "/handoff-ack")
        return [handoff, ack, (spool / "handoff-ack").read_bytes().hex(),
                (cwd / "handoff.json").read_text()]
print(json.dumps(asyncio.run(run()), separators=(",", ":")))
""",
    )
    assert result[0][0] == 200
    assert result[0][2] == "no-store"
    assert result[1][0] == 200
    assert result[2] == "31"
    assert result[3] == '{"location":"wrong"}'


def test_retry_decisions_cleanup_order_and_failure_paths_match(tmp_path):
    result = _paired(
        tmp_path,
        r"""
import asyncio, json, os, stat
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_terminal import install
    install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
handoff = Path(os.environ["WIZARD_HANDOFF"])
spool.mkdir(parents=True)
handoff.mkdir(parents=True)
def tree():
    values = {}
    for path in sorted(spool.iterdir()):
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            values[path.name] = ["link", os.readlink(path), mode]
        elif path.is_dir():
            values[path.name] = ["dir", mode]
        else:
            values[path.name] = ["file", path.read_bytes().hex(), mode]
    return values
async def capture(client):
    value = await client.post("/retry", allow_redirects=False)
    return [value.status, (await value.read()).hex(), value.headers.get("Location"),
            value.headers.get("Cache-Control"), tree()]
async def run():
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None))) as client:
        values = [["unauthenticated", await capture(client)]]
        await client.post("/auth", data={"token":"pit-fixture-token"}, allow_redirects=False)
        values.append(["not-failed", await capture(client)])
        (spool / "setup-failed").write_text("1")
        (spool / "error.txt").write_text("failure")
        (spool / "installing").write_text("1")
        (spool / "unrelated").write_text("keep")
        values.append(["success", await capture(client)])
        (spool / "setup-failed").write_text("1")
        (spool / "error.txt").symlink_to("missing-target")
        (spool / "installing").symlink_to("missing-progress")
        values.append(["broken-links", await capture(client)])
        (spool / "setup-failed").write_text("1")
        (spool / "error.txt").unlink()
        (spool / "error.txt").write_text("remove-first")
        (spool / "installing").unlink()
        (spool / "installing").mkdir()
        values.append(["partial-failure", await capture(client)])
        return values
print(json.dumps(asyncio.run(run()), separators=(",", ":")))
""",
    )
    assert result[0][1][:3] == [302, b"302: Found".hex(), "/"]
    assert result[1][1][0] == 409
    assert result[2][1][0] == 200
    assert result[2][1][4] == {"unrelated": ["file", "6b656570", 0o644]}
    assert result[3][1][0] == 200
    assert set(result[3][1][4]) == {"error.txt", "installing", "unrelated"}
    assert result[4][1][0] == 500
    assert "error.txt" not in result[4][1][4]
    assert set(result[4][1][4]) == {"installing", "setup-failed", "unrelated"}


@pytest.mark.parametrize(
    ("authenticated", "stage_value", "expected_stage", "needs_spool"),
    [
        (False, "unused", "", False),
        (True, "setup", "setup", False),
        (True, "failed", "failed", True),
    ],
)
def test_retry_factory_calls_callbacks_lazily(
    monkeypatch, authenticated, stage_value, expected_stage, needs_spool
):
    from mining_dashboard import go_wizard_terminal

    callbacks = []
    calls = []

    def stage():
        callbacks.append("stage")
        return stage_value

    def spool():
        callbacks.append("spool")
        return "/topology-placeholder"

    def call(operation, authed, **values):
        calls.append([operation, authed, values])
        if needs_spool and len(calls) == 1:
            return {"need_spool": True}
        return {"status": 200, "body": {"status": "settings"}}

    monkeypatch.setattr(go_wizard_terminal, "_call", call)
    result = go_wizard_terminal._retry(authenticated, stage, spool)
    assert callbacks == (
        ["stage", "spool"] if needs_spool else (["stage"] if authenticated else [])
    )
    assert calls[0] == ["retry", authenticated, {"stage": expected_stage}]
    if needs_spool:
        assert calls[1] == [
            "retry",
            authenticated,
            {"stage": expected_stage, "spool": "/topology-placeholder"},
        ]
    assert result == {"status": 200, "body": {"status": "settings"}}


@pytest.mark.parametrize(
    ("entry", "expected_status"),
    [("handoff", 401), ("handoff_ack", 302), ("keep_role", 302), ("retry_handler", 302)],
)
@pytest.mark.asyncio
async def test_unauthenticated_endpoint_never_calls_native_or_retry_callbacks(
    monkeypatch, entry, expected_status
):
    from mining_dashboard import go_wizard_terminal
    from mining_dashboard.wizard import server

    calls = []
    callbacks = []

    def native(*args, **kwargs):
        calls.append([args, kwargs])
        raise AssertionError("native terminal helper called")

    def stage():
        callbacks.append("stage")
        return "failed"

    def spool():
        callbacks.append("spool")
        return "/topology-placeholder"

    monkeypatch.setattr(go_wizard_terminal, "_call", native)
    request = SimpleNamespace()
    if entry == "retry_handler":
        handler = go_wizard_terminal.retry_handler(lambda value: False, stage, spool)
    else:
        monkeypatch.setattr(server, "_authed", lambda value: False)
        handler = getattr(go_wizard_terminal, entry)
    try:
        response = await handler(request)
        status = response.status
        assert response.body == b'{"error": "unauthenticated"}'
    except web.HTTPFound as error:
        status = error.status
        assert error.location == "/"
    assert status == expected_status
    assert calls == []
    assert callbacks == []
