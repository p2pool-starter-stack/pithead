import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

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
from mining_dashboard.config import config
from mining_dashboard.service import control_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.service.workers import worker_refresh
from mining_dashboard.web import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard import go_worker_http
    go_worker_http.install(server)
config.DASHBOARD_CONTROL_ENABLED = True
HEADERS = {"X-Pithead-Control":"1", "X-Auth-User":"operator"}
async def snapshot(response):
    body = await response.read()
    return [response.status, response.headers.get("Content-Type"), base64.b64encode(body).decode()]
async def open_client(data=None):
    state = StateManager(db_path=":memory:")
    client = TestClient(TestServer(server.create_app(state, data or {"workers":[]})))
    await client.start_server()
    return state, client
"""


def test_header_json_name_and_detail_boundaries_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
def detail(name, data, state, range_arg, window):
    events.append([name, data, range_arg, window])
    if name == "boom": raise RuntimeError("private")
    return {"name":name,"ok":True}
server.build_worker_detail = detail
control_service.validate_worker_changes = lambda changes: None
control_service.submit_worker_apply = lambda worker, changes, actor: "rid"
async def wait(rid, done): return None
control_service.wait_result = wait
async def main():
    state, client = await open_client({"workers":[],"stamp":1})
    try:
        replies = []
        replies.append(await snapshot(await client.post("/api/control/worker-apply", data=b"{")))
        replies.append(await snapshot(await client.post(
            "/api/control/worker-apply", data=b"{", headers=HEADERS)))
        replies.append(await snapshot(await client.post(
            "/api/control/worker-apply", json=[], headers=HEADERS)))
        replies.append(await snapshot(await client.post(
            "/api/control/worker-apply", json={"worker":" ","changes":{}}, headers=HEADERS)))
        replies.append(await snapshot(await client.get("/api/worker")))
        replies.append(await snapshot(await client.get("/api/worker?name=rig&range=1h")))
        replies.append(await snapshot(await client.get("/api/worker?name=boom")))
        return [replies, events]
    finally: await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [reply[0] for reply in result[0]] == [403, 400, 500, 202, 400, 200, 500]
    assert [event[0] for event in result[1]] == ["rig", "boom"]


def test_apply_strip_wait_record_refresh_and_collision_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
RID = "00000000-0000-0000-0000-000000000011"
def validate(changes): events.append(["validate", changes]); return None
def submit(worker, changes, actor): events.append(["submit", worker, changes, actor]); return RID
results = iter([
    {"status":"applied","id":"runner","change_id":"cid","worker":"wrong","reason":"why"},
    None,
])
async def wait(rid, done):
    events.append(["wait", rid, done({"status":"running"}), done({"status":"applied"})])
    return next(results)
def refresh(app, state, worker, changes, res): events.append(["refresh", worker, changes, res])
control_service.validate_worker_changes = validate
control_service.submit_worker_apply = submit
control_service.wait_result = wait
worker_refresh.maybe_refresh_after_apply = refresh
async def main():
    state, client = await open_client()
    def record(*args, **kwargs): events.append(["record", list(args), kwargs])
    state.add_worker_config_version = record
    try:
        depth = {"pass":{"__secret__":True},"tls-fingerprint":{"__secret__":1},"keep":2}
        for _ in range(3): depth = {"nest":depth}
        body = {"worker":"rig","changes":{"pools":[depth],"DONATION":True}}
        replies = [await snapshot(await client.post(
            "/api/control/worker-apply", json=body, headers=HEADERS)) for _ in range(2)]
        return [replies, events]
    finally: await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [reply[0] for reply in result[0]] == [200, 202]
    submits = [event for event in result[1] if event[0] == "submit"]
    assert "pass" not in json.dumps(submits[0][2])
    assert "tls-fingerprint" in json.dumps(submits[0][2])
    record = next(event for event in result[1] if event[0] == "record")
    assert record[1][0] == "rig" and record[1][1] == "cid"
    assert record[1][4] == "why"


def test_apply_validation_submit_and_result_statuses_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
errors = iter(["bad changes", None, None])
def validate(changes): return next(errors)
def submit(*args):
    if len(events) == 0: events.append("failed"); raise OSError("private")
    return "00000000-0000-0000-0000-000000000012"
control_service.validate_worker_changes = validate
control_service.submit_worker_apply = submit
async def main():
    state, client = await open_client()
    try:
        replies = []
        for body in ({"worker":"rig","changes":{}},{"worker":"rig","changes":{}},
                     {"worker":1,"changes":{}}):
            replies.append(await snapshot(await client.post(
                "/api/control/worker-apply", json=body, headers=HEADERS)))
        return replies
    finally: await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [reply[0] for reply in result] == [400, 500, 400]


def test_upgrade_versions_freshness_noop_and_submit_match():
    result = _paired(
        PREAMBLE
        + r"""
from datetime import UTC, datetime
events = []
def submit(worker, version, actor): events.append([worker,version,actor]); return "rid"
control_service.submit_worker_upgrade = submit
async def wait(rid, done, timeout_s): return None
control_service.wait_result = wait
fresh = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
async def main():
    state, client = await open_client({"workers":[{"name":"rig","rigforge":{
        "version":"01.2.3","generated_at":fresh,"stale":False}}]})
    try:
        versions = ["v1.2.3","v1.2.3-rc1","v\u0661.2.4","v\uff11.2.4",
                    "v\U0001d7cf.2.4","v\U00011f50.2.4","v" + "9"*4300 + ".2.4",
                    "v" + "9"*4301 + ".2.4"]
        replies = []
        for version in versions:
            raw = json.dumps({"worker":"rig","version":version}).encode()
            replies.append(await snapshot(await client.post(
                "/api/control/worker-upgrade", data=raw,
                headers={**HEADERS,"Content-Type":"application/json"})))
        tasks = list(client.app["_bg_tasks"])
        if tasks: await asyncio.gather(*tasks)
        return [replies, events]
    finally: await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [reply[0] for reply in result[0]] == [200, 400, 202, 202, 202, 400, 202, 500]
    assert len(result[1]) == 4


def test_upgrade_background_record_refresh_and_failure_match():
    result = _paired(
        PREAMBLE
        + r"""
events = []
results = iter([{"status":"accepted","change_id":"cid","version":"v2.0.0"}, RuntimeError("wait")])
def submit(worker, version, actor): events.append(["submit",worker,version,actor]); return str(len(events))
async def wait(rid, done, timeout_s):
    events.append(["wait",rid,done({"status":"running"}),done({"status":"failed"}),timeout_s])
    value = next(results)
    if isinstance(value, Exception): raise value
    return value
async def refresh(data, worker, version, res): events.append(["refresh",worker,version,res])
control_service.submit_worker_upgrade = submit
control_service.wait_result = wait
worker_refresh.maybe_refresh_after_upgrade = refresh
async def main():
    state, client = await open_client()
    def record(*args, **kwargs): events.append(["record",list(args),kwargs])
    state.add_worker_config_version = record
    try:
        replies = []
        for worker in ("rig-a","rig-b"):
            replies.append(await snapshot(await client.post(
                "/api/control/worker-upgrade", json={"worker":worker,"version":"v2.0.0"},
                headers=HEADERS)))
            tasks = list(client.app["_bg_tasks"])
            if tasks: await asyncio.gather(*tasks, return_exceptions=True)
        return [replies, events]
    finally: await client.close(); state.close()
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [reply[0] for reply in result[0]] == [202, 202]
    assert len([event for event in result[1] if event[0] == "record"]) == 1
    assert len([event for event in result[1] if event[0] == "refresh"]) == 1


def test_upgrade_live_feed_shape_and_python_whitespace_match():
    result = _paired(
        PREAMBLE
        + r"""
from datetime import UTC, datetime
events = []
def submit(worker, version, actor): events.append(worker); return "rid"
async def wait(rid, done, timeout_s): return None
control_service.submit_worker_upgrade = submit
control_service.wait_result = wait
fresh = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
datasets = [
    {}, {"workers":{}}, {"workers":""}, {"workers":{"bad":1}},
    {"workers":[{"name":"rig","rigforge":[]}]},
    {"workers":[{"name":"rig","rigforge":"truthy"}]},
    {"workers":[{"name":"rig","rigforge":{"version":"\u001c1.2.3",
                                                "generated_at":fresh}}]},
    {"workers":[{"name":"rig","rigforge":{"version":True,"generated_at":fresh}}]},
]
async def main():
    replies = []
    for data in datasets:
        state, client = await open_client(data)
        try:
            replies.append(await snapshot(await client.post(
                "/api/control/worker-upgrade", json={"worker":"rig","version":"v1.2.3"},
                headers=HEADERS)))
            tasks = list(client.app["_bg_tasks"])
            if tasks: await asyncio.gather(*tasks)
        finally: await client.close(); state.close()
    return [replies, events]
print(json.dumps(asyncio.run(main()), separators=(",",":")))
"""
    )
    assert [reply[0] for reply in result[0]] == [202, 202, 202, 500, 202, 202, 200, 500]
    assert len(result[1]) == 5


def test_record_status_vocabulary_and_caller_ownership_match():
    result = _paired(
        PREAMBLE
        + r"""
rows = []
class State:
    def add_worker_config_version(self, *args, **kwargs): rows.append([list(args),kwargs])
statuses = ["applied","rejected","rolled_back","accepted","failed","noop","throttled",
            "running","unknown",True]
for status in statuses:
    server._record_worker_result(State(), "caller", {"own":True}, {
        "worker":"other","status":status,"change_id":"id","reason":"","error":"fallback"})
print(json.dumps(rows, separators=(",",":")))
"""
    )
    assert len(result) == 7
    assert all(row[0][0] == "caller" and row[0][3] == {"own": True} for row in result)
    assert all(row[0][4] == "fallback" for row in result)


def test_native_worker_plan_failures_are_fail_closed(monkeypatch):
    from mining_dashboard import go_control_http, go_worker_http

    with monkeypatch.context() as patch:
        patch.setattr(
            go_control_http.go_channel,
            "call",
            lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("unavailable")),
        )
        with pytest.raises(RuntimeError):
            go_worker_http._plan("worker-name", value="rig")

    cases = [
        ({"next": "wrong"}, lambda: go_worker_http._check(go_worker_http._plan("worker-name"))),
        ({"next": "ready"}, lambda: go_worker_http._value("worker-live")),
        ({"done": "yes"}, lambda: go_worker_http._done({"status": "running"})),
        (
            {"next": "record", "value": {}},
            lambda: go_worker_http._record_worker_result(
                object(), "rig", {}, {"status": "applied"}
            ),
        ),
        (
            {"next": "broken"},
            lambda: go_worker_http._record_worker_result(
                object(), "rig", {}, {"status": "applied"}
            ),
        ),
    ]
    for plan, invoke in cases:
        with monkeypatch.context() as patch:
            patch.setattr(go_worker_http, "_plan", lambda *args, _plan=plan, **kwargs: _plan)
            with pytest.raises(RuntimeError):
                invoke()
