# ruff: noqa: S101, S603

import os
import subprocess
import sys
from pathlib import Path

import pytest
import run_dashboard_native_oracle as launcher
from dashboard_native_oracle_plugin import _accepted_without_compatibility

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "tests/go-parity/run_dashboard_native_oracle.py"


def test_launcher_owns_selector_paths_and_plugin():
    env = launcher.environment(
        {"PYTHONPATH": "fixture", "PYTEST_PLUGINS": "wrong", "PYTEST_ADDOPTS": "-k hidden"}
    )
    assert env["PITHEAD_IMPL"] == "go"
    assert "PYTEST_PLUGINS" not in env
    assert "PYTEST_ADDOPTS" not in env
    assert env["PYTHONPATH"].split(os.pathsep) == [
        str(ROOT / "tests/go-parity"),
        str(ROOT / "dashboard"),
        "fixture",
    ]
    assert launcher.command(["-q", "tests"])[3:5] == ["-p", launcher.PLUGIN]


@pytest.mark.parametrize(
    "arguments",
    [
        ["-p", "dashboard_state_plugin"],
        ["-pdashboard_state_plugin"],
        ["-p", "no:dashboard_native_oracle_plugin"],
        ["-pno:dashboard_native_oracle_plugin"],
    ],
)
def test_launcher_rejects_competing_dashboard_plugins(arguments):
    with pytest.raises(ValueError, match="owned by the native-oracle launcher"):
        launcher.command(arguments)


def test_default_selection_is_the_frozen_original_dashboard_oracle():
    paths = launcher.original_tests()
    assert len(paths) == 248
    assert "tests/web/test_server_state_api.py" in paths
    assert "tests/bridges/test_state_bridges.py" not in paths


def test_compatibility_result_is_not_counted_as_native_acceptance():
    from collections import Counter

    calls = Counter(posture=1)
    compatibility = Counter()
    assert _accepted_without_compatibility(calls, "posture", compatibility, 0, 0)
    compatibility["compute_egress_posture:route-provider"] += 1
    assert not _accepted_without_compatibility(calls, "posture", compatibility, 0, 0)


def _fake_binary(tmp_path):
    binary = tmp_path / "dashboard-fake"
    binary.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, socket, sys, urllib.error, urllib.request\n"
        "trace = os.environ['NATIVE_ORACLE_FAKE_TRACE']\n"
        "helper = os.environ.get('PITHEAD_DASHBOARD_HELPER', '')\n"
        "def record(value):\n"
        "    with open(trace, 'a', encoding='utf-8') as stream:\n"
        "        stream.write(value + '\\n')\n"
        "if helper:\n"
        "    record('helper:' + helper)\n"
        "    if helper == 'network-stream':\n"
        "        raise SystemExit(0)\n"
        "    for line in sys.stdin:\n"
        "        value = 0 if helper == 'average-stream' else {}\n"
        "        print(json.dumps(value), flush=True)\n"
        "        if helper.endswith('-stream'):\n"
        "            break\n"
        "    raise SystemExit(0)\n"
        "listener = socket.socket(fileno=int(os.environ['PITHEAD_DASHBOARD_LISTEN_FD']))\n"
        "while True:\n"
        "    connection, _ = listener.accept()\n"
        "    request = b''\n"
        "    while b'\\r\\n\\r\\n' not in request:\n"
        "        block = connection.recv(4096)\n"
        "        if not block:\n"
        "            break\n"
        "        request += block\n"
        "    path = request.split(b' ', 2)[1].decode().split('?', 1)[0]\n"
        "    record('server:' + path)\n"
        "    status = 200\n"
        "    body = b'{\"broken-native\":true}' if path == '/api/state' else b'ready'\n"
        "    if path == '/api/state' and os.environ.get('NATIVE_ORACLE_FAKE_MODE') == 'forward-state':\n"
        "        try:\n"
        "            upstream = urllib.request.urlopen(os.environ['PITHEAD_DASHBOARD_REFERENCE_URL'] + path)\n"
        "        except urllib.error.HTTPError as error:\n"
        "            upstream = error\n"
        "        status, body = upstream.status, upstream.read()\n"
        "    kind = b'application/json' if path == '/api/state' else b'text/plain'\n"
        "    response = (f'HTTP/1.1 {status} Result\\r\\n'.encode() + b'Content-Type: ' + kind + "
        " b'\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: close\\r\\n\\r\\n' + body)\n"
        "    connection.sendall(response)\n"
        "    connection.close()\n"
    )
    binary.chmod(0o755)
    return binary


def _run_probe(tmp_path, source, mode="broken"):
    binary = _fake_binary(tmp_path)
    trace = tmp_path / "trace"
    probe = tmp_path / "test_native_probe.py"
    probe.write_text(source)
    env = os.environ.copy()
    env.update(
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        NATIVE_ORACLE_FAKE_TRACE=str(trace),
        NATIVE_ORACLE_FAKE_MODE=mode,
        PYTEST_XDIST_AUTO_NUM_WORKERS="1",
    )
    result = subprocess.run(
        [sys.executable, str(RUNNER), "-q", str(probe)],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=90,
        check=False,
    )
    return result, trace.read_text().splitlines()


def test_broken_native_state_route_cannot_hide_behind_reference_app(tmp_path):
    result, trace = _run_probe(
        tmp_path,
        "import pytest\n"
        "from mining_dashboard.web.server import create_app\n"
        "@pytest.mark.asyncio\n"
        "async def test_state(aiohttp_client):\n"
        "    response = await (await aiohttp_client(create_app(object(), {}))).get('/api/state')\n"
        "    assert response.status == 200\n",
        mode="forward-state",
    )
    assert result.returncode != 0
    assert "server:/api/state" in trace
    assert '"public-http": 1' in result.stdout


def test_broken_native_helper_cannot_fall_back_to_python_body(tmp_path):
    result, trace = _run_probe(
        tmp_path,
        "from mining_dashboard.web.views.charts import build_chart\n"
        "def test_chart():\n"
        "    value = build_chart([{'timestamp': 1, 'v': 2, 'v_p2pool': 2, 'v_xvb': 0}], [], 'all')\n"
        "    assert value['p2pool'][0]['y'] == 2\n",
    )
    assert result.returncode != 0
    assert "helper:chart" in trace
    assert "KeyError" in result.stdout
