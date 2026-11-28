import asyncio

import pytest

from mining_dashboard.config import config
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web import auth
from mining_dashboard.web.server import create_app

LOCAL = {"Host": "127.0.0.1:8000"}


@pytest.fixture
async def direct(aiohttp_client):
    sm = StateManager(db_path=":memory:")
    client = await aiohttp_client(
        create_app(sm, {"shares": [], "workers": []}), front_headers=False
    )
    yield client
    sm.close()


def front(**extra):
    return {**LOCAL, auth.FRONT_HEADER: config.DASHBOARD_PROXY_SECRET, **extra}


async def test_front_request_is_served(direct):
    resp = await direct.get("/api/state", headers=front())
    assert resp.status == 200


async def test_localhost_name_is_accepted(direct):
    resp = await direct.get("/api/state", headers=front(Host="localhost:8000"))
    assert resp.status == 200


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", "/"),
        ("GET", "/api/state"),
        ("GET", "/metrics"),
        ("GET", "/api/xvb-standby"),
        ("GET", "/api/access"),
        ("GET", "/api/auth/check"),
        ("POST", "/api/auth/login"),
        ("POST", "/api/auth/logout"),
        ("GET", "/login"),
        ("GET", "/static/dashboard.css"),
        ("POST", "/api/control/support-bundle"),
    ],
)
async def test_request_without_the_secret_is_refused(direct, method, path):
    resp = await direct.request(method, path, headers={**LOCAL, "X-Auth-User": "admin"})
    assert resp.status == 403
    assert "web front" in await resp.text()


async def test_wrong_secret_is_refused(direct):
    resp = await direct.get("/api/state", headers={**LOCAL, auth.FRONT_HEADER: "guess"})
    assert resp.status == 403


async def test_undecodable_secret_is_refused(direct):
    reader, writer = await asyncio.open_connection(direct.host, direct.port)
    writer.write(
        b"GET /api/state HTTP/1.1\r\nHost: 127.0.0.1:8000\r\n"
        b"X-Pithead-Proxy-Secret: \xff\r\nConnection: close\r\n\r\n"
    )
    await writer.drain()
    status_line = await reader.readline()
    writer.close()
    assert status_line.split()[1] == b"403"


@pytest.mark.parametrize("host", ["panel.example", "127.0.0.1", "127.0.0.1:8001", "evil:8000"])
async def test_secret_with_another_host_is_refused(direct, host):
    resp = await direct.get("/api/state", headers=front(Host=host))
    assert resp.status == 403


async def test_unset_secret_refuses_everything_but_health(direct, monkeypatch):
    monkeypatch.setattr(config, "DASHBOARD_PROXY_SECRET", "")
    resp = await direct.get("/api/state", headers={**LOCAL, auth.FRONT_HEADER: ""})
    assert resp.status == 403
    resp = await direct.get(auth.HEALTH_PATH, headers=LOCAL)
    assert resp.status == 200


async def test_health_answers_without_the_secret(direct):
    resp = await direct.get(auth.HEALTH_PATH, headers=LOCAL)
    assert resp.status == 200
    assert await resp.text() == "ok"
    resp = await direct.head(auth.HEALTH_PATH, headers=LOCAL)
    assert resp.status == 200


async def test_health_refuses_another_host(direct):
    resp = await direct.get(auth.HEALTH_PATH, headers={"Host": "rebound.example:8000"})
    assert resp.status == 403


async def test_refusal_carries_security_headers(direct):
    resp = await direct.get("/api/state", headers=LOCAL)
    assert resp.status == 403
    assert resp.headers.get("X-Content-Type-Options") == "nosniff"
