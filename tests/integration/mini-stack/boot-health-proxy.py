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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


raw_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)


def call(path, method="GET", headers=None, body=None, auth=None):
    hdrs = {"Host": "panel.example:8080", **(headers or {})}
    if auth:
        hdrs["Authorization"] = auth
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(f"http://{host}:{PORT}{path}", data=data, headers=hdrs, method=method)
    try:
        response = raw_opener.open(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def sign_in(password, remember=False):
    return call(
        "/api/auth/login", "POST", body={"username": "admin", "password": password, "remember": remember}
    )


def session_cookie(headers):
    return headers["Set-Cookie"].split(";", 1)[0]


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
elif mode == "login":
    status, _, body = call("/login")
    require(status == 200 and b'id="login-form"' in body, status)
    for asset in ("/static/login.js", "/static/login-next.mjs", "/static/dashboard.css"):
        require(call(asset)[0] == 200, asset)
    require(call("/static/dashboard.js")[0] == 401)
    status, headers, _ = call("/", headers={"Accept": "text/html"})
    require(status == 303 and headers["Location"].startswith("/login"), (status, headers))
    require(call("/api/state")[0] == 401)
    require(call("/api/auth/check")[0] == 401)
    status, headers, _ = sign_in("wrong-password")
    require(status == 401 and "Set-Cookie" not in headers, status)

    status, headers, _ = sign_in("fixture-password")
    require(status == 200, status)
    set_cookie = headers["Set-Cookie"]
    require("HttpOnly" in set_cookie and "SameSite=Strict" in set_cookie, set_cookie)
    require("Max-Age" not in set_cookie, set_cookie)
    cookie = session_cookie(headers)
    status, _, body = call("/api/state", headers={"Cookie": cookie, "X-Auth-User": "evil"})
    state = json.loads(body)
    require(status == 200 and state["auth_user"] == "admin", (status, state.get("auth_user")))
    require(state["auth_session"] is True)
    status, _, body = call("/api/state", auth=GOOD_AUTH, headers={"X-Auth-User": "evil"})
    require(status == 200 and json.loads(body)["auth_user"] == "admin")
    require(call("/api/state", headers={"X-Auth-User": "admin"})[0] == 401)

    status, headers, _ = sign_in("fixture-password", remember=True)
    require(status == 200 and "Max-Age=2592000" in headers["Set-Cookie"], headers["Set-Cookie"])
    remembered = session_cookie(headers)
    require(call("/api/state", headers={"Cookie": remembered})[0] == 200)

    require(call("/api/auth/logout", "POST", headers={"Cookie": cookie})[0] == 200)
    require(call("/api/state", headers={"Cookie": cookie})[0] == 401)
    require(call("/api/state", headers={"Cookie": remembered})[0] == 200)
    print("COOKIE=" + remembered)
elif mode == "rotated":
    old = os.environ["OLD_COOKIE"]
    require(call("/api/state", headers={"Cookie": old})[0] == 401)
    require(call("/api/state", auth=GOOD_AUTH)[0] == 401)
    status, headers, _ = sign_in("rotated-password")
    require(status == 200, status)
    fresh = session_cookie(headers)
    require(call("/api/state", headers={"Cookie": fresh})[0] == 200)
    statuses = [sign_in("wrong-password")[0] for _ in range(7)]
    require(statuses[0] == 401 and statuses[-1] == 429 and 429 in statuses, statuses)
    status, headers, _ = sign_in("rotated-password")
    require(status == 429 and int(headers["Retry-After"]) >= 1, status)
    for _ in range(50):
        entries = json.loads(call("/api/access", headers={"Cookie": fresh})[2])["entries"]
        seen = {e["status"] for e in entries if e["uri"] == "/api/auth/login"}
        if {200, 401, 429} <= seen:
            break
        time.sleep(0.1)
    else:
        raise AssertionError(seen)
elif mode == "unlocked":
    status, body = request(PROBE, headers={"X-Pithead-Boot-Probe": CAPABILITY})
    require(status == 200 and b"<html" in body.lower(), (status, body[:200]))
    require(call("/login")[0] == 404 and call("/api/auth/login", "POST", body={})[0] == 404)
else:
    raise AssertionError(mode)
