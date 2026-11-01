import asyncio
import json
import math
import os
import subprocess
import sys
import threading
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard import go_channel, go_control, go_wizard
from mining_dashboard.config import config

# ruff: noqa: S101, S603

ROOT = Path(__file__).resolve().parents[2]
RID = "12345678-1234-5678-90ab-1234567890ab"


def _reference(script, directory, implementation="python"):
    env = os.environ.copy()
    env["PITHEAD_IMPL"] = implementation
    env["PYTHONPATH"] = str(ROOT / "dashboard")
    result = subprocess.run(
        [sys.executable, "-c", script, str(directory)],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


@pytest.mark.parametrize("mask", [0, 0o077, 0o777])
def test_control_writer_honors_the_inherited_umask(tmp_path, mask):
    script = f"""import json,os,sys
from pathlib import Path
from mining_dashboard.config import config
from mining_dashboard.service import control_service
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_control import install
    install()
config.CONTROL_REQUESTS_DIR = sys.argv[1]
os.umask({mask})
rid = control_service.submit("preview", {{}}, intent_id={RID!r})
print(json.dumps({{"id":rid,"mode":Path(sys.argv[1],rid+".json").stat().st_mode & 0o777}}))
"""
    reference = tmp_path / "reference"
    native = tmp_path / "native"
    reference.mkdir()
    native.mkdir()
    try:
        expected = _reference(script, reference)
        assert _reference(script, native, "go") == expected
        assert expected["mode"] == (0o600 & ~mask)
    finally:
        for directory in (reference, native):
            for path in directory.iterdir():
                path.chmod(0o600)


def test_native_control_request_bytes_and_special_values(tmp_path, monkeypatch):
    reference_dir = tmp_path / "reference"
    native_dir = tmp_path / "native"
    reference_dir.mkdir()
    native_dir.mkdir()
    script = """import json,sys
from mining_dashboard.config import config
from mining_dashboard.service import control_service
config.CONTROL_REQUESTS_DIR = sys.argv[1]
rid=control_service.submit("preview", {"z":2**80,"_core_keys":["x"],"a":"été","n":float("nan"),"i":float("inf"),"nested":{"_core_keys":1}}, actor=None, intent_id="12345678-1234-5678-90ab-1234567890ab", confirm="APPLY", approval={"payout_suffixes":{"monero":"12345678"}})
print(json.dumps({"id":rid}))
"""
    expected = _reference(script, reference_dir)
    monkeypatch.setattr(config, "CONTROL_REQUESTS_DIR", str(native_dir))
    actual = go_control.submit(
        "preview",
        {
            "z": 2**80,
            "_core_keys": ["x"],
            "a": "été",
            "n": math.nan,
            "i": math.inf,
            "nested": {"_core_keys": 1},
        },
        actor=None,
        intent_id=RID,
        confirm="APPLY",
        approval={"payout_suffixes": {"monero": "12345678"}},
    )
    assert actual == expected["id"]
    assert (native_dir / f"{RID}.json").read_bytes() == (reference_dir / f"{RID}.json").read_bytes()
    assert (native_dir / f"{RID}.json").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("value", [None, [], {"large": 2**80}, "ready", 42, False])
def test_native_result_returns_every_json_shape(tmp_path, monkeypatch, value):
    monkeypatch.setattr(config, "CONTROL_RESULTS_DIR", str(tmp_path))
    (tmp_path / f"{RID}.json").write_text(json.dumps(value))
    assert go_control.result("{" + RID.upper() + "}") == value


def test_native_control_failure_never_falls_back(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "CONTROL_REQUESTS_DIR", str(tmp_path))
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(tmp_path / "missing"))
    with pytest.raises(RuntimeError, match="helper unavailable"):
        go_control.submit("preview", {}, intent_id=RID)
    assert not list(tmp_path.iterdir())


def test_native_wizard_objects_read_and_status(tmp_path, monkeypatch):
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_HANDOFF", str(tmp_path))
    (tmp_path / "config.reference.json").write_text(
        '{"_docs":1,"config_version":"2.0.0","big":1208925819614629174706176,"n":NaN,"i":Infinity}'
    )
    value = go_wizard._reference()
    assert value["big"] == 2**80 and math.isnan(value["n"]) and value["i"] == math.inf
    assert "_docs" not in value and "config_version" not in value
    other = tmp_path / "other"
    other.mkdir()
    (other / "marker").write_bytes(b"\r\n a\rb\r\n")
    assert go_wizard._spool_read("marker", str(other)) == "a\nb"
    for name, stage in (
        ("disks.tsv", "installer"),
        ("handoff.json", "handoff"),
        ("setup-failed", "failed"),
    ):
        (tmp_path / name).write_text("1")
        assert go_wizard.wizard_stage() == stage


def test_native_wizard_invalid_utf8_and_json_match_reference(tmp_path, monkeypatch):
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    (tmp_path / "last-attempt.json").write_bytes(b"\xff")
    assert go_wizard._last_attempt() == {}
    with pytest.raises(UnicodeDecodeError):
        go_wizard._spool_read("last-attempt.json")


@pytest.mark.parametrize("stdout,code", [("invalid", 0), ('{"ok":true}', 0), ("", 125)])
def test_channel_transport_failure_is_fatal(tmp_path, monkeypatch, stdout, code):
    helper = tmp_path / "helper"
    helper.write_text(f"#!{sys.executable}\nprint({stdout!r})\nraise SystemExit({code})\n")
    helper.chmod(0o755)
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(helper))
    with pytest.raises(RuntimeError):
        go_channel.call("control", {"operation": "control-submit", "action": "preview"})


@pytest.mark.parametrize("implementation", [None, "bash", "python", "go"])
def test_wizard_public_reference_selection_ignores_native_helper(tmp_path, implementation):
    env = os.environ.copy()
    env.pop("PITHEAD_IMPL", None)
    if implementation is not None:
        env["PITHEAD_IMPL"] = implementation
    env["PYTHONPATH"] = str(ROOT / "dashboard")
    env["PITHEAD_DASHBOARD_GO_BINARY"] = str(tmp_path / "missing")
    env["WIZARD_SPOOL"] = str(tmp_path)
    env["WIZARD_RESTORE"] = str(tmp_path / "restore")
    script = """from mining_dashboard.wizard import server
server.make_app()
print(server.wizard_stage())
"""
    result = subprocess.run(
        [sys.executable, "-c", script], env=env, capture_output=True, text=True, check=False
    )
    if implementation == "go":
        assert result.returncode != 0
        assert "native wizard helper unavailable" in result.stderr
    else:
        assert result.returncode == 0
        assert result.stdout.strip() == "setup"


async def test_public_status_coalesces_native_work_without_blocking_auth(tmp_path, monkeypatch):
    from mining_dashboard.wizard import server

    monkeypatch.setenv("PITHEAD_IMPL", "go")
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_RESTORE", str(tmp_path / "restore"))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-fixture")
    started = threading.Event()
    release = threading.Event()
    calls = []
    native = go_wizard._call

    def delayed(operation, **extra):
        calls.append(operation)
        started.set()
        if not release.wait(timeout=10):
            raise RuntimeError("status fixture timed out")
        return native(operation, **extra)

    monkeypatch.setattr(go_wizard, "_call", delayed)
    client = TestClient(TestServer(server.make_app()))
    await client.start_server()
    tasks = [asyncio.create_task(client.get("/status")) for _ in range(12)]
    try:
        assert await asyncio.to_thread(started.wait, 2)
        async with asyncio.timeout(2):
            response = await client.post(
                "/auth", data={"token": "pit-fixture"}, allow_redirects=False
            )
            assert response.status == 302
        release.set()
        responses = await asyncio.gather(*tasks)
        assert calls == ["status"]
        assert all(response.status == 200 for response in responses)
        assert {await response.text() for response in responses} == {
            "Waiting for this machine to validate and apply…"
        }
        (tmp_path / "applied").write_text("1")
        response = await client.get("/status")
        assert await response.text() == "Provisioned — the dashboard is coming up now."
        assert calls == ["status", "status"]
    finally:
        release.set()
        await asyncio.gather(*tasks, return_exceptions=True)
        await client.close()


async def test_wizard_state_coalesces_and_keeps_auth_responsive(tmp_path, monkeypatch):
    from mining_dashboard.wizard import server

    monkeypatch.setenv("PITHEAD_IMPL", "go")
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_HANDOFF", str(tmp_path))
    monkeypatch.setenv("WIZARD_RESTORE", str(tmp_path / "restore"))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-fixture")
    started = threading.Event()
    release = threading.Event()
    calls = []
    builder = go_wizard.state_builder

    def delayed(request):
        calls.append(1)
        started.set()
        if not release.wait(timeout=10):
            raise RuntimeError("state fixture timed out")
        return builder(request)

    monkeypatch.setattr(go_wizard, "state_builder", delayed)
    client = TestClient(TestServer(server.make_app()))
    await client.start_server()
    await client.post("/auth", data={"token": "pit-fixture"})
    tasks = [asyncio.create_task(client.get("/api/wizard-state")) for _ in range(12)]
    anonymous = TestClient(client.server)
    try:
        assert await asyncio.to_thread(started.wait, 2)
        async with asyncio.timeout(2):
            response = await client.post(
                "/auth", data={"token": "pit-fixture"}, allow_redirects=False
            )
            assert response.status == 302
            response = await anonymous.get("/api/wizard-state")
            assert response.status == 401
        release.set()
        responses = await asyncio.gather(*tasks)
        bodies = [await response.json() for response in responses]
        assert calls == [1]
        assert all(response.status == 200 for response in responses)
        assert all(body == bodies[0] for body in bodies)
        assert bodies[0]["stage"] == "setup"
        assert all(response.headers["Cache-Control"] == "no-store" for response in responses)
        (tmp_path / "applied").write_text("1")
        response = await client.get("/api/wizard-state")
        assert (await response.json())["stage"] == "done"
        assert calls == [1, 1]
    finally:
        release.set()
        await asyncio.gather(*tasks, return_exceptions=True)
        await anonymous.close()
        await client.close()
