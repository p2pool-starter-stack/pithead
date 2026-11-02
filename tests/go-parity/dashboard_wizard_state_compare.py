import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S106, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, directory, implementation="python", **extra):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPATH=str(ROOT / "dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        WIZARD_SPOOL=str(directory / "spool"),
        WIZARD_RESTORE=str(directory / "restore"),
        WIZARD_HANDOFF=str(directory / "handoff"),
        WIZARD_TOKEN="pit-state-fixture",
        **extra,
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


PREAMBLE = r"""
import asyncio, json, os
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard import go_wizard_state
    go_wizard_state.install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
restore = Path(os.environ["WIZARD_RESTORE"])
handoff = Path(os.environ["WIZARD_HANDOFF"])
for path in (spool, restore, handoff):
    path.mkdir(parents=True)
async def state():
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None,
                                                      restore_enabled=True))) as client:
        await client.post("/auth", data={"token":"pit-state-fixture"},
                          allow_redirects=False)
        response = await client.get("/api/wizard-state")
        return {"status":response.status, "body":(await response.read()).hex(),
                "cache":response.headers.get("Cache-Control"),
                "type":response.headers.get("Content-Type")}
"""


def test_fresh_state_http_bytes_provider_order_and_distinct_disk_reads_match(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
events = []
disks = iter([[{"name":"recovery"}], [{"name":"defaults"}], [{"name":"response"}]])
def read_disks():
    value = next(disks)
    events.append(["disks", value[0]["name"]])
    return value
def recover(spool_json, spool_read, value):
    del spool_json, spool_read
    events.append(["recovery", value[0]["name"]])
    return [], None, None
def answers(budget, value, platform):
    events.append(["answers", budget, value[0]["name"], platform])
    return {"dashboard":{"host":"fresh.example.com"}}
server._disks = read_disks
server.recovery_state = recover
server.new_machine_answers = answers
spool.joinpath("config.reference.json").write_text(
    json.dumps({"dashboard":{"host":"auto"}}))
value = asyncio.run(state())
print(json.dumps([value, events], separators=(",",":")))
""",
    )
    assert result[0]["status"] == 200
    assert result[0]["cache"] == "no-store"
    assert result[1] == [
        ["disks", "recovery"],
        ["recovery", "recovery"],
        ["disks", "defaults"],
        ["answers", {}, "defaults", "appliance"],
        ["disks", "response"],
    ]


def test_existing_attempt_skips_defaults_and_empty_change_write(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
events = []
def read_disks():
    events.append("disks")
    return []
def recover(*args):
    events.append("recovery")
    return [], None, None
def answers(*args):
    raise AssertionError("new-machine defaults were read")
def remember(*args):
    raise AssertionError("empty changes were remembered")
server._disks = read_disks
server.recovery_state = recover
server.new_machine_answers = answers
server.remember_changes = remember
spool.joinpath("config.reference.json").write_text(
    json.dumps({"dashboard":{"host":"auto"}}))
spool.joinpath("last-attempt.json").write_text(
    json.dumps({"dashboard":{"host":"kept.example.com"}}))
value = asyncio.run(state())
body = json.loads(bytes.fromhex(value["body"]))
print(json.dumps([value, events, body["new_machine"], body["config_changes"]],
                 separators=(",",":")))
""",
    )
    assert result[1] == ["disks", "recovery", "disks"]
    assert result[2:] == [False, []]


def test_migrated_prefill_is_persisted_and_returned_once(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
spool.joinpath("config.reference.json").write_text(json.dumps({
    "xvb":{"enabled":True}, "dashboard":{"host":"auto"}}))
spool.joinpath("last-attempt.json").write_text(json.dumps({
    "xmrig_proxy":{"enabled":False}, "unknown_1x_key":True}))
value = asyncio.run(state())
body = json.loads(bytes.fromhex(value["body"]))
remembered = json.loads(spool.joinpath("config-changes.json").read_text())
print(json.dumps([value, body["config_changes"], remembered], separators=(",",":")))
""",
    )
    assert result[1] == ["xmrig_proxy.enabled → xvb.enabled", "unknown_1x_key removed"]
    assert result[2]["changes"] == result[1]


def test_malformed_handoff_stops_after_data_wiped_before_saved_role(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
events = []
handoff.joinpath("handoff.json").write_text("{")
def wiped():
    events.append("data-wiped")
    return {}
def role():
    events.append("saved-role")
    return None
server._data_wiped = wiped
server._saved_role = role
value = asyncio.run(state())
print(json.dumps([value, events], separators=(",",":")))
""",
    )
    assert result[0]["status"] == 500
    assert result[1] == ["data-wiped"]


def test_saved_probe_validity_and_response_order_match(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
async def run():
    values = []
    for raw in ("{", "{}", '{"ok":"yes"}',
                '{"ok":false,"probes":[{"target":"monero"}]}'):
        spool.joinpath("node-probe.json").write_text(raw)
        value = await state()
        body = json.loads(bytes.fromhex(value["body"]))
        values.append([list(body), body["node_probe"]])
    return values
print(json.dumps(asyncio.run(run()), separators=(",",":")))
""",
    )
    assert [item[1] for item in result[:3]] == [None, None, None]
    assert result[3][1] == {"ok": False, "probes": [{"target": "monero"}]}
    assert result[3][0][10:14] == ["handoff", "saved_role", "node_probe", "config_changes"]


@pytest.mark.parametrize(
    ("phase", "result"),
    [
        pytest.param("prepare", RuntimeError("native helper unavailable"), id="unavailable"),
        pytest.param("prepare", {"next": "wrong"}, id="malformed-phase"),
        pytest.param(
            "prepare",
            {
                "next": "config",
                "attempt": ["invalid", None],
                "changes": ["list", []],
                "remember": False,
                "read_handoff": False,
                "need_defaults": True,
            },
            id="malformed-tagged-value",
        ),
        pytest.param(
            "prepare",
            {
                "next": "config",
                "attempt": ["dict", []],
                "changes": ["list", []],
                "remember": False,
                "read_handoff": False,
            },
            id="missing-prepare-decision",
        ),
        pytest.param(
            "config",
            {
                "next": "response",
                "config": ["list", []],
                "new_machine": True,
                "mode": "setup",
            },
            id="malformed-config-shape",
        ),
        pytest.param(
            "response", {"next": "ready", "body": ["list", []]}, id="malformed-body-shape"
        ),
    ],
)
def test_native_plan_failures_raise_without_reference_fallback(monkeypatch, phase, result):
    from mining_dashboard import go_wizard_state

    calls = []

    def broken(helper, payload):
        calls.append([helper, payload["phase"]])
        if isinstance(result, Exception):
            raise result
        return result

    monkeypatch.setattr(go_wizard_state.go_channel, "call", broken)
    with pytest.raises(RuntimeError):
        go_wizard_state._plan(phase)
    assert calls == [["wizard-state", phase]]


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_uses_original_state_without_native_helper(tmp_path, implementation):
    marker = tmp_path / "native-called"
    fake = tmp_path / "dashboard-helper"
    fake.write_text(
        f"#!{sys.executable}\n"
        "from pathlib import Path\n"
        f"Path({str(marker)!r}).write_text('called')\n"
        "raise SystemExit(91)\n"
    )
    fake.chmod(0o755)
    env = os.environ.copy()
    if implementation is None:
        env.pop("PITHEAD_IMPL", None)
    else:
        env["PITHEAD_IMPL"] = implementation
    env.update(
        PITHEAD_DASHBOARD_GO_BINARY=str(fake),
        PYTHONPATH=str(ROOT / "dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        WIZARD_SPOOL=str(tmp_path / "spool"),
        WIZARD_RESTORE=str(tmp_path / "restore"),
        WIZARD_TOKEN="pit-state-fixture",
    )
    script = r"""
import asyncio
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
Path(__import__("os").environ["WIZARD_SPOOL"]).mkdir(parents=True)
async def run():
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token":"pit-state-fixture"})
        return (await client.get("/api/wizard-state")).status
assert asyncio.run(run()) == 200
"""
    completed = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    assert not marker.exists()
