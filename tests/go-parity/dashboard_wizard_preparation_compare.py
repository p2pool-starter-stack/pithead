import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S106, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, implementation="python", **extra):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPATH=str(ROOT / "dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
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


def _paired(script):
    expected = _run(script)
    actual = _run(script, "go")
    assert actual == expected
    return actual


PREAMBLE = r"""
import json, os
from mining_dashboard import go_wizard_typed
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    go_wizard_typed.install(server)
    from mining_dashboard import go_wizard_preparation
def config(form, raw):
    if os.environ["PITHEAD_IMPL"] == "go":
        return go_wizard_preparation.config(form, raw)
    return go_wizard_typed._config(form, raw)
def prepare(cfg, ref):
    if os.environ["PITHEAD_IMPL"] == "go":
        return go_wizard_preparation.prepare(cfg, ref)
    cfg, changes = server.prepare_config(cfg, ref, reject_legacy_conflicts=True)
    if not server._last_attempt():
        defaults, _ = server.prepare_config(
            server.new_install_defaults(
                (server._spool_read("platform.txt") or "appliance").strip()
            ), ref
        )
        cfg = server.deep_merge(defaults, cfg)
    server.validate_machine_name(cfg, server._last_attempt())
    return cfg, changes
"""


def test_raw_and_form_sources_match():
    result = _paired(
        PREAMBLE
        + r"""
values = []
for form, raw in (({}, '{"dashboard":{"host":"raw-name"}}'),
                  ({"machine_name":"form-name","monero_mode":"local"}, "")):
    try:
        values.append(["value", config(form, raw)])
    except Exception as error:
        values.append([type(error).__name__, str(error)])
for raw in ("null", "[]", "42"):
    try:
        values.append(["value", config({}, raw)])
    except Exception as error:
        values.append([type(error).__name__, str(error)])
print(json.dumps(values, separators=(",", ":")))
"""
    )
    assert [item[0] for item in result[-3:]] == ["ValueError"] * 3


def test_fresh_defaults_and_changing_previous_values_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
previous = iter([{}, {"dashboard":{"host":"old.example.com"}}])
def last():
    value = next(previous)
    events.append(["previous", value])
    return value
server._last_attempt = last
cfg, changes = prepare({"dashboard":{"host":"auto"}}, {"dashboard":{"host":"auto"}})
print(json.dumps([cfg, changes, events], separators=(",", ":")))
"""
    )
    assert [event[0] for event in result[2]] == ["previous", "previous"]
    assert result[2][0][1] == {}
    assert result[2][1][1]["dashboard"]["host"] == "old.example.com"


def test_existing_previous_skips_default_provider_and_reads_again():
    result = _paired(
        PREAMBLE
        + r"""
events = []
previous = iter([
    {"dashboard":{"host":"existing.example.com"}},
    {"dashboard":{"host":"auto"}},
])
def last():
    value = next(previous)
    events.append(["previous", value])
    return value
def defaults(platform):
    raise AssertionError("defaults provider called")
server._last_attempt = last
server.new_install_defaults = defaults
cfg, changes = prepare({"dashboard":{"host":"auto"}}, {"dashboard":{"host":"auto"}})
print(json.dumps([cfg, changes, events], separators=(",", ":")))
"""
    )
    assert len(result[2]) == 2


def test_prepare_and_default_provider_failures_stop_following_providers():
    result = _paired(
        PREAMBLE
        + r"""
values = []
events = []
def last():
    events.append("previous")
    return {}
server._last_attempt = last
conflict = {"xvb":{"enabled":True}, "xmrig_proxy":{"enabled":False}}
try:
    prepare(conflict, {})
except Exception as error:
    values.append([type(error).__name__, str(error), list(events)])
events.clear()
def defaults(platform):
    events.append(["defaults", platform])
    raise ValueError("defaults stopped")
server.new_install_defaults = defaults
try:
    prepare({}, {})
except Exception as error:
    values.append([type(error).__name__, str(error), list(events)])
print(json.dumps(values, separators=(",", ":")))
"""
    )
    assert result[0][0] == "ValueError"
    assert result[0][2] == []
    assert result[1] == ["ValueError", "defaults stopped", ["previous", ["defaults", "appliance"]]]


@pytest.mark.parametrize("fault", ["helper", "plan"])
def test_native_preparation_failures_reach_the_http_500_boundary(tmp_path, fault):
    result = _run(
        r"""
import asyncio, json, os
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard import go_wizard_preparation, go_wizard_typed
from mining_dashboard.wizard import server
go_wizard_typed.install(server)
native = go_wizard_preparation.go_channel.call
if os.environ["FAULT"] == "helper":
    def broken(helper, payload):
        if helper == "wizard-preparation":
            raise RuntimeError("native helper unavailable")
        return native(helper, payload)
else:
    def broken(helper, payload):
        if helper == "wizard-preparation":
            return {}
        return native(helper, payload)
go_wizard_preparation.go_channel.call = broken
async def run():
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token":"fixture-token"}, allow_redirects=False)
        response = await client.post("/submit", data={"config":"{}"})
        return response.status
print(json.dumps(asyncio.run(run())))
""",
        "go",
        FAULT=fault,
        WIZARD_SPOOL=str(tmp_path / "spool"),
        WIZARD_RESTORE=str(tmp_path / "restore"),
        WIZARD_HANDOFF=str(tmp_path / "handoff"),
        WIZARD_TOKEN="fixture-token",
    )
    assert result == 500


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_starts_native_helper(tmp_path, implementation):
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
    )
    script = "from mining_dashboard.go_wizard_typed import _config; assert _config({}, '{}') == {}"
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert not marker.exists()
