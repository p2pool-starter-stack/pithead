import asyncio
import base64
import ipaddress
import logging
import time
from pathlib import Path
from urllib.parse import quote

import aiohttp
from aiohttp import web

from mining_dashboard.service import auth_sessions

logger = logging.getLogger("WebAuth")

COOKIE = "pithead_session"
VERIFY_URL = "http://127.0.0.1:8001/"
EPOCH_HEADER = "X-Pithead-Auth-Epoch"
REFRESH_HEADER = "X-Pithead-Session-Refresh"
LOGIN_TEMPLATE = Path(__file__).parent / "templates" / "login.html"
FAILURE_LIMIT = 5
FAILURE_WINDOW = 60
MAX_TRACKED_CLIENTS = 1024
MAX_CONCURRENT_VERIFY = 4
MAX_LOGIN_BYTES = 4096
MAX_FIELD_CHARS = 256


class Attempts:
    def __init__(self):
        self._failures = {}

    def retry_after(self, key, now=None):
        now = time.monotonic() if now is None else now
        recent = [t for t in self._failures.get(key, ()) if now - t < FAILURE_WINDOW]
        if recent:
            self._failures[key] = recent
        else:
            self._failures.pop(key, None)
        if len(recent) < FAILURE_LIMIT:
            return 0
        return max(1, int(FAILURE_WINDOW - (now - recent[0])) + 1)

    def failed(self, key, now=None):
        now = time.monotonic() if now is None else now
        if key not in self._failures and len(self._failures) >= MAX_TRACKED_CLIENTS:
            self._failures.pop(next(iter(self._failures)))
        self._failures.setdefault(key, []).append(now)


def trusted_proxy(request) -> bool:
    try:
        return ipaddress.ip_address(request.remote).is_loopback
    except (ValueError, TypeError):
        return False


def client_key(request):
    forwarded = request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
    if trusted_proxy(request) and forwarded:
        try:
            return str(ipaddress.ip_address(forwarded))
        except ValueError:
            pass
    return request.remote or "unknown"


def secure(request):
    return request.secure or (
        trusted_proxy(request) and request.headers.get("X-Forwarded-Proto") == "https"
    )


def _set_cookie(request, response, token, remember):
    response.set_cookie(
        COOKIE,
        token,
        max_age=auth_sessions.REMEMBER_SECONDS if remember else None,
        httponly=True,
        samesite="Strict",
        secure=secure(request),
        path="/",
    )


def annotate(request, state):
    state["auth_user"] = request.headers.get("X-Auth-User", "")
    state["auth_session"] = bool(request.cookies.get(COOKIE))
    return state


async def login_page(request):
    return web.FileResponse(LOGIN_TEMPLATE, headers={"Cache-Control": "no-store"})


async def _verify(request, username, password):
    raw = f"{username}:{password}".encode()
    headers = {"Authorization": "Basic " + base64.b64encode(raw).decode()}
    timeout = aiohttp.ClientTimeout(total=5)
    async with aiohttp.ClientSession(timeout=timeout) as http:
        async with http.get(
            request.app["auth"]["verify_url"], headers=headers, allow_redirects=False
        ) as resp:
            if resp.status == 204:
                return True
            if resp.status == 401:
                return False
    raise aiohttp.ClientError("unexpected verifier status")


async def login(request):
    epoch = request.headers.get(EPOCH_HEADER, "")
    if not epoch:
        raise web.HTTPNotFound()
    if request.content_length is None or request.content_length > MAX_LOGIN_BYTES:
        raise web.HTTPBadRequest(text="Invalid login request.")
    try:
        data = await request.json()
    except ValueError:
        raise web.HTTPBadRequest(text="Invalid login request.") from None
    if not isinstance(data, dict):
        raise web.HTTPBadRequest(text="Invalid login request.")
    username, password, remember = data.get("username"), data.get("password"), data.get("remember")
    if not (isinstance(username, str) and isinstance(password, str)):
        raise web.HTTPBadRequest(text="Invalid login request.")
    if len(username) > MAX_FIELD_CHARS or len(password) > MAX_FIELD_CHARS or ":" in username:
        return web.json_response({"error": "Invalid username or password."}, status=401)

    attempts, key = request.app["auth"]["attempts"], client_key(request)
    wait = attempts.retry_after(key)
    if wait or request.app["auth"]["busy"] >= MAX_CONCURRENT_VERIFY:
        raise web.HTTPTooManyRequests(
            text="Too many sign-in attempts. Try again shortly.",
            headers={"Retry-After": str(wait or FAILURE_WINDOW)},
        )
    request.app["auth"]["busy"] += 1
    try:
        ok = await _verify(request, username, password)
    except (aiohttp.ClientError, TimeoutError):
        logger.warning("Sign-in verifier unreachable")
        raise web.HTTPServiceUnavailable(text="Sign-in is temporarily unavailable.") from None
    finally:
        request.app["auth"]["busy"] -= 1
    if not ok:
        attempts.failed(key)
        logger.warning("Failed dashboard sign-in from %s", key)
        return web.json_response({"error": "Invalid username or password."}, status=401)

    remember = remember is True
    token = await asyncio.to_thread(
        auth_sessions.issue, request.app["state_manager"], username, epoch, remember
    )
    response = web.json_response({"ok": True}, headers={"Cache-Control": "no-store"})
    _set_cookie(request, response, token, remember)
    return response


async def logout(request):
    token = request.cookies.get(COOKIE, "")
    if token:
        await asyncio.to_thread(auth_sessions.revoke, request.app["state_manager"], token)
    response = web.json_response({"ok": True}, headers={"Cache-Control": "no-store"})
    response.del_cookie(COOKIE, path="/", httponly=True, samesite="Strict", secure=secure(request))
    return response


def _wants_page(request):
    uri = request.headers.get("X-Forwarded-Uri", "")
    return (
        request.headers.get("X-Forwarded-Method", "GET") == "GET"
        and "text/html" in request.headers.get("Accept", "")
        and not uri.startswith("/api/")
    )


async def check(request):
    session = await asyncio.to_thread(
        auth_sessions.validate,
        request.app["state_manager"],
        request.cookies.get(COOKIE, ""),
        request.headers.get(EPOCH_HEADER, ""),
    )
    if session is None:
        if _wants_page(request):
            uri = request.headers.get("X-Forwarded-Uri", "/")
            target = "/login" if uri == "/" else f"/login?next={quote(uri, safe='')}"
            raise web.HTTPSeeOther(target, headers={"Cache-Control": "no-store"})
        raise web.HTTPUnauthorized(text="Authentication required.")
    username, _, refresh = session
    headers = {"X-Auth-User": username, "Cache-Control": "no-store"}
    if refresh:
        headers[REFRESH_HEADER] = "1"
    return web.Response(status=204, headers=headers)


@web.middleware
async def refresh_middleware(request, handler):
    response = await handler(request)
    token = request.cookies.get(COOKIE, "")
    if token and request.headers.get(REFRESH_HEADER) == "1":
        _set_cookie(request, response, token, True)
    return response


def setup(app):
    auth_sessions.create_schema(app["state_manager"])
    app["auth"] = {"attempts": Attempts(), "busy": 0, "verify_url": VERIFY_URL}
    app.add_routes(
        [
            web.get("/login", login_page),
            web.post("/api/auth/login", login),
            web.post("/api/auth/logout", logout),
            web.get("/api/auth/check", check),
        ]
    )
