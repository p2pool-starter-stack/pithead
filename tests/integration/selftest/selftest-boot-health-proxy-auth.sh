#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export DASHBOARD_BOOT_PROBE_TOKEN=fixture-capability
export BOOT_HEALTH_PROXY_SOURCE="${BOOT_HEALTH_PROXY_SOURCE:-$ROOT/tests/integration/mini-stack/boot-health-proxy.py}"
export BOOT_HEALTH_FRONT_PROXY_SOURCE="${BOOT_HEALTH_FRONT_PROXY_SOURCE:-$ROOT/tests/integration/mini-stack/boot-health-front-proxy.py}"
echo "== boot health proxy session transport =="

python3 - <<'PY'
import base64
import io
import importlib.util
import json
import os

spec = importlib.util.spec_from_file_location("boot_health_proxy", os.environ["BOOT_HEALTH_PROXY_SOURCE"])
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
calls = []


def request(path, **kwargs):
    calls.append((path, kwargs))
    if path == "/login":
        return 303, b""
    if path == "/api/access":
        return 200, json.dumps(
            {"available": True, "failures_24h": 0, "rotate_hint": False}
        ).encode()
    raise AssertionError((path, kwargs))


driver.request = request
driver.login()
driver.summary(0, False)
assert calls == [
    (
        "/login",
        {
            "method": "POST",
            "headers": {"Origin": driver.ORIGIN},
            "follow": False,
            "form": {"username": "admin", "password": "fixture-password"},
            "session": True,
        },
    ),
    ("/api/access", {"session": True}),
]
assert base64.b64decode(driver.METRICS_AUTH.removeprefix("Basic ")).decode() == "metrics:fixture-password"

summaries = []
probe_calls = 0


def local_request(path, auth=None, **kwargs):
    global probe_calls
    if path == "/":
        return 200, b"dashboard"
    if path == driver.PROBE:
        probe_calls += 1
        return (303, b"") if auth == driver.BAD_AUTH else (200, b"dashboard")
    if path == "/metrics":
        return (200, b"pithead_shares_accepted_total") if auth == driver.METRICS_AUTH else (401, b"")
    if path == "/api/state":
        return 401, b""
    raise AssertionError((path, auth, kwargs))


def local_summary(failures, warning):
    summaries.append((failures, warning))
    return {"entries": [{"uri": driver.PROBE, "status": 200}]}


driver.login = lambda: None
driver.request = local_request
driver.summary = local_summary
driver.run("local", "fixture")
assert summaries == [(0, False), (4, False), (5, True), (6, True)]
assert probe_calls == 54

front_spec = importlib.util.spec_from_file_location(
    "boot_health_front_proxy", os.environ["BOOT_HEALTH_FRONT_PROXY_SOURCE"]
)
front = importlib.util.module_from_spec(front_spec)
front_spec.loader.exec_module(front)
upstream_calls = []


class Response:
    status = 303

    def read(self):
        return b""

    def getheaders(self):
        return [
            ("Set-Cookie", "pithead_session=fixture"),
            ("Location", "/"),
            ("Content-Length", "0"),
            ("Connection", "close"),
        ]


class Connection:
    def __init__(self, *_args, **_kwargs):
        pass

    def request(self, method, path, body=None, headers=None):
        upstream_calls.append((method, path, body, headers))

    def getresponse(self):
        return Response()

    def close(self):
        pass


front.http.client.HTTPConnection = Connection
handler = object.__new__(front.FrontProxy)
handler.command = "POST"
handler.path = "/login"
handler.headers = {"Content-Length": "13", "Origin": "fixture-origin"}
handler.rfile = io.BytesIO(b"fixture-login")
handler.wfile = io.BytesIO()
response_headers = []
handler.send_response = lambda status: response_headers.append(("Status", str(status)))
handler.send_header = lambda name, value: response_headers.append((name, value))
handler.end_headers = lambda: None
handler.forward()
assert upstream_calls == [
    ("POST", "/login", b"fixture-login", handler.headers)
]
assert ("Set-Cookie", "pithead_session=fixture") in response_headers
assert ("Location", "/") in response_headers
assert ("Connection", "close") not in response_headers
PY

echo 'selftest-boot-health-proxy-auth: 9 cases passed'
