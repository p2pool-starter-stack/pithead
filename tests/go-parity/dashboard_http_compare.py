# ruff: noqa: S101
import asyncio
import os
import sys
from contextlib import asynccontextmanager

import dashboard_http_plugin
import pytest
from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer
from dashboard_http_plugin import WEB_ROOT, DashboardProcess, reference_create_app
from yarl import URL

from mining_dashboard.config import config
from mining_dashboard.service.storage_service import StateManager

pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"),
]

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": (
        "default-src 'self'; img-src 'self' data:; style-src 'self'; "
        "script-src 'self'; connect-src 'self'; frame-ancestors 'none'; "
        "base-uri 'self'; form-action 'self'"
    ),
}
BASE_ROUTES = {
    "/api/state": "GET",
    "/api/miner-connection": "GET",
    "/api/xvb-standby": "GET",
    "/metrics": "GET",
    "/api/access": "GET",
}
CONTROL_ROUTES = {
    "/api/config": "GET",
    "/api/control/preview": "POST",
    "/api/control/commit": "POST",
    "/api/control/upgrade": "POST",
    "/api/control/result": "GET",
    "/api/audit": "GET",
    "/api/worker": "GET",
    "/api/control/worker-apply": "POST",
    "/api/control/worker-upgrade": "POST",
    "/api/control/backup": "POST",
    "/api/control/backup-download": "GET",
    "/api/control/os-update": "POST",
    "/api/control/diag-doctor": "POST",
    "/api/control/diag-logs": "POST",
    "/api/control/onion-client-key": "POST",
}


def _assert_security(response, cache_control="no-cache"):
    for name, value in SECURITY_HEADERS.items():
        assert response.headers[name] == value
    assert response.headers["Cache-Control"] == cache_control


@asynccontextmanager
async def _process(reference_app, control_enabled):
    server = TestServer(reference_app)
    await server.start_server()
    process = DashboardProcess(str(server.make_url("/")), control_enabled)
    try:
        await process.start()
        async with ClientSession() as session:
            yield process, session
    finally:
        await process.close()
        await server.close()


def _sentinel_app():
    app = web.Application()

    async def sentinel(_request):
        return web.Response(status=299, body=b"python-reference", headers={"X-Reference": "1"})

    app.router.add_route("*", "/{tail:.*}", sentinel)
    return app


async def test_missing_binary_fails_closed(monkeypatch, tmp_path):
    monkeypatch.setattr(dashboard_http_plugin, "BINARY", tmp_path / "missing-dashboard")
    process = DashboardProcess("http://127.0.0.1:1", False)
    with pytest.raises(RuntimeError, match="binary is unavailable"):
        await process.start()
    assert process.process is None
    assert process.url is None


async def test_default_runtime_bootstraps_and_reaps_python_child(monkeypatch, tmp_path):
    package = tmp_path / "mining_dashboard"
    web_root = package / "web"
    templates = web_root / "templates"
    templates.mkdir(parents=True)
    (package / "__init__.py").write_text("")
    child_pid_file = tmp_path / "reference.pid"
    fixture_state = {"source": "python-child", "height": 3811}
    (package / "main.py").write_text(
        "import os\n"
        "from pathlib import Path\n"
        "from aiohttp import web\n"
        "SHUTDOWN_TIMEOUT = 0.1\n"
        "async def state(_request):\n"
        "    return web.json_response({'source': 'python-child', 'height': 3811})\n"
        "def build_app():\n"
        "    Path(os.environ['PITHEAD_REFERENCE_PID_FILE']).write_text(str(os.getpid()))\n"
        "    app = web.Application()\n"
        "    app.router.add_get('/api/state', state)\n"
        "    return app\n"
    )
    index = b"<h1>native Go shell fixture</h1>\n"
    (templates / "index.html").write_bytes(index)
    monkeypatch.delenv("PITHEAD_DASHBOARD_REFERENCE_URL", raising=False)
    monkeypatch.setenv("PITHEAD_REFERENCE_PID_FILE", str(child_pid_file))
    process = DashboardProcess(None, False, web_root=web_root, python=sys.executable)
    reference_pid = None
    go_process = None
    try:
        await process.start()
        go_process = process.process
        async with ClientSession() as session:
            response = await session.get(f"{process.url}/")
            assert response.status == 200
            assert await response.read() == index
            for _ in range(100):
                response = await session.get(f"{process.url}/api/state")
                if response.status == 200:
                    assert await response.json() == fixture_state
                    break
                await response.read()
                await asyncio.sleep(0.01)
            else:
                pytest.fail("Python reference child did not become ready")
        for _ in range(100):
            if child_pid_file.exists():
                reference_pid = int(child_pid_file.read_text())
                break
            await asyncio.sleep(0.01)
        assert reference_pid is not None
    finally:
        await process.close()
    assert go_process.returncode == 0
    for _ in range(100):
        try:
            os.kill(reference_pid, 0)
        except ProcessLookupError:
            break
        await asyncio.sleep(0.01)
    else:
        pytest.fail(f"Python reference child {reference_pid} was not reaped")


async def _snapshot(session, url, method="GET", headers=None):
    async with session.request(
        method, URL(url, encoded=True), headers=headers or {}, allow_redirects=False
    ) as response:
        body = await response.read()
        selected = {
            name.lower(): value
            for name, value in response.headers.items()
            if name.lower()
            in {
                "accept-ranges",
                "allow",
                "cache-control",
                "content-length",
                "content-range",
                "content-security-policy",
                "content-type",
                "etag",
                "last-modified",
                "referrer-policy",
                "x-content-type-options",
                "x-frame-options",
            }
        }
        return response.status, selected, body


@pytest.mark.parametrize("control_enabled", [False, True])
async def test_route_table_and_methods_are_native(control_enabled):
    async with _process(_sentinel_app(), control_enabled) as (process, session):
        for path, status in {
            "/": 200,
            "/ui-preview": 404,
            "/static/dashboard.css": 200,
        }.items():
            response = await session.get(f"{process.url}{path}")
            assert response.status == status, path
            assert response.headers.get("X-Reference") is None
            _assert_security(response)
            response.release()
            response = await session.post(f"{process.url}{path}")
            assert response.status == 405, path
            assert response.headers["Allow"] == "GET,HEAD"
            _assert_security(response)
            response.release()

        for path, method in BASE_ROUTES.items():
            response = await session.request(method, f"{process.url}{path}")
            assert response.status == 299, path
            assert response.headers["X-Reference"] == "1"
            _assert_security(response)
            response.release()
            wrong = "POST" if method == "GET" else "GET"
            response = await session.request(wrong, f"{process.url}{path}")
            assert response.status == 405, path
            expected = "GET,HEAD" if method == "GET" else "POST"
            assert response.headers["Allow"] == expected
            _assert_security(response)
            response.release()

        for path, method in CONTROL_ROUTES.items():
            response = await session.request(method, f"{process.url}{path}")
            assert response.status == (299 if control_enabled else 404), path
            if control_enabled:
                assert response.headers["X-Reference"] == "1"
            _assert_security(response)
            response.release()
            wrong = "POST" if method == "GET" else "GET"
            response = await session.request(wrong, f"{process.url}{path}")
            assert response.status == (405 if control_enabled else 404), path
            _assert_security(response)
            response.release()

        response = await session.get(f"{process.url}/not-a-dashboard-route")
        assert response.status == 404
        _assert_security(response)


async def test_shell_static_and_preview_bypass_reference(monkeypatch):
    monkeypatch.delenv("DASHBOARD_UI_PREVIEW", raising=False)
    async with _process(_sentinel_app(), False) as (process, session):
        index = (WEB_ROOT / "templates" / "index.html").read_bytes()
        css = (WEB_ROOT / "static" / "dashboard.css").read_bytes()
        response = await session.get(f"{process.url}/")
        assert response.status == 200
        assert await response.read() == index
        assert response.headers["Cache-Control"] == "no-cache"
        _assert_security(response)
        response = await session.get(f"{process.url}/static/dashboard.css")
        assert response.status == 200
        assert await response.read() == css
        assert response.headers["Content-Type"] == "text/css"
        _assert_security(response)
        response = await session.get(f"{process.url}/ui-preview")
        assert response.status == 404
        assert await response.read() != b"python-reference"
        _assert_security(response)

    monkeypatch.setenv("DASHBOARD_UI_PREVIEW", "1")
    async with _process(_sentinel_app(), False) as (process, session):
        preview = (WEB_ROOT / "templates" / "sovereign.html").read_bytes()
        response = await session.get(f"{process.url}/ui-preview")
        assert response.status == 200
        assert await response.read() == preview
        assert response.headers["Cache-Control"] == "no-store"
        _assert_security(response, "no-store")


async def test_shell_and_static_wire_contract_matches_python(monkeypatch):
    monkeypatch.delenv("DASHBOARD_UI_PREVIEW", raising=False)
    state_manager = StateManager(db_path=":memory:")
    reference_app = reference_create_app(state_manager, {})
    reference_server = TestServer(reference_app)
    await reference_server.start_server()
    process = DashboardProcess(str(reference_server.make_url("/")), False)
    await process.start()
    try:
        async with ClientSession() as session:
            reference = str(reference_server.make_url("/")).rstrip("/")
            cases = [
                ("GET", "/", {}),
                ("HEAD", "/", {}),
                ("GET", "/static/dashboard.css", {}),
                ("HEAD", "/static/dashboard.css", {}),
                ("GET", "/static/dashboard.css", {"Range": "bytes=0-31"}),
                ("GET", "/static/does-not-exist.js", {}),
                ("GET", "/static", {}),
                ("GET", "/static/", {}),
                ("GET", "/static/app", {}),
                ("GET", "/static/dashboard.js", {}),
                ("GET", "/static/app/components.mjs", {}),
                ("GET", "/static/app/./components.mjs", {}),
                ("GET", "/static/app//components.mjs", {}),
                ("GET", "/static/app/../dashboard.js", {}),
                ("GET", "/static/app/%2e/components.mjs", {}),
                ("GET", "/static/app/%2e%2e/dashboard.js", {}),
                ("GET", "//static/dashboard.css", {}),
                ("GET", "/static/../../templates/index.html", {}),
                ("GET", "/static/%2e%2e/%2e%2e/templates/index.html", {}),
                ("GET", "/static/%2e%2e/templates/index.html", {}),
                ("POST", "/static/dashboard.css", {}),
            ]
            for method, path, headers in cases:
                python = await _snapshot(session, f"{reference}{path}", method, headers)
                go = await _snapshot(session, f"{process.url}{path}", method, headers)
                assert go == python, (method, path)

            initial = await _snapshot(session, f"{process.url}/static/dashboard.css")
            etag = initial[1]["etag"]
            modified = initial[1]["last-modified"]
            for header in ({"If-None-Match": etag}, {"If-Modified-Since": modified}):
                python = await _snapshot(
                    session, f"{reference}/static/dashboard.css", headers=header
                )
                go = await _snapshot(session, f"{process.url}/static/dashboard.css", headers=header)
                assert go == python
    finally:
        await process.close()
        await reference_server.close()
        state_manager.close()


async def test_proxy_restarts_for_preview_environment(aiohttp_client, monkeypatch):
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", False)
    monkeypatch.delenv("DASHBOARD_UI_PREVIEW", raising=False)
    state_manager = StateManager(db_path=":memory:")
    client = await aiohttp_client(
        __import__("mining_dashboard.web.server", fromlist=["create_app"]).create_app(
            state_manager, {}
        )
    )
    try:
        assert (await client.get("/ui-preview")).status == 404
        old_pid = client.app["go_dashboard_proxy"].process.process.pid
        monkeypatch.setenv("DASHBOARD_UI_PREVIEW", "1")
        response = await client.get("/ui-preview")
        assert response.status == 200
        assert client.app["go_dashboard_proxy"].process.process.pid != old_pid
    finally:
        await client.close()
        state_manager.close()
