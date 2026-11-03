import asyncio
import base64
import binascii
import ipaddress
import json
import os
import secrets
import sqlite3
from pathlib import Path

from aiohttp import web

from mining_dashboard.service import auth_sessions, dashboard_auth

COOKIE = "pithead_session"
SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})
MACHINE_ROUTES = {
    "/metrics": ("metrics", "metrics_password_hash"),
    "/api/xvb-standby": ("standby", "standby_password_hash"),
}
LOGIN_ASSETS = frozenset(
    {
        "/static/pithead-mark.svg",
        "/static/sovereign/theme-init.js",
        "/static/sovereign/tokens.css",
        "/static/login.css",
        "/static/login.js",
    }
)
LOGIN_TEMPLATE = Path(__file__).parent / "templates" / "login.html"


def trusted_proxy(request) -> bool:
    try:
        return ipaddress.ip_address(request.remote).is_loopback
    except (ValueError, TypeError):
        return False


def secure(request):
    return request.secure or (
        trusted_proxy(request) and request.headers.get("X-Forwarded-Proto") == "https"
    )


def client_key(request):
    forwarded = request.headers.get("X-Forwarded-For", "")
    if trusted_proxy(request) and forwarded:
        try:
            return str(ipaddress.ip_address(forwarded))
        except ValueError:
            pass
    return request.remote or "unknown"


def require_origin(request):
    origin = request.headers.get("Origin")
    expected = f"{'https' if secure(request) else 'http'}://{request.host}"
    if origin != expected:
        raise web.HTTPForbidden(text="Request origin refused.")


def session_info(request):
    return request.get("auth", {"enabled": False, "user": "", "role": "admin"})


def decorate_state(request, body):
    if "auth" not in request:
        return body
    body["auth"] = session_info(request)
    if body["auth"]["role"] == "viewer":
        body["control_enabled"] = False
    return body


def viewer_result(request, body):
    if session_info(request)["role"] != "viewer":
        return body
    hidden = {"passphrase", "client_key", "torrc_line"}
    return {k: v for k, v in body.items() if k not in hidden}


def _unauthorized(request):
    if request.path.startswith("/api/") or request.path == "/metrics":
        raise web.HTTPUnauthorized(text="Authentication required.")
    raise web.HTTPSeeOther("/login")


def _credentials(request):
    value = request.headers.get("Authorization", "")
    if len(value) > 1024:
        return "", ""
    try:
        if value.startswith("Basic "):
            raw = base64.b64decode(value[6:], validate=True).decode()
            name, password = raw.split(":", 1)
            return name, password
        if value.startswith("Bearer ") and request.path == "/metrics":
            return "metrics", value[7:]
    except (ValueError, UnicodeError, binascii.Error):
        pass
    return "", ""


async def _check_password(request, name, password, machine=False):
    attempts = request.app["auth_runtime"]["attempts"]
    entry = attempts.start(client_key(request))
    if entry is None or request.app["auth_runtime"]["busy"] >= 4:
        raise web.HTTPTooManyRequests(
            text="Please try again shortly.",
            headers={"Retry-After": str(dashboard_auth.FAILURE_WINDOW)},
        )
    cfg = request["auth_config"]
    if machine:
        account, key = MACHINE_ROUTES[request.path]
        hashed = cfg.get(key, "")
        hashes = {hashed[4:6]: hashed} if hashed else {}
        user = (
            {"name": account, "role": "viewer", "password_hash": hashed}
            if name == account and hashed
            else None
        )
    else:
        user = cfg["users"].get(name)
        hashes = {u["password_hash"][4:6]: u["password_hash"] for u in cfg["users"].values()}
    if user:
        hashes[user["password_hash"][4:6]] = user["password_hash"]
    request.app["auth_runtime"]["busy"] += 1
    try:
        matched = False
        for cost in sorted(hashes):
            hashed = hashes[cost]
            verified = await asyncio.to_thread(dashboard_auth.verify, password, hashed)
            if user and hashed == user["password_hash"]:
                matched = verified
        if matched:
            attempts.success(entry)
            return user
    finally:
        request.app["auth_runtime"]["busy"] -= 1
    return None


@web.middleware
async def middleware(request, handler):
    if request.path in LOGIN_ASSETS and request.method in {"GET", "HEAD"}:
        return await handler(request)
    try:
        cfg = await asyncio.to_thread(dashboard_auth.load)
        request["auth_config"] = cfg
        enabled = bool(cfg["users"])
        signature = json.dumps(cfg, sort_keys=True)
        if cfg["configured"] and request.app["auth_runtime"].get("signature") != signature:
            await asyncio.to_thread(
                auth_sessions.reconcile, request.app["state_manager"], cfg["users"]
            )
            request.app["auth_runtime"]["signature"] = signature
        if request.path == "/login":
            return await handler(request)
        if request.path == "/api/auth/ready" and request.method in {"GET", "HEAD"}:
            return await handler(request)
        if (
            request.method in {"GET", "HEAD"}
            and request.path == "/"
            and trusted_proxy(request)
            and request.headers.get("X-Pithead-Boot-Probe") == "boot-health-v1"
        ):
            return await handler(request)
        machine_route = MACHINE_ROUTES.get(request.path)
        if not enabled and not (machine_route and cfg.get(machine_route[1])):
            return await handler(request)
        token = os.environ.get("DASHBOARD_BOOT_PROBE_TOKEN", "")
        user = None
        if (
            request.path == "/api/state"
            and request.method in {"GET", "HEAD"}
            and trusted_proxy(request)
            and not any(
                key.lower() == "forwarded" or key.lower().startswith("x-forwarded-")
                for key in request.headers
            )
            and token
            and secrets.compare_digest(
                request.headers.get("Authorization", "").encode(), f"Bearer {token}".encode()
            )
        ):
            user = {"name": "local-state", "role": "viewer"}
        if not user:
            user = await asyncio.to_thread(
                auth_sessions.authenticate,
                request.app["state_manager"],
                request.cookies.get(COOKIE, ""),
                cfg["users"],
                secure(request),
            )
        if (
            not user
            and machine_route
            and request.method in {"GET", "HEAD"}
            and request.headers.get("Authorization")
        ):
            name, password = _credentials(request)
            user = await _check_password(request, name, password, machine=True)
        if not user:
            _unauthorized(request)
        if request.method not in SAFE_METHODS:
            if user["role"] != "admin" and request.path != "/logout":
                raise web.HTTPForbidden(text="Read-only account.")
            require_origin(request)
        headers = request.headers.copy()
        headers["X-Auth-User"] = user["name"]
        request = request.clone(headers=headers)
        request["auth"] = {"enabled": True, "user": user["name"], "role": user["role"]}
        response = await handler(request)
        response.headers["Cache-Control"] = "no-store"
        return response
    except (OSError, ValueError, sqlite3.Error, TypeError):
        raise web.HTTPServiceUnavailable(
            text="Authentication is temporarily unavailable."
        ) from None


async def login_page(request):
    return web.FileResponse(LOGIN_TEMPLATE, headers={"Cache-Control": "no-store"})


async def login(request):
    require_origin(request)
    if request.content_length is None or request.content_length > 4096:
        raise web.HTTPBadRequest(text="Invalid login request.")
    form = await request.post()
    name, password = form.get("username", ""), form.get("password", "")
    if not isinstance(name, str) or not isinstance(password, str):
        raise web.HTTPBadRequest(text="Invalid login request.")
    user = await _check_password(request, name, password)
    if not user:
        return web.json_response({"error": "Invalid username or password."}, status=401)
    token = await asyncio.to_thread(
        auth_sessions.issue,
        request.app["state_manager"],
        user,
        secure(request),
        request.cookies.get(COOKIE, ""),
    )
    response = web.HTTPSeeOther("/")
    response.set_cookie(
        COOKIE,
        token,
        httponly=True,
        samesite="Strict",
        secure=secure(request),
        max_age=auth_sessions.ABSOLUTE_SECONDS,
        path="/",
    )
    response.headers["Cache-Control"] = "no-store"
    raise response


async def logout(request):
    require_origin(request)
    await asyncio.to_thread(
        auth_sessions.revoke, request.app["state_manager"], request.cookies.get(COOKIE, "")
    )
    response = web.HTTPSeeOther("/login")
    response.del_cookie(COOKIE, path="/", httponly=True, samesite="Strict", secure=secure(request))
    response.headers["Cache-Control"] = "no-store"
    raise response


async def identity(request):
    return web.json_response(session_info(request), headers={"Cache-Control": "no-store"})


async def ready(request):
    if not request["auth_config"]["configured"]:
        raise web.HTTPServiceUnavailable(text="Authentication configuration required.")
    return web.Response(
        status=204, headers={"X-Pithead-Auth-Protocol": "sessions-v1", "Cache-Control": "no-store"}
    )


async def password_hash(request):
    identity = session_info(request)
    if not identity["enabled"] or identity["role"] != "admin":
        raise web.HTTPForbidden(text="An administrator login is required.")
    if request.headers.get("X-Pithead-Control") != "1":
        raise web.HTTPForbidden(text="Missing X-Pithead-Control header.")
    if request.content_length is None or request.content_length > 4096:
        raise web.HTTPBadRequest(text="Invalid password request.")
    try:
        data = await request.json()
        raw = data.get("password") if isinstance(data, dict) else None
        dashboard_auth.password_bytes(raw, minimum=8)
    except (ValueError, UnicodeError):
        raise web.HTTPBadRequest(
            text="Use at least 8 characters and at most 72 UTF-8 bytes, without NUL."
        ) from None
    if request.app["auth_runtime"]["busy"] >= 4:
        raise web.HTTPTooManyRequests(text="Please try again shortly.")
    request.app["auth_runtime"]["busy"] += 1
    try:
        hashed = await asyncio.to_thread(dashboard_auth.hash_password, raw)
    finally:
        request.app["auth_runtime"]["busy"] -= 1
    return web.json_response({"password_hash": hashed}, headers={"Cache-Control": "no-store"})


def setup(app):
    app["auth_runtime"] = {"attempts": dashboard_auth.Attempts(), "busy": 0}
    app.add_routes(
        [
            web.get("/login", login_page),
            web.post("/login", login),
            web.post("/logout", logout),
            web.get("/api/auth/session", identity),
            web.get("/api/auth/ready", ready),
            web.post("/api/auth/hash", password_hash),
        ]
    )
