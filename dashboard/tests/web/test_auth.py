import asyncio
import base64

import pytest
from aiohttp import web

from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web import auth
from mining_dashboard.web.server import create_app

EPOCH = {auth.EPOCH_HEADER: "epoch-one"}
GOOD = ("admin", "correct horse")


def verifier_app(calls):
    async def verify(request):
        calls.append(request.headers.get("Authorization", ""))
        expected = "Basic " + base64.b64encode(":".join(GOOD).encode()).decode()
        if request.headers.get("Authorization") == expected:
            return web.Response(status=204)
        return web.Response(status=401, headers={"WWW-Authenticate": 'Basic realm="restricted"'})

    app = web.Application()
    app.router.add_get("/", verify)
    return app


@pytest.fixture
async def verifier_calls():
    return []


@pytest.fixture
async def stack(aiohttp_client, verifier_calls):
    verifier = await aiohttp_client(verifier_app(verifier_calls))
    sm = StateManager(db_path=":memory:")
    app = create_app(sm, {"shares": [], "workers": []})
    app["auth"]["verify_url"] = str(verifier.make_url("/"))
    client = await aiohttp_client(app)
    yield client
    sm.close()


def login(client, user=GOOD[0], password=GOOD[1], remember=False, headers=EPOCH, **extra):
    body = {"username": user, "password": password, "remember": remember, **extra}
    return client.post("/api/auth/login", json=body, headers=headers)


def cookie_of(resp):
    return resp.headers["Set-Cookie"]


class TestLogin:
    async def test_success_sets_session_cookie_without_max_age(self, stack):
        resp = await login(stack)
        assert resp.status == 200
        cookie = cookie_of(resp)
        assert cookie.startswith(f"{auth.COOKIE}=")
        assert "HttpOnly" in cookie
        assert "SameSite=Strict" in cookie
        assert "Max-Age" not in cookie
        assert "Secure" not in cookie

    async def test_remember_sets_thirty_day_cookie(self, stack):
        resp = await login(stack, remember=True)
        assert f"Max-Age={30 * 86400}" in cookie_of(resp)

    async def test_remember_must_be_literal_true(self, stack):
        resp = await login(stack, remember="yes")
        assert "Max-Age" not in cookie_of(resp)

    async def test_cookie_secure_when_proxy_reports_https(self, stack):
        resp = await login(stack, headers={**EPOCH, "X-Forwarded-Proto": "https"})
        assert "Secure" in cookie_of(resp)

    async def test_wrong_password_is_401_with_no_cookie(self, stack):
        resp = await login(stack, password="nope")
        assert resp.status == 401
        assert "Set-Cookie" not in resp.headers
        assert (await resp.json())["error"] == "Invalid username or password."

    async def test_wrong_user_is_401(self, stack):
        assert (await login(stack, user="root")).status == 401

    async def test_username_with_colon_never_reaches_the_verifier(self, stack, verifier_calls):
        assert (await login(stack, user="admin:x", password="y")).status == 401
        assert verifier_calls == []

    async def test_missing_epoch_header_is_404(self, stack):
        assert (await login(stack, headers={})).status == 404

    async def test_malformed_bodies_are_400(self, stack):
        for payload in ("not json", "[]", '{"username": 1, "password": "x"}'):
            resp = await stack.post(
                "/api/auth/login",
                data=payload,
                headers={**EPOCH, "Content-Type": "application/json"},
            )
            assert resp.status == 400

    async def test_verifier_down_is_503(self, stack):
        stack.app["auth"]["verify_url"] = "http://127.0.0.1:9/"
        assert (await login(stack)).status == 503

    async def test_repeated_failures_are_rate_limited(self, stack, verifier_calls):
        for _ in range(auth.FAILURE_LIMIT):
            assert (await login(stack, password="nope")).status == 401
        resp = await login(stack, password="nope")
        assert resp.status == 429
        assert int(resp.headers["Retry-After"]) >= 1
        before = len(verifier_calls)
        assert (await login(stack)).status == 429
        assert len(verifier_calls) == before

    async def test_rate_limit_is_per_client(self, stack):
        for _ in range(auth.FAILURE_LIMIT):
            await login(stack, password="nope", headers={**EPOCH, "X-Forwarded-For": "10.0.0.1"})
        other = await login(stack, headers={**EPOCH, "X-Forwarded-For": "10.0.0.2"})
        assert other.status == 200

    async def test_concurrent_verifications_beyond_the_cap_are_refused(self, stack):
        release = asyncio.Event()
        started = []
        real = auth._verify

        async def held(request, username, password):
            started.append(username)
            await release.wait()
            return await real(request, username, password)

        auth._verify = held
        try:
            pending = [
                asyncio.ensure_future(
                    login(stack, headers={**EPOCH, "X-Forwarded-For": f"10.0.1.{n}"})
                )
                for n in range(auth.MAX_CONCURRENT_VERIFY)
            ]
            for _ in range(100):
                if len(started) == auth.MAX_CONCURRENT_VERIFY:
                    break
                await asyncio.sleep(0.01)
            assert len(started) == auth.MAX_CONCURRENT_VERIFY
            extra = await login(stack, headers={**EPOCH, "X-Forwarded-For": "10.0.1.99"})
            assert extra.status == 429
            release.set()
            assert [r.status for r in await asyncio.gather(*pending)] == [200] * len(pending)
        finally:
            auth._verify = real
            release.set()
        assert stack.app["auth"]["busy"] == 0

    async def test_login_page_is_served(self, stack):
        resp = await stack.get("/login")
        assert resp.status == 200
        assert 'id="login-form"' in await resp.text()
        assert 'id="login-remember"' in await resp.text()


class TestCheck:
    async def signed_in(self, stack, **kw):
        await login(stack, **kw)

    async def test_valid_session_returns_user(self, stack):
        await self.signed_in(stack)
        resp = await stack.get("/api/auth/check", headers=EPOCH)
        assert resp.status == 204
        assert resp.headers["X-Auth-User"] == "admin"

    async def test_no_cookie_api_request_is_401(self, stack):
        resp = await stack.get(
            "/api/auth/check", headers={**EPOCH, "X-Forwarded-Uri": "/api/state"}
        )
        assert resp.status == 401

    async def test_no_cookie_browser_navigation_redirects_to_login(self, stack):
        resp = await stack.get(
            "/api/auth/check",
            headers={**EPOCH, "Accept": "text/html", "X-Forwarded-Uri": "/"},
            allow_redirects=False,
        )
        assert resp.status == 303
        assert resp.headers["Location"] == "/login"

    async def test_missing_epoch_is_401(self, stack):
        await self.signed_in(stack)
        assert (await stack.get("/api/auth/check")).status == 401

    async def test_password_change_ends_every_session(self, stack):
        await self.signed_in(stack)
        await self.signed_in(stack, remember=True)
        changed = {auth.EPOCH_HEADER: "epoch-two"}
        assert (await stack.get("/api/auth/check", headers=changed)).status == 401
        assert (await stack.get("/api/auth/check", headers=EPOCH)).status == 401

    async def test_new_login_after_change_drops_stale_sessions(self, stack):
        await self.signed_in(stack)
        await login(stack, headers={auth.EPOCH_HEADER: "epoch-two"})
        rows = (
            stack.app["state_manager"]
            ._conn.execute("SELECT DISTINCT epoch FROM dashboard_sessions")
            .fetchall()
        )
        assert [r["epoch"] for r in rows] == ["epoch-two"]

    async def test_logout_ends_the_session_at_once(self, stack):
        await self.signed_in(stack)
        resp = await stack.post("/api/auth/logout")
        assert resp.status == 200
        assert "Max-Age=0" in cookie_of(resp)
        stack.session.cookie_jar.clear()
        assert (await stack.get("/api/auth/check", headers=EPOCH)).status == 401

    async def test_logout_revokes_server_side_even_if_cookie_is_replayed(self, stack):
        resp = await login(stack)
        token = cookie_of(resp).split(";")[0].split("=", 1)[1]
        await stack.post("/api/auth/logout")
        replay = await stack.get("/api/auth/check", headers=EPOCH, cookies={auth.COOKIE: token})
        assert replay.status == 401


class TestStateAndRefresh:
    async def test_state_reports_the_signed_in_user(self, stack):
        await login(stack)
        body = await (await stack.get("/api/state", headers={"X-Auth-User": "admin"})).json()
        assert body["auth_user"] == "admin"
        assert body["auth_session"] is True

    async def test_state_without_a_session_has_no_signout(self, stack):
        body = await (await stack.get("/api/state", headers={"X-Auth-User": "admin"})).json()
        assert body["auth_session"] is False

    async def test_refresh_header_reissues_the_remember_cookie(self, stack):
        token = cookie_of(await login(stack, remember=True)).split(";")[0].split("=", 1)[1]
        resp = await stack.get(
            "/api/state",
            headers={auth.REFRESH_HEADER: "1"},
            cookies={auth.COOKIE: token},
        )
        assert f"Max-Age={30 * 86400}" in cookie_of(resp)
        assert token in cookie_of(resp)

    async def test_no_refresh_header_leaves_cookies_alone(self, stack):
        resp = await stack.get("/api/state", cookies={auth.COOKIE: "abc"})
        assert "Set-Cookie" not in resp.headers


class TestAttempts:
    def test_limit_opens_after_the_window(self):
        attempts = auth.Attempts()
        for _ in range(auth.FAILURE_LIMIT):
            attempts.failed("a", now=100.0)
        assert attempts.retry_after("a", now=100.0) > 0
        assert attempts.retry_after("a", now=100.0 + auth.FAILURE_WINDOW) == 0

    def test_tracked_clients_are_bounded_and_evict_the_oldest(self):
        attempts = auth.Attempts()
        for n in range(auth.MAX_TRACKED_CLIENTS):
            attempts.failed(f"c{n}", now=1.0)
        for _ in range(auth.FAILURE_LIMIT - 1):
            attempts.failed("c0", now=1.0)
        attempts.failed("new", now=1.0)
        assert len(attempts._failures) == auth.MAX_TRACKED_CLIENTS
        assert "c0" not in attempts._failures
        assert "new" in attempts._failures
