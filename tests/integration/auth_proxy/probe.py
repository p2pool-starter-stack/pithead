import base64
import http.cookiejar
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

mode = sys.argv[1]
proxy_host = os.environ["PROXY_HOST"]
site_host = os.environ["SITE_HOST"]
site_port = os.environ["SITE_PORT"]
origin = f"https://{site_host}:{site_port}"
connect_origin = f"https://{proxy_host}:{site_port}"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


cookie_jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),  # noqa: S323
    urllib.request.HTTPCookieProcessor(cookie_jar),
    NoRedirect(),
)


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def basic(name, password):
    encoded = base64.b64encode(f"{name}:{password}".encode()).decode()
    return f"Basic {encoded}"


def request(path, method="GET", headers=None, form=None):
    request_headers = {"Host": f"{site_host}:{site_port}", **(headers or {})}
    body = None
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
        request_headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(  # noqa: S310
        connect_origin + path, data=body, headers=request_headers, method=method
    )
    try:
        response = opener.open(req, timeout=8)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def ready():
    outcome = None
    for _ in range(80):
        try:
            status, _, body = request("/login")
            outcome = (status, body[:200])
            if status == 200:
                return
        except (urllib.error.URLError, TimeoutError) as error:
            outcome = repr(error)
        time.sleep(0.25)
    raise AssertionError(f"proxy did not become ready: {outcome}")


if mode == "authenticated":
    ready()
    status, headers, _ = request("/")
    require(status == 303 and headers.get("Location") == "/login", (status, headers))
    status, headers, body = request(
        "/login",
        method="POST",
        headers={"Origin": origin},
        form={"username": os.environ["ADMIN_NAME"], "password": "incorrect"},
    )
    require(status == 401, (status, body))
    require(headers.get("WWW-Authenticate") is None, headers)
    status, headers, _ = request(
        "/login",
        method="POST",
        headers={"Origin": origin, "X-Forwarded-Proto": "http"},
        form={
            "username": os.environ["ADMIN_NAME"],
            "password": os.environ["ADMIN_PASSWORD"],
        },
    )
    require(status == 303 and headers.get("Location") == "/", (status, headers))
    cookie = headers.get("Set-Cookie", "")
    require("Secure" in cookie and "HttpOnly" in cookie and "SameSite=Strict" in cookie, cookie)
    status, _, body = request("/api/auth/session")
    require(status == 200, (status, body))
    session = json.loads(body)
    require(session["role"] == "admin" and session["user"] == os.environ["ADMIN_NAME"], session)
    status, _, _ = request("/logout", method="POST", headers={"Origin": origin})
    require(status == 303, status)
    require(request("/api/auth/session")[0] == 401, "logout left the session usable")

    viewer_jar = http.cookiejar.CookieJar()
    opener.add_handler(urllib.request.HTTPCookieProcessor(viewer_jar))
    status, _, _ = request(
        "/login",
        method="POST",
        headers={"Origin": origin},
        form={
            "username": os.environ["VIEWER_NAME"],
            "password": os.environ["VIEWER_PASSWORD"],
        },
    )
    require(status == 303, status)
    status, _, body = request(
        "/api/auth/hash",
        method="POST",
        headers={
            "Origin": origin,
            "Content-Type": "application/json",
            "X-Auth-User": os.environ["ADMIN_NAME"],
            "X-Pithead-Control": "1",
        },
    )
    require(status == 403 and b"Read-only account" in body, (status, body))

    cookie_jar.clear()
    viewer_jar.clear()
    machine = basic("metrics", os.environ["METRICS_PASSWORD"])
    status, _, body = request("/metrics", headers={"Authorization": machine})
    require(status == 200 and b"# TYPE pithead_" in body, (status, body[:200]))
    require(
        request("/api/auth/session", headers={"Authorization": machine})[0] == 401,
        "monitoring credential escaped the metrics route",
    )
elif mode == "disabled":
    ready()
    status, _, body = request("/api/auth/session")
    require(status == 200 and json.loads(body)["enabled"] is False, (status, body))
    require(request("/")[0] == 200, "authentication-off dashboard was not public")
elif mode == "stale":
    for _ in range(80):
        try:
            status, _, body = request("/")
            if status != 502:
                break
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(0.25)
    require(status == 404 and b"legacy dashboard" not in body, (status, body))
else:
    raise AssertionError(mode)
