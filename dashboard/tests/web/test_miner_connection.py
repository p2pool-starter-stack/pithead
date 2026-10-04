# ruff: noqa: F811
"""Credential responses must follow the rendered Caddy authentication perimeter."""

import pytest

from mining_dashboard.config import config
from tests.web._server_support import app_data, client  # noqa: F401, F811


@pytest.fixture(autouse=True)
def connection_env(monkeypatch):
    monkeypatch.setattr(config, "HOST_IP", "192.0.2.8")
    monkeypatch.setattr(config, "STRATUM_PORT", 4444)
    for key in (
        "PROXY_STRATUM_PASSWORD",
        "PROXY_STRATUM_TLS",
        "STRATUM_TLS_FINGERPRINT",
        "DASHBOARD_AUTH_HASH_B64",
        "DASHBOARD_AUTH_USER",
    ):
        monkeypatch.delenv(key, raising=False)


@pytest.mark.parametrize("authenticated", [False, True])
async def test_no_password_is_explicit_and_not_cached(client, monkeypatch, authenticated):
    if authenticated:
        monkeypatch.setenv("DASHBOARD_AUTH_HASH_B64", "rendered-hash")
    r = await client.get("/api/miner-connection", headers={"X-Auth-User": "admin"})
    body = await r.json()
    assert body["url"] == "stratum+tcp://192.0.2.8:4444"
    assert body["password_set"] is False
    assert body["password"] in (None, "")
    assert body["tls"] is False
    assert body["fingerprint"] == ""
    assert r.headers["Cache-Control"] == "no-store"


@pytest.mark.parametrize("auth_hash,actor", [("", ""), ("", "supplied-header"), ("hash", "admin")])
async def test_owner_permits_password_on_login_free_lan_dashboard(
    client, monkeypatch, auth_hash, actor
):
    monkeypatch.setenv("PROXY_STRATUM_PASSWORD", "fixture-stratum-secret")
    monkeypatch.setenv("DASHBOARD_AUTH_HASH_B64", auth_hash)
    r = await client.get("/api/miner-connection", headers={"X-Auth-User": actor})
    body = await r.json()
    assert body["password_set"] is True
    assert body["password"] == "fixture-stratum-secret"
    assert r.headers["Cache-Control"] == "no-store"
    assert "fixture-stratum-secret" not in await (await client.get("/api/state")).text()


async def test_tls_fingerprint_is_public_and_ipv6_url_is_bracketed(client, monkeypatch):
    monkeypatch.setattr(config, "HOST_IP", "2001:db8::1")
    monkeypatch.setenv("PROXY_STRATUM_TLS", "true")
    monkeypatch.setenv("STRATUM_TLS_FINGERPRINT", "a" * 64)
    body = await (await client.get("/api/miner-connection")).json()
    assert body["url"] == "stratum+ssl://[2001:db8::1]:4444"
    assert body["tls"] is True
    assert body["fingerprint"] == "a" * 64
