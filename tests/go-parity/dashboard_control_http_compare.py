import base64
import json
import os
import subprocess
import sys
from pathlib import Path

# ruff: noqa: S101, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, implementation="python"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
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
import asyncio, base64, json, os
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.config import config, documents
from mining_dashboard.service import control_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.service.workers import worker_adopt
from mining_dashboard.web import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard import go_control_http
    go_control_http.install(server)
config.DASHBOARD_CONTROL_ENABLED = True
HEADERS = {"X-Pithead-Control":"1", "X-Auth-User":"operator"}
async def snapshot(response):
    body = await response.read()
    headers = [[name, response.headers[name]] for name in (
        "Content-Type", "Content-Length", "X-Content-Type-Options", "X-Frame-Options",
        "Referrer-Policy", "Content-Security-Policy", "Cache-Control"
    ) if name in response.headers]
    return [response.status, headers, base64.b64encode(body).decode()]
async def open_client():
    state = StateManager(db_path=":memory:")
    client = TestClient(TestServer(server.create_app(state, {"workers":[]})))
    await client.start_server()
    return state, client
"""


def test_csrf_precedes_json_and_preview_validation_short_circuits():
    result = _paired(
        PREAMBLE
        + r"""
events = []
def fleet(proposed):
    events.append(["fleet", proposed])
    return "fleet rejected" if proposed.get("bad") else None
def workers(current, proposed):
    events.append(["workers", current, proposed])
    return None
def read_config():
    events.append(["read"])
    return {"live":True}
def submit(action, proposed, actor):
    events.append(["submit", action, proposed, actor])
    return "00000000-0000-0000-0000-000000000001"
async def wait(rid, **kwargs):
    events.append(["wait", rid, sorted(kwargs)])
    return None
worker_adopt.validate_fleet_api_port = fleet
worker_adopt.validate_new_worker_entries = workers
control_service.read_config = read_config
control_service.submit = submit
control_service.wait_result = wait
async def main():
    state, client = await open_client()
    try:
        values = []
        values.append(await snapshot(await client.post("/api/control/preview", data=b"{")))
        values.append(await snapshot(await client.post(
            "/api/control/preview", json={"config":"bad"}, headers=HEADERS)))
        values.append(await snapshot(await client.post(
            "/api/control/preview", json={"config":{"bad":True}}, headers=HEADERS)))
        values.append(await snapshot(await client.post(
            "/api/control/preview", json={"config":{"ok":True}}, headers=HEADERS)))
        return [values, events]
    finally:
        await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [item[0] for item in result[0]] == [403, 400, 400, 202]
    assert [event[0] for event in result[1]] == [
        "fleet",
        "fleet",
        "read",
        "workers",
        "submit",
        "wait",
    ]


def test_config_read_errors_and_success_match():
    result = _paired(
        PREAMBLE
        + r"""
values = iter([
    {"ordered":{"value":1}},
    documents.HostConfigError("curated host error"),
    RuntimeError("private generic detail"),
])
def read_config():
    value = next(values)
    if isinstance(value, Exception):
        raise value
    return value
control_service.read_config = read_config
async def main():
    state, client = await open_client()
    try:
        return [await snapshot(await client.get("/api/config")) for _ in range(3)]
    finally:
        await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [item[0] for item in result] == [200, 500, 500]


def test_commit_approval_and_stale_preview_predicate_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
def submit(action, **kwargs):
    events.append(["submit", action, kwargs])
    return kwargs.get("intent_id", "")
async def wait(rid, done=None, **kwargs):
    events.append(["wait", rid, done({"status":"previewed"}), done({"status":"applied"}), kwargs])
    return {"status":"applied", "detail":{"kept":True}}
control_service.submit = submit
control_service.wait_result = wait
RID = "00000000-0000-0000-0000-000000000002"
async def main():
    state, client = await open_client()
    try:
        bodies = [
            {"id":RID, "approve":True, "confirm":"APPLY",
             "payout_suffixes":{"tari":"ab", "monero":"1234"}},
            {"id":RID, "approve":1, "payout_suffixes":{"monero":"ignored"}},
            {"id":RID, "approve":True, "payout_suffixes":{"xmr":"bad"}},
        ]
        replies = [await snapshot(await client.post(
            "/api/control/commit", json=body, headers=HEADERS)) for body in bodies]
        return [replies, events]
    finally:
        await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [item[0] for item in result[0]] == [200, 200, 400]
    assert result[1][0][2]["approval"] == {"payout_suffixes": {"tari": "ab", "monero": "1234"}}
    assert result[1][2][2]["approval"] is None
    assert result[1][1][2:4] == [False, True]


def test_plain_json_version_and_os_action_boundaries_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
def submit(action, **kwargs):
    events.append([action, kwargs])
    return "00000000-0000-0000-0000-000000000003"
control_service.submit = submit
async def main():
    state, client = await open_client()
    try:
        cases = [
            ("/api/control/upgrade", b'{"version":"bad","version":"v\u0661.2.3"}'),
            ("/api/control/upgrade", json.dumps({"version":"v\uff11.2.3"}).encode()),
            ("/api/control/upgrade", json.dumps({"version":"v\U0001d7cf.2.3"}).encode()),
            ("/api/control/upgrade", json.dumps({"version":"v\U00011f50.2.3"}).encode()),
            ("/api/control/upgrade", json.dumps({"version":"v\U0001e4f0.2.3"}).encode()),
            ("/api/control/upgrade", json.dumps({"version":"v\u00b2.2.3"}).encode()),
            ("/api/control/os-update", json.dumps({"action":"check","version":"v\u0661.2.3"}).encode()),
            ("/api/control/os-update", json.dumps({"action":["check"]}).encode()),
        ]
        replies = []
        for path, body in cases:
            replies.append(await snapshot(await client.post(
                path, data=body, headers={**HEADERS, "Content-Type":"application/json"})))
        return [replies, events]
    finally:
        await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [item[0] for item in result[0]] == [202, 202, 202, 400, 400, 400, 202, 500]
    assert [event[0] for event in result[1]] == ["upgrade", "upgrade", "upgrade", "os-check"]


def test_strict_preview_backup_and_result_shapes_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
def submit(action, **kwargs):
    events.append(["submit", action, kwargs])
    return "00000000-0000-0000-0000-000000000004"
async def wait(*args, **kwargs):
    events.append(["unexpected-wait", args, kwargs])
    return None
results = iter([None, ["any", {"shape":True}]])
def result(rid):
    events.append(["result", rid])
    return next(results)
control_service.submit = submit
control_service.wait_result = wait
control_service.result = result
async def main():
    state, client = await open_client()
    try:
        duplicate = b'{"config":{},"config":{"second":true}}'
        replies = [await snapshot(await client.post(
            "/api/control/preview", data=duplicate,
            headers={**HEADERS, "Content-Type":"application/json"}))]
        replies.append(await snapshot(await client.post(
            "/api/control/backup", data=b'{"ignored":true}', headers=HEADERS)))
        rid = "00000000-0000-0000-0000-000000000004"
        replies.append(await snapshot(await client.get("/api/control/result?id=" + rid)))
        replies.append(await snapshot(await client.get("/api/control/result?id=" + rid)))
        return [replies, events]
    finally:
        await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [item[0] for item in result[0]] == [400, 202, 202, 200]
    assert not any(event[0] == "unexpected-wait" for event in result[1])


def test_preview_result_id_collision_order_and_nonmapping_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
results = iter([
    {"status":"previewed", "id":"runner-id", "tail":7},
    ["not", "a", "mapping"],
])
def submit(action, proposed, actor):
    events.append([action, proposed, actor])
    return "00000000-0000-0000-0000-000000000005"
async def wait(rid):
    events.append(["wait", rid])
    return next(results)
worker_adopt.validate_fleet_api_port = lambda proposed: None
worker_adopt.validate_new_worker_entries = lambda current, proposed: None
control_service.read_config = lambda: {}
control_service.submit = submit
control_service.wait_result = wait
async def main():
    state, client = await open_client()
    try:
        replies = []
        for number in (1, 2):
            replies.append(await snapshot(await client.post(
                "/api/control/preview", json={"config":{"case":number}}, headers=HEADERS)))
        return [replies, events]
    finally:
        await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [item[0] for item in result[0]] == [200, 500]
    body = json.loads(base64.b64decode(result[0][0][2]))
    assert list(body) == ["id", "status", "tail"]
    assert body["id"] == "runner-id"
