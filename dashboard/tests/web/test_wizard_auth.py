# ruff: noqa: F403, F405
from tests.web._wizard_support import *  # noqa: F403


@pytest.mark.parametrize(
    "typed",
    ["pit-X7KM2Q", "PIT-X7KM2Q", "pit-x7km2q", "X7KM2Q", "x7km2q", "  pit-X7KM2Q  "],
)
async def test_token_transcription_variants_all_pass(client, typed):
    r = await _auth(client, typed)
    assert r.status == 302
    assert "SameSite=Strict" in r.headers.get("Set-Cookie", "")


async def test_wrong_token_403(client):
    assert (await _auth(client, "pit-WRONGX")).status == 403


@pytest.fixture
async def auth_clients(spool, monkeypatch):
    exits = []
    monkeypatch.setattr(wizard.sys, "exit", exits.append)
    app = wizard.make_app()

    @web.middleware
    async def peer(request, handler):
        return await handler(request.clone(remote=request.headers["X-Test-Peer"]))

    app.middlewares.append(peer)
    server = TestServer(app)
    async with TestClient(server, headers={"X-Test-Peer": "operator"}) as operator:
        async with TestClient(server, headers={"X-Test-Peer": "offender"}) as offender:
            yield operator, offender, exits


async def test_lockout_only_throttles_offending_client(auth_clients):
    operator, offender, exits = auth_clients
    assert (await _auth(operator)).status == 302
    for attempt in range(wizard.MAX_FAILURES * 3):
        r = await _auth(offender, "pit-WRONGX")
        assert r.status == (403 if attempt < wizard.MAX_FAILURES - 1 else 429)
    assert exits == []
    assert (await operator.get("/api/wizard-state")).status == 200
    assert (await _auth(operator)).status == 302
    assert (await offender.get("/api/wizard-state")).status == 401


async def test_auth_success_clears_only_its_clients_failures(auth_clients):
    operator, offender, exits = auth_clients
    for _ in range(wizard.MAX_FAILURES - 1):
        assert (await _auth(operator, "pit-WRONGX")).status == 403
        assert (await _auth(offender, "pit-WRONGX")).status == 403
    assert (await _auth(operator)).status == 302
    assert (await _auth(operator, "pit-WRONGX")).status == 403
    assert (await _auth(offender, "pit-WRONGX")).status == 429
    assert exits == []
    assert (await operator.get("/api/wizard-state")).status == 200


async def test_lockout_expires_without_extending_or_changing_token(auth_clients, monkeypatch):
    _, offender, exits = auth_clients
    now = [100.0]
    monkeypatch.setattr(wizard, "monotonic", lambda: now[0], raising=False)
    for _ in range(wizard.MAX_FAILURES):
        r = await _auth(offender, "pit-WRONGX")
    assert r.status == 429
    assert r.headers["Retry-After"] == "60"
    assert "try again" in (await r.json())["error"].lower()
    assert (await _auth(offender)).status == 429
    now[0] += 59.5
    r = await _auth(offender, "pit-WRONGX")
    assert r.status == 429
    assert r.headers["Retry-After"] == "1"
    now[0] += 0.5
    assert (await _auth(offender)).status == 302
    assert exits == []


async def test_partial_failure_budget_expires(auth_clients, monkeypatch):
    _, offender, _ = auth_clients
    now = [100.0]
    monkeypatch.setattr(wizard, "monotonic", lambda: now[0], raising=False)
    for _ in range(wizard.MAX_FAILURES - 1):
        await _auth(offender, "pit-WRONGX")
    now[0] += 60
    assert (await _auth(offender, "pit-WRONGX")).status == 403


async def test_forwarded_headers_cannot_reset_client_budget(client):
    for attempt in range(wizard.MAX_FAILURES):
        r = await client.post(
            "/auth",
            data={"token": "pit-WRONGX"},
            headers={"X-Forwarded-For": f"claimed-peer-{attempt}"},
        )
    assert r.status == 429
    assert client.server.app["exits"] == []


async def test_authenticated_operator_sharing_blocked_peer_keeps_session(auth_clients):
    operator, offender, exits = auth_clients
    await _auth(operator)
    for _ in range(wizard.MAX_FAILURES * 2):
        r = await offender.post(
            "/auth", data={"token": "pit-WRONGX"}, headers={"X-Test-Peer": "operator"}
        )
    assert r.status == 429
    assert exits == []
    assert (await operator.get("/api/wizard-state")).status == 200
    assert (await offender.get("/api/wizard-state")).status == 401


async def test_failure_tracking_is_bounded_without_resetting_existing_peer(
    auth_clients, monkeypatch
):
    operator, offender, _ = auth_clients
    monkeypatch.setattr(wizard, "MAX_AUTH_CLIENTS", 2)
    await _auth(offender, "pit-WRONGX")
    await _auth(operator, "pit-WRONGX")
    await operator.post(
        "/auth", data={"token": "pit-WRONGX"}, headers={"X-Test-Peer": "another-client"}
    )
    failures = operator.server.app["failures"]
    assert len(failures) == 2
    assert "offender" not in failures
    for _ in range(wizard.MAX_FAILURES - 2):
        assert (await _auth(operator, "pit-WRONGX")).status == 403
    assert (await _auth(operator, "pit-WRONGX")).status == 429
