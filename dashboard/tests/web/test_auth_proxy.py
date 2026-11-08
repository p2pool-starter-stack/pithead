import ipaddress
from types import SimpleNamespace

from mining_dashboard.web import auth


def test_forwarded_headers_are_trusted_only_from_loopback():
    request = SimpleNamespace(
        remote=str(ipaddress.IPv4Address(1)),
        secure=False,
        headers={"X-Forwarded-Proto": "https", "X-Forwarded-For": str(ipaddress.IPv4Address(2))},
    )
    assert not auth.trusted_proxy(request)
    assert not auth.secure(request)
    assert auth.client_key(request) == request.remote
    request.remote = None
    assert not auth.trusted_proxy(request)
    assert auth.client_key(request) == "unknown"


async def test_proxy_readiness_requires_explicit_configuration(
    monkeypatch, state_manager, aiohttp_client
):
    from mining_dashboard.web import server

    monkeypatch.delenv("DASHBOARD_AUTH_FILE", raising=False)
    client = await aiohttp_client(server.create_app(state_manager, {}))
    assert (await client.get("/api/auth/ready")).status == 503
