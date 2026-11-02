import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

mode, host = sys.argv[1:]
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


direct_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
GOOD_AUTH = "Basic " + base64.b64encode(b"admin:fixture-password").decode()
BAD_AUTH = "Basic " + base64.b64encode(b"admin:wrong-password").decode()
PROBE = "/.pithead-boot-health"
CAPABILITY = os.environ["DASHBOARD_BOOT_PROBE_TOKEN"]
PORT = 8081 if mode == "proxy" else 8080


def require(condition, detail="wire assertion failed"):
    if not condition:
        raise AssertionError(detail)


def request(path, auth=None, method="GET", headers=None, follow=True):
    hdrs = {"Host": "panel.example:8080", **(headers or {})}
    if auth:
        hdrs["Authorization"] = auth
    req = urllib.request.Request(f"http://{host}:{PORT}{path}", headers=hdrs, method=method)
    try:
        response = (opener if follow else direct_opener).open(req, timeout=5)
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
        require(request(PROBE, headers={"X-Pithead-Boot-Probe": CAPABILITY})[0] == 200)
    data = summary(0, False)
    require(any(e["uri"] == PROBE and e["status"] == 200 for e in data["entries"]), data)
    require(request("/metrics")[0] == 401)
    require(request("/metrics", BAD_AUTH)[0] == 401)
    status, body = request("/metrics", GOOD_AUTH)
    require(status == 200 and b"pithead_shares_accepted_total" in body)
    for _ in range(2):
        require(request("/api/state")[0] == 401)
    summary(4, False)
    require(request("/api/state")[0] == 401)
    summary(5, True)
    require(
        request(PROBE, BAD_AUTH, headers={"X-Pithead-Boot-Probe": CAPABILITY}, follow=False)[0]
        == 303
    )
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
    for path, method in [
        ("/api/state", "GET"),
        ("/api/state?x=1", "GET"),
        ("/api/state", "POST"),
        ("/metrics", "GET"),
    ]:
        require(request(path, method=method, headers=forged)[0] == 401)
    require(request(PROBE, headers=forged, follow=False)[0] == 303)
    if mode == "external":
        require(
            request(PROBE, headers={"X-Pithead-Boot-Probe": CAPABILITY}, follow=False)[0] == 303
        )
elif mode == "final":
    summary(13, True)
    # Loopback alone is not an exemption, nor is a near-match path/method.
    for path, method in [("/", "GET"), (PROBE + "?x=1", "GET"), (PROBE, "HEAD")]:
        require(
            request(
                path,
                method=method,
                headers={"X-Pithead-Boot-Probe": CAPABILITY},
                follow=False,
            )[0]
            == 303
        )
    for value in [None, "boot-health-v1", CAPABILITY[:-1]]:
        headers = {} if value is None else {"X-Pithead-Boot-Probe": value}
        require(request(PROBE, headers=headers, follow=False)[0] == 303)
    summary(13, True)
elif mode == "old-backend":
    for _ in range(60):
        try:
            status, body = request("/", GOOD_AUTH)
            if status == 404:
                break
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(0.5)
    else:
        raise AssertionError("old upstream was not rejected")
elif mode == "unlocked":
    status, body = request(PROBE, headers={"X-Pithead-Boot-Probe": CAPABILITY})
    require(status == 200 and b"<html" in body.lower(), (status, body[:200]))
else:
    raise AssertionError(mode)
