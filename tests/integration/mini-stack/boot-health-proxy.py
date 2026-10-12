"""Wire assertions for the real Caddy/dashboard boot probe fixture."""

import base64
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

mode, host = sys.argv[1:]
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
GOOD_AUTH = "Basic " + base64.b64encode(b"admin:fixture-password").decode()
BAD_AUTH = "Basic " + base64.b64encode(b"admin:wrong-password").decode()
PROBE = "/.pithead-boot-health"
CAPABILITY = hashlib.sha256(
    ("pithead-boot-health-v1:" + os.environ["DASHBOARD_AUTH_HASH_B64"]).encode()
).hexdigest()
PORT = 8081 if mode == "proxy" else 8080


def require(condition, detail="wire assertion failed"):
    if not condition:
        raise AssertionError(detail)


def request(path, auth=None, method="GET", headers=None):
    hdrs = {"Host": "panel.example:8080", **(headers or {})}
    if auth:
        hdrs["Authorization"] = auth
    req = urllib.request.Request(f"http://{host}:{PORT}{path}", headers=hdrs, method=method)
    try:
        response = opener.open(req, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.read()


def summary(failures, warning):
    # Access logging is asynchronous; wait for the exact count, never accept an empty log.
    for _ in range(50):
        status, body = request("/api/access", GOOD_AUTH)
        require(status == 200, (status, body[:200]))
        data = json.loads(body)
        if data["available"] and data["failures_24h"] == failures:
            require(data["rotate_hint"] is warning, data)
            return data
        time.sleep(0.1)
    raise AssertionError(data)


if mode == "local":
    for _ in range(60):
        try:
            status, body = request("/", GOOD_AUTH)
            if status == 200 and body:
                break
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(1)
    else:
        raise AssertionError("real dashboard did not serve through Caddy")
    for _ in range(53):
        require(request(PROBE, headers={"X-Pithead-Boot-Probe": CAPABILITY})[0] == 401)
    data = summary(0, False)
    require(any(e["uri"] == PROBE and e["status"] == 401 for e in data["entries"]), data)
    for _ in range(4):
        require(request("/", BAD_AUTH)[0] == 401)
    summary(4, False)
    require(request("/", BAD_AUTH)[0] == 401)
    summary(5, True)
    # Even local wrong credentials on the exact health path are ordinary failures.
    require(request(PROBE, BAD_AUTH, headers={"X-Pithead-Boot-Probe": CAPABILITY})[0] == 401)
    summary(6, True)
elif mode in {"external", "proxy"}:
    forged = {
        "Pithead-Probe": "boot-health-v1",
        "X-Pithead-Probe": "boot-health-v1",
        "X-Pithead-Boot-Probe": "boot-health-v1",
        "X-Forwarded-For": "127.0.0.1",
        "Forwarded": "for=127.0.0.1",
        "User-Agent": "curl",
    }
    # Wait for the front proxy without creating a login failure.
    for _ in range(50):
        try:
            if request("/", GOOD_AUTH)[0] == 200:
                break
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(0.1)
    else:
        raise AssertionError("proxy not ready")
    # Path, query, method and header controls, from a distinct socket peer.
    for path, method in [("/", "GET"), (PROBE, "GET"), (PROBE + "?x=1", "GET"), (PROBE, "POST")]:
        require(request(path, BAD_AUTH, method, forged)[0] == 401)
    require(request(PROBE, headers=forged)[0] == 401)
    if mode == "external":
        # Even a test client holding the capability cannot use it from a remote socket.
        require(request(PROBE, headers={"X-Pithead-Boot-Probe": CAPABILITY})[0] == 401)
elif mode == "final":
    summary(17, True)
    # Loopback alone is not an exemption, nor is a near-match path/method.
    for path, method in [("/", "GET"), (PROBE + "?x=1", "GET"), (PROBE, "HEAD")]:
        require(
            request(path, method=method, headers={"X-Pithead-Boot-Probe": CAPABILITY})[0] == 401
        )
    summary(20, True)
    for value in [None, "boot-health-v1", CAPABILITY[:-1]]:
        headers = {} if value is None else {"X-Pithead-Boot-Probe": value}
        require(request(PROBE, headers=headers)[0] == 401)
    summary(23, True)
elif mode == "unlocked":
    status, body = request(PROBE, headers={"X-Pithead-Boot-Probe": CAPABILITY})
    require(status == 200 and b"<html" in body.lower(), (status, body[:200]))
else:
    raise AssertionError(mode)
