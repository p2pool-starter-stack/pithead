import base64
import json
import secrets

import bcrypt
import pytest

from mining_dashboard.service import control_service
from tests.web.dashboard_auth_fixtures import (
    auth_client as auth_client,
)
from tests.web.dashboard_auth_fixtures import (
    auth_config as auth_config,
)
from tests.web.dashboard_auth_fixtures import (
    basic,
    login,
    origin,
)


async def test_pages_redirect_and_api_has_no_browser_prompt(auth_client):
    for path in ("/", "/ui-preview", "/unknown-page"):
        response = await auth_client.get(path, allow_redirects=False)
        assert response.status == 303
        assert response.headers["Location"] == "/login"
        assert "WWW-Authenticate" not in response.headers
    response = await auth_client.get("/api/state")
    assert response.status == 401
    assert "WWW-Authenticate" not in response.headers
    response = await auth_client.get("/login")
    assert response.status == 200
    assert 'name="password"' in await response.text()


async def test_login_cookie_logout_and_actor(auth_client, auth_config, monkeypatch):
    response = await login(auth_client, auth_config[2])
    assert response.status == 303
    cookie = response.cookies["pithead_session"]
    assert cookie["httponly"]
    assert cookie["samesite"] == "Strict"
    assert not cookie["secure"]
    assert len(cookie.value) >= 40
    response = await auth_client.get("/api/auth/session")
    assert await response.json() == {"enabled": True, "user": "owner", "role": "admin"}
    actors = []
    monkeypatch.setattr(control_service, "submit", lambda *a, **kw: actors.append(kw["actor"]))
    response = await auth_client.post(
        "/api/control/backup",
        headers={"Origin": origin(auth_client), "X-Pithead-Control": "1", "X-Auth-User": "forged"},
    )
    assert response.status == 202
    assert actors == ["owner"]
    response = await auth_client.post(
        "/logout", headers={"Origin": origin(auth_client)}, allow_redirects=False
    )
    assert response.status == 303
    assert (await auth_client.get("/api/state")).status == 401


async def test_viewer_rejected_by_entire_mutating_route_table(auth_client, auth_config):
    await login(auth_client, auth_config[2], "observer")
    checked = []
    for route in auth_client.app.router.routes():
        if route.method in {"GET", "HEAD", "OPTIONS"} or route.resource.canonical in {
            "/login",
            "/logout",
        }:
            continue
        path = route.resource.canonical
        response = await auth_client.request(
            route.method,
            path,
            json={},
            headers={"Origin": origin(auth_client), "X-Pithead-Control": "1"},
        )
        assert response.status == 403, (route.method, path)
        checked.append(path)
    assert "/api/control/commit" in checked
    assert "/api/control/power" in checked
    assert "/api/auth/hash" in checked
    response = await auth_client.get("/api/state")
    assert response.status == 200
    state = await response.json()
    assert state["auth"]["role"] == "viewer"
    assert state["control_enabled"] is False


@pytest.mark.parametrize("headers", [{}, {"Origin": "null"}, {"Origin": "https:"}])
async def test_csrf_rejected(auth_client, auth_config, headers):
    response = await auth_client.post("/login", data={}, headers=headers)
    assert response.status == 403
    await login(auth_client, auth_config[2])
    response = await auth_client.post(
        "/api/control/backup", headers={"X-Pithead-Control": "1", **headers}
    )
    assert response.status == 403
    response = await auth_client.post("/logout", headers=headers)
    assert response.status == 403


async def test_wrong_credentials_are_generic_and_rate_limited(auth_client, auth_config):
    bodies = []
    for name in ("owner", "missing", "observer", "owner", "owner"):
        response = await login(auth_client, secrets.token_urlsafe(), name)
        assert response.status == 401
        bodies.append(await response.text())
    assert len(set(bodies)) == 1
    response = await login(auth_client, auth_config[2])
    assert response.status == 429
    assert int(response.headers["Retry-After"]) > 0


async def test_metrics_credential_cannot_open_other_routes(auth_client, auth_config):
    for authorization in ("Bearer " + auth_config[3], basic("metrics", auth_config[3])):
        response = await auth_client.get("/metrics", headers={"Authorization": authorization})
        assert response.status == 200
        for path in ("/api/state", "/api/config"):
            assert (
                await auth_client.get(path, headers={"Authorization": authorization})
            ).status == 401
    response = await auth_client.get(
        "/metrics", headers={"Authorization": basic("owner", auth_config[2])}
    )
    assert response.status == 401
    await login(auth_client, auth_config[2])
    assert (await auth_client.get("/metrics")).status == 200


@pytest.mark.parametrize("change", ["password_hash", "role", "remove"])
async def test_user_changes_revoke_sessions(auth_client, auth_config, change):
    path, data, password, _ = auth_config
    await login(auth_client, password)
    if change == "remove":
        data["users"].pop(0)
        data["users"][0]["role"] = "admin"
    elif change == "role":
        data["users"][0]["role"] = "viewer"
        data["users"][1]["role"] = "admin"
    else:
        data["users"][0]["password_hash"] = bcrypt.hashpw(
            secrets.token_bytes(18), bcrypt.gensalt(rounds=4)
        ).decode()
    path.write_text(json.dumps(data))
    assert (await auth_client.get("/api/state")).status == 401


async def test_missing_auth_config_fails_closed(auth_client, auth_config):
    auth_config[0].unlink()
    response = await auth_client.get("/api/state")
    assert response.status == 503
    assert str(auth_config[0]) not in await response.text()


async def test_machine_credential_protects_metrics_with_browser_auth_disabled(
    auth_client, auth_config
):
    path, data, _, machine = auth_config
    data["users"] = []
    path.write_text(json.dumps(data))
    assert (await auth_client.get("/")).status == 200
    assert (await auth_client.get("/metrics")).status == 401
    assert (
        await auth_client.get("/metrics", headers={"Authorization": "Bearer " + machine})
    ).status == 200


async def test_proxy_readiness_requires_valid_auth_configuration(auth_client, auth_config):
    response = await auth_client.get("/api/auth/ready")
    assert response.status == 204
    assert response.headers["X-Pithead-Auth-Protocol"] == "sessions-v1"
    auth_config[0].write_text("{}")
    assert (await auth_client.get("/api/auth/ready")).status == 503


async def test_tls_cookie_and_secure_session_refuse_plain_transport(auth_client, auth_config):
    response = await auth_client.post(
        "/login",
        data={"username": "owner", "password": auth_config[2]},
        headers={
            "X-Forwarded-Proto": "https",
            "Origin": origin(auth_client).replace("http:", "https:"),
        },
        allow_redirects=False,
    )
    cookie = response.cookies["pithead_session"]
    assert cookie["secure"] and cookie["httponly"]
    headers = {"Cookie": f"pithead_session={cookie.value}"}
    assert (await auth_client.get("/api/state", headers=headers)).status == 401
    assert (
        await auth_client.get("/api/state", headers={**headers, "X-Forwarded-Proto": "https"})
    ).status == 200


async def test_interactive_basic_credentials_cannot_authorize_control(
    auth_client, auth_config, monkeypatch
):
    actors = []
    monkeypatch.setattr(control_service, "submit", lambda *a, **kw: actors.append(kw["actor"]))
    headers = {"Authorization": basic("owner", auth_config[2])}
    response = await auth_client.post(
        "/api/control/backup",
        headers={**headers, "X-Pithead-Control": "1", "Origin": origin(auth_client)},
    )
    assert response.status == 401
    assert actors == []
    assert (await auth_client.post("/api/control/backup", headers=headers)).status == 401
    response = await auth_client.post(
        "/api/control/backup", headers={**headers, "X-Pithead-Control": "1"}
    )
    assert response.status == 401
    assert actors == []
    response = await auth_client.post(
        "/api/control/backup", headers={**headers, "X-Pithead-Control": "1", "Origin": "null"}
    )
    assert response.status == 401
    await login(auth_client, auth_config[2])
    response = await auth_client.post(
        "/api/control/backup", headers={**headers, "X-Pithead-Control": "1"}
    )
    assert response.status == 403
    response = await auth_client.post(
        "/api/control/backup",
        headers={**headers, "X-Pithead-Control": "1", "Origin": origin(auth_client)},
    )
    assert response.status == 202
    assert actors == ["owner"]


async def test_viewer_cannot_read_one_time_control_or_miner_credentials(
    auth_client, auth_config, monkeypatch
):
    secret = secrets.token_urlsafe()
    monkeypatch.setenv("PROXY_STRATUM_PASSWORD", secret)
    monkeypatch.setattr(
        control_service,
        "result",
        lambda _: {
            "status": "applied",
            "passphrase": secret,
            "client_key": secret,
            "torrc_line": secret,
        },
    )
    await login(auth_client, auth_config[2], "observer")
    for path in ("/api/control/result", "/api/miner-connection"):
        response = await auth_client.get(path)
        assert response.status == 200
        assert secret not in await response.text()


async def test_admin_hashes_password_without_spooling_plaintext(auth_client, auth_config):
    await login(auth_client, auth_config[2])
    password = secrets.token_urlsafe()
    response = await auth_client.post(
        "/api/auth/hash",
        json={"password": password},
        headers={
            "Origin": origin(auth_client),
            "X-Pithead-Control": "1",
        },
    )
    assert response.status == 200
    data = await response.json()
    assert bcrypt.checkpw(password.encode(), data["password_hash"].encode())
    assert password not in await response.text()
    assert response.headers["Cache-Control"] == "no-store"


async def test_auth_disabled_cannot_invoke_password_hashing(auth_client, monkeypatch):
    monkeypatch.delenv("DASHBOARD_AUTH_FILE")
    calls = []
    monkeypatch.setattr(bcrypt, "hashpw", lambda *args: calls.append(args) or b"unused")
    response = await auth_client.post(
        "/api/auth/hash",
        json={"password": secrets.token_urlsafe()},
        headers={"X-Pithead-Control": "1"},
    )
    assert response.status == 403
    assert calls == []


@pytest.mark.parametrize(
    "value", [None, [], {}, {"password": "x" * 73}, {"password": "a\0b"}, {"password": "a"}]
)
async def test_hash_endpoint_refuses_invalid_password(auth_client, auth_config, value):
    await login(auth_client, auth_config[2])
    response = await auth_client.post(
        "/api/auth/hash",
        json=value,
        headers={
            "Origin": origin(auth_client),
            "X-Pithead-Control": "1",
        },
    )
    assert response.status == 400


async def test_bounded_login_request_and_hash_concurrency(auth_client, auth_config):
    response = await auth_client.post(
        "/login", data="x" * 5000, headers={"Origin": origin(auth_client)}
    )
    assert response.status == 400
    await login(auth_client, auth_config[2])
    auth_client.app["auth_runtime"]["busy"] = 4
    response = await auth_client.post(
        "/api/auth/hash",
        json={"password": secrets.token_urlsafe()},
        headers={
            "Origin": origin(auth_client),
            "X-Pithead-Control": "1",
        },
    )
    assert response.status == 429


@pytest.mark.parametrize(
    "authorization",
    [
        "Basic !",
        "Basic " + base64.b64encode(b"missing-separator").decode(),
        "Basic " + base64.b64encode(b"invalid:\xff").decode(),
        "Basic " + "x" * 2048,
        "Bearer x",
    ],
)
@pytest.mark.parametrize("endpoint", ["/api/state", "/metrics", "/api/xvb-standby"])
async def test_malformed_credentials_do_not_bypass_auth(auth_client, authorization, endpoint):
    assert (await auth_client.get(endpoint, headers={"Authorization": authorization})).status == 401


async def test_boot_probe_exemption_cannot_reach_an_api(auth_client):
    headers = {"X-Pithead-Boot-Probe": "boot-health-v1"}
    assert (await auth_client.get("/", headers=headers)).status == 200
    assert (await auth_client.get("/api/state", headers=headers)).status == 401


async def test_public_assets_only_allow_login_dependencies(auth_client):
    assert (await auth_client.get("/static/login.css")).status == 200
    response = await auth_client.get("/static/dashboard.js", allow_redirects=False)
    assert response.status == 303


async def test_auth_disabled_keeps_dashboard_behavior(auth_client, auth_config, monkeypatch):
    monkeypatch.delenv("DASHBOARD_AUTH_FILE")
    response = await auth_client.get("/api/state")
    assert response.status == 200
    assert "auth" not in await response.json()


async def test_global_throttling_applies_across_clients(auth_client, auth_config, monkeypatch):
    from mining_dashboard.web import auth

    monkeypatch.setattr(auth, "client_key", lambda request: secrets.token_hex(8))
    monkeypatch.setattr(auth.dashboard_auth, "GLOBAL_ATTEMPTS", 2)
    for _ in range(2):
        assert (await login(auth_client, secrets.token_urlsafe())).status == 401
    assert (await login(auth_client, auth_config[2])).status == 429


@pytest.mark.parametrize("name", ["owner@example", "_owner", "-owner", ".owner"])
async def test_legacy_usernames_remain_valid_after_upgrade(auth_client, auth_config, name):
    path, data, password, _ = auth_config
    data["users"][0]["name"] = name
    path.write_text(json.dumps(data))
    assert (await login(auth_client, password, name)).status == 303
    assert (await (await auth_client.get("/api/auth/session")).json())["user"] == name


async def test_metrics_named_admin_and_machine_credentials_are_independent(
    auth_client, auth_config
):
    path, data, password, machine = auth_config
    data["users"][0]["name"] = "metrics"
    path.write_text(json.dumps(data))
    for credential in (basic("metrics", machine), "Bearer " + machine):
        assert (
            await auth_client.get("/metrics", headers={"Authorization": credential})
        ).status == 200
    assert (
        await auth_client.get("/metrics", headers={"Authorization": "Bearer " + password})
    ).status == 401
    assert (
        await auth_client.get("/api/state", headers={"Authorization": basic("metrics", machine)})
    ).status == 401
    assert (
        await auth_client.get("/metrics", headers={"Authorization": basic("metrics", password)})
    ).status == 401
    assert (await login(auth_client, password, "metrics")).status == 303
    assert (await auth_client.get("/metrics")).status == 200
