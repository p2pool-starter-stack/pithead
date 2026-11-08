import json
import secrets
import shlex
import urllib.request
from pathlib import Path

import bcrypt
import pytest

from mining_dashboard.service import control_service, dashboard_auth
from mining_dashboard.web import auth
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


@pytest.mark.parametrize(
    "invalidation", ["logout", "idle", "absolute", "password", "role", "remove", "revision"]
)
async def test_cached_basic_cannot_restore_invalidated_session(
    auth_client, auth_config, state_manager, monkeypatch, invalidation
):
    path, data, password, _ = auth_config
    retained = {"Authorization": basic("owner", password)}
    response = await login(auth_client, password, **retained)
    assert response.status == 303
    old_cookie = response.cookies["pithead_session"].value
    if invalidation == "logout":
        response = await auth_client.post(
            "/logout", headers={**retained, "Origin": origin(auth_client)}, allow_redirects=False
        )
        assert response.status == 303
    elif invalidation in {"idle", "absolute"}:
        with state_manager._db_lock, state_manager._conn:
            state_manager._conn.execute(
                "UPDATE dashboard_sessions SET touched=0"
                if invalidation == "idle"
                else "UPDATE dashboard_sessions SET created=0"
            )
    else:
        user = data["users"][0]
        if invalidation == "password":
            user["password_hash"] = bcrypt.hashpw(
                secrets.token_bytes(18), bcrypt.gensalt(rounds=4)
            ).decode()
        elif invalidation == "role":
            user["role"] = "viewer"
            data["users"][1]["role"] = "admin"
        elif invalidation == "remove":
            data["users"].pop(0)
            data["users"][0]["role"] = "admin"
        else:
            user["revision"] = secrets.token_hex(8)
        path.write_text(json.dumps(data))
    actors = []
    monkeypatch.setattr(control_service, "submit", lambda *a, **kw: actors.append(kw["actor"]))
    for cookie in (old_cookie, ""):
        auth_client.session.cookie_jar.clear()
        headers = {**retained, "Cookie": f"pithead_session={cookie}"}
        assert (await auth_client.get("/api/auth/session", headers=headers)).status == 401
        response = await auth_client.get("/", headers=headers, allow_redirects=False)
        assert response.status == 303
        assert response.headers["Location"] == "/login"
        assert (
            await auth_client.post(
                "/api/control/backup",
                headers={**headers, "Origin": origin(auth_client), "X-Pithead-Control": "1"},
            )
        ).status == 401
    assert actors == []
    assert state_manager._conn.execute("SELECT COUNT(*) FROM dashboard_sessions").fetchone()[0] == 0


async def test_viewer_session_cannot_be_elevated_by_cached_admin_basic(auth_client, auth_config):
    await login(auth_client, auth_config[2], "observer")
    headers = {
        "Authorization": basic("owner", auth_config[2]),
        "Origin": origin(auth_client),
        "X-Pithead-Control": "1",
    }
    response = await auth_client.get("/api/auth/session", headers=headers)
    assert (await response.json())["role"] == "viewer"
    assert (await auth_client.post("/api/control/backup", headers=headers)).status == 403


@pytest.mark.parametrize(
    "password_kind", ["incorrect", "owner", "observer", "empty", "long", "nul"]
)
async def test_mixed_cost_login_uses_same_work_for_every_username(
    auth_client, auth_config, monkeypatch, password_kind
):
    path, data, password, _ = auth_config
    other_password = secrets.token_urlsafe(18)
    data["users"][1]["password_hash"] = bcrypt.hashpw(
        other_password.encode(), bcrypt.gensalt(rounds=5)
    ).decode()
    path.write_text(json.dumps(data))
    supplied = {
        "incorrect": secrets.token_urlsafe(),
        "owner": password,
        "observer": other_password,
        "empty": "",
        "long": "x" * 73,
        "nul": "a\0b",
    }[password_kind]
    verify = dashboard_auth.verify
    schedules = []
    for name in ("missing", "owner", "observer"):
        calls = []

        def recorded(raw, hashed, calls=calls):
            calls.append(hashed[4:6])
            return verify(raw, hashed)

        monkeypatch.setattr(dashboard_auth, "verify", recorded)
        response = await login(auth_client, supplied, name)
        success = password_kind == name
        assert response.status == (303 if success else 401)
        if not success:
            assert await response.json() == {"error": "Invalid username or password."}
        else:
            assert (await (await auth_client.get("/api/auth/session")).json())["user"] == name
        schedules.append(calls)
    assert schedules == [["04", "05"]] * 3


@pytest.mark.parametrize("browser_auth", [True, False])
async def test_standby_credential_is_limited_to_its_safe_endpoint(
    auth_client, auth_config, browser_auth
):
    path, data, password, metrics = auth_config
    standby = secrets.token_urlsafe(18)
    data["standby_password_hash"] = bcrypt.hashpw(
        standby.encode(), bcrypt.gensalt(rounds=4)
    ).decode()
    if not browser_auth:
        data["users"] = []
    path.write_text(json.dumps(data))
    assert (await auth_client.get("/api/xvb-standby")).status == 401
    headers = {"Authorization": basic("standby", standby)}
    for method in ("GET", "HEAD"):
        response = await auth_client.request(method, "/api/xvb-standby", headers=headers)
        assert response.status == 200
    for credential in (basic("owner", password), basic("metrics", metrics), "Bearer " + standby):
        assert (
            await auth_client.get("/api/xvb-standby", headers={"Authorization": credential})
        ).status == 401
    assert (await auth_client.post("/api/xvb-standby", headers=headers)).status == 401
    if browser_auth:
        for endpoint in ("/api/state", "/api/config", "/api/auth/session", "/metrics"):
            assert (await auth_client.get(endpoint, headers=headers)).status == 401
        assert (await auth_client.get("/", headers=headers, allow_redirects=False)).status == 303
        assert (
            await auth_client.post(
                "/api/control/backup",
                headers={**headers, "Origin": origin(auth_client), "X-Pithead-Control": "1"},
            )
        ).status == 401


async def test_standby_machine_and_same_named_dashboard_account_are_independent(
    auth_client, auth_config
):
    path, data, password, _ = auth_config
    standby = secrets.token_urlsafe(18)
    data["users"][0]["name"] = "standby"
    data["standby_password_hash"] = bcrypt.hashpw(
        standby.encode(), bcrypt.gensalt(rounds=4)
    ).decode()
    path.write_text(json.dumps(data))
    headers = {"Authorization": basic("standby", standby)}
    assert (await auth_client.get("/api/xvb-standby", headers=headers)).status == 200
    assert (await auth_client.get("/api/auth/session", headers=headers)).status == 401
    assert (await login(auth_client, standby, "standby")).status == 401
    assert (
        await auth_client.get(
            "/api/xvb-standby", headers={"Authorization": basic("standby", password)}
        )
    ).status == 401
    assert (await login(auth_client, password, "standby")).status == 303
    assert (await auth_client.get("/api/auth/session")).status == 200
    auth_client.session.cookie_jar.clear()
    data["standby_password_hash"] = bcrypt.hashpw(
        secrets.token_bytes(18), bcrypt.gensalt(rounds=4)
    ).decode()
    path.write_text(json.dumps(data))
    assert (await auth_client.get("/api/xvb-standby", headers=headers)).status == 401


@pytest.mark.parametrize("method", ("GET", "HEAD"))
async def test_local_state_probe_uses_separate_read_only_machine_token(
    auth_client, monkeypatch, method
):
    token = secrets.token_hex(16)
    monkeypatch.setenv("DASHBOARD_BOOT_PROBE_TOKEN", token)
    headers = {"Authorization": "Bearer " + token}
    response = await auth_client.request(method, "/api/state", headers=headers)
    assert response.status == 200
    assert response.headers["Cache-Control"] == "no-store"
    if method == "GET":
        body = await response.json()
        assert body["auth"] == {"enabled": True, "user": "local-state", "role": "viewer"}
        assert body["control_enabled"] is False
    for endpoint in ("/api/auth/session", "/api/config", "/metrics", "/api/xvb-standby"):
        assert (await auth_client.get(endpoint, headers=headers)).status == 401
    for endpoint in ("/api/state", "/api/control/backup"):
        assert (
            await auth_client.post(
                endpoint,
                headers={**headers, "Origin": origin(auth_client), "X-Pithead-Control": "1"},
            )
        ).status == 401


@pytest.mark.parametrize(
    "refusal", ("empty", "wrong", "remote", "X-Forwarded-For", "X-Forwarded-Proto", "Forwarded")
)
async def test_local_state_probe_refuses_missing_wrong_remote_and_forwarded_tokens(
    auth_client, monkeypatch, refusal
):
    token = secrets.token_hex(16)
    monkeypatch.setenv("DASHBOARD_BOOT_PROBE_TOKEN", "" if refusal == "empty" else token)
    headers = {
        "Authorization": "Bearer " + (secrets.token_hex(16) if refusal == "wrong" else token)
    }
    if refusal == "remote":
        monkeypatch.setattr(auth, "trusted_proxy", lambda request: False)
    elif refusal not in {"empty", "wrong"}:
        headers[refusal] = "untrusted"
    assert (await auth_client.get("/api/state", headers=headers)).status == 401


@pytest.mark.parametrize("configured", (True, False))
def test_healthcheck_preserves_state_assembly_with_machine_authentication(monkeypatch, configured):
    token = secrets.token_hex(16)
    if configured:
        monkeypatch.setenv("DASHBOARD_BOOT_PROBE_TOKEN", token)
    else:
        monkeypatch.delenv("DASHBOARD_BOOT_PROBE_TOKEN", raising=False)
    calls = []
    monkeypatch.setattr(
        urllib.request, "urlopen", lambda request, timeout: calls.append((request, timeout))
    )
    command = shlex.split(
        (Path(__file__).parents[2] / "healthcheck.sh").read_text().splitlines()[-1]
    )
    assert command[:3] == ["exec", "python3", "-c"]
    exec(compile(command[3], "healthcheck.sh", "exec"), {})  # noqa: S102
    request, timeout = calls[0]
    assert len(calls) == 1
    assert request.method == "HEAD"
    assert request.full_url.endswith("/api/state")
    assert timeout == 5
    assert request.get_header("Authorization") == ("Bearer " + token if configured else None)
