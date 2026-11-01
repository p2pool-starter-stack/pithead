import asyncio
import os
import socket
import subprocess
from pathlib import Path

from aiohttp import ClientSession, ClientTimeout, web
from aiohttp.test_utils import TestServer

REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / "go" / "bin" / "dashboard"
WEB_ROOT = REPO_ROOT / "dashboard" / "mining_dashboard" / "web"
HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}
_ORIGINAL_CREATE_APP = None


class DashboardProcess:
    def __init__(
        self,
        reference_url,
        control_enabled,
        web_root=WEB_ROOT,
        python=None,
    ):
        self.reference_url = reference_url.rstrip("/") if reference_url else None
        self.control_enabled = control_enabled
        self.web_root = web_root
        self.python = python
        self.preview_enabled = None
        self.process = None
        self.url = None

    async def start(self):
        await self.close()
        if not BINARY.is_file() or not os.access(BINARY, os.X_OK):
            raise RuntimeError(f"Go dashboard binary is unavailable: {BINARY}")
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(socket.SOMAXCONN)
        listener.set_inheritable(True)
        port = listener.getsockname()[1]
        env = os.environ.copy()
        env.update(
            {
                "PITHEAD_DASHBOARD_LISTEN_FD": str(listener.fileno()),
                "PITHEAD_DASHBOARD_WEB_ROOT": str(self.web_root),
                "DASHBOARD_CONTROL_ENABLED": "true" if self.control_enabled else "false",
            }
        )
        if self.reference_url is None:
            env.pop("PITHEAD_DASHBOARD_REFERENCE_URL", None)
        else:
            env["PITHEAD_DASHBOARD_REFERENCE_URL"] = self.reference_url
        if self.python is not None:
            env["PITHEAD_DASHBOARD_PYTHON"] = str(self.python)
        self.preview_enabled = env.get("DASHBOARD_UI_PREVIEW") == "1"
        try:
            self.process = await asyncio.create_subprocess_exec(
                str(BINARY),
                cwd=REPO_ROOT,
                env=env,
                pass_fds=(listener.fileno(),),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        finally:
            listener.close()
        self.url = f"http://127.0.0.1:{port}"
        try:
            await self._wait_ready()
        except Exception:
            await self.close()
            raise

    async def restart_if_needed(self):
        if self.preview_enabled != (os.environ.get("DASHBOARD_UI_PREVIEW") == "1"):
            await self.start()

    async def _wait_ready(self):
        timeout = ClientTimeout(total=0.2)
        async with ClientSession(timeout=timeout) as session:
            for _ in range(100):
                if self.process.returncode is not None:
                    raise RuntimeError(
                        f"Go dashboard exited during startup with {self.process.returncode}"
                    )
                try:
                    async with session.get(f"{self.url}/") as response:
                        await response.read()
                        return
                except (OSError, TimeoutError):
                    await asyncio.sleep(0.01)
        raise RuntimeError("Go dashboard did not accept HTTP requests")

    async def close(self):
        process = self.process
        self.process = None
        self.url = None
        if process is None or process.returncode is not None:
            return
        process.terminate()
        try:
            await asyncio.wait_for(process.wait(), timeout=2)
        except TimeoutError:
            process.kill()
            await process.wait()


class DashboardProxy:
    def __init__(self, reference_app, control_enabled):
        self.reference_app = reference_app
        self.control_enabled = control_enabled
        self.reference_server = None
        self.process = None
        self.session = None
        self.lock = asyncio.Lock()

    async def start(self):
        self.reference_server = TestServer(self.reference_app)
        await self.reference_server.start_server()
        reference_url = str(self.reference_server.make_url("/"))
        self.process = DashboardProcess(reference_url, self.control_enabled)
        try:
            await self.process.start()
            self.session = ClientSession(timeout=ClientTimeout(total=30))
        except Exception:
            await self.close()
            raise

    async def close(self):
        if self.session is not None:
            await self.session.close()
            self.session = None
        if self.process is not None:
            await self.process.close()
            self.process = None
        if self.reference_server is not None:
            await self.reference_server.close()
            self.reference_server = None

    async def forward(self, request):
        async with self.lock:
            await self.process.restart_if_needed()
        body = await request.read()
        headers = {
            name: value
            for name, value in request.headers.items()
            if name.lower() not in HOP_HEADERS | {"host", "content-length"}
        }
        async with self.session.request(
            request.method,
            f"{self.process.url}{request.rel_url}",
            data=body,
            headers=headers,
            allow_redirects=False,
        ) as upstream:
            response_body = await upstream.read()
            response_headers = [
                (name, value)
                for name, value in upstream.headers.items()
                if name.lower() not in HOP_HEADERS
            ]
            return web.Response(
                status=upstream.status,
                reason=upstream.reason,
                headers=response_headers,
                body=response_body,
            )


def reference_create_app(state_manager, latest_data_ref):
    if _ORIGINAL_CREATE_APP is None:
        raise RuntimeError("dashboard HTTP parity plugin is not configured")
    return _ORIGINAL_CREATE_APP(state_manager, latest_data_ref)


def _proxy_create_app(state_manager, latest_data_ref):
    from mining_dashboard.config import config

    reference_app = reference_create_app(state_manager, latest_data_ref)
    app = web.Application()
    for key, value in reference_app.items():
        app[key] = value
    proxy = DashboardProxy(reference_app, config.DASHBOARD_CONTROL_ENABLED)
    app["go_dashboard_proxy"] = proxy

    async def start(_app):
        await proxy.start()

    async def close(_app):
        await proxy.close()

    app.on_startup.append(start)
    app.on_cleanup.append(close)
    app.router.add_route("*", "/{tail:.*}", proxy.forward)
    return app


def pytest_configure(config):
    global _ORIGINAL_CREATE_APP
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    from mining_dashboard.web import server

    if _ORIGINAL_CREATE_APP is None:
        _ORIGINAL_CREATE_APP = server.create_app
    server.create_app = _proxy_create_app
