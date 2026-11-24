import asyncio
import json
import struct

import pytest
from aiohttp import web

from mining_dashboard.config import config
from mining_dashboard.service.logs import api
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.server import create_app

AUTH = {"X-Auth-User": "operator"}
WALLET = "4" + "S" * 94
T0 = api.parse_cursor("2026-11-23T10:00:00Z")


def entries(count, text="line", start=T0):
    return [(start + i, f"{text} {i}") for i in range(count)]


@pytest.fixture
def served(monkeypatch):
    monkeypatch.setattr(config, "DASHBOARD_MODE", "api")
    monkeypatch.setattr(config, "LOG_API_SERVICES", ("tor", "p2pool"))


@pytest.fixture
def fetched(monkeypatch):
    calls = []
    state = {"entries": [], "error": False}

    async def fake(service, since_ns=None, tail=api.MAX_TAIL):
        calls.append((service, since_ns, tail))
        if state["error"]:
            raise api.LogFetchError("down")
        return [e for e in state["entries"] if since_ns is None or e[0] > since_ns][-tail:]

    monkeypatch.setattr(api, "fetch", fake)
    state["calls"] = calls
    return state


@pytest.fixture
async def client(aiohttp_client, served):
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, {}))
    cli.sm = sm
    yield cli
    sm.close()


def audit_rows(cli):
    return [e for e in cli.sm.get_audit_events() if e["source"] == "api"]


class TestModeGate:
    @pytest.mark.parametrize("mode", ["dashboard", "", "nonsense"])
    async def test_routes_404_unless_mode_is_api_or_both(self, aiohttp_client, monkeypatch, mode):
        monkeypatch.setattr(config, "DASHBOARD_MODE", mode)
        monkeypatch.setattr(config, "LOG_API_SERVICES", ("tor",))
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, {}))
        for path in ("/api/logs/tor", "/api/logs/tor/follow"):
            assert (await cli.get(path, headers=AUTH)).status == 404
        sm.close()

    @pytest.mark.parametrize("mode", ["api", "both"])
    async def test_routes_are_served_in_api_and_both(
        self, aiohttp_client, monkeypatch, fetched, mode
    ):
        monkeypatch.setattr(config, "DASHBOARD_MODE", mode)
        monkeypatch.setattr(config, "LOG_API_SERVICES", ("tor",))
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, {}))
        assert (await cli.get("/api/logs/tor", headers=AUTH)).status == 200
        sm.close()

    def test_default_mode_is_dashboard_only(self):
        assert config.DASHBOARD_MODE == "dashboard"


class TestAuthAndAllowlist:
    async def test_unauthenticated_is_401_and_audited(self, client, fetched):
        resp = await client.get("/api/logs/tor")
        assert resp.status == 401
        assert resp.headers["Cache-Control"] == "no-store"
        assert fetched["calls"] == []
        assert [r["status"] for r in audit_rows(client)] == ["401"]

    @pytest.mark.parametrize("name", ["wallet-rpc", "tari-wallet", "nope", "..", "tor%2F.."])
    async def test_services_outside_the_allowlist_are_404(self, client, fetched, name):
        resp = await client.get(f"/api/logs/{name}", headers=AUTH)
        assert resp.status == 404
        assert fetched["calls"] == []

    async def test_follow_enforces_the_same_checks(self, client, fetched):
        assert (await client.get("/api/logs/tor/follow")).status == 401
        assert (await client.get("/api/logs/wallet-rpc/follow", headers=AUTH)).status == 404

    @pytest.mark.parametrize("lines", ["0", "501", "-1", "abc", "1.5", ""])
    async def test_lines_outside_1_to_500_is_400(self, client, fetched, lines):
        assert (await client.get(f"/api/logs/tor?lines={lines}", headers=AUTH)).status == 400

    async def test_bad_cursor_is_400(self, client, fetched):
        assert (await client.get("/api/logs/tor?since=yesterday", headers=AUTH)).status == 400


class TestTail:
    async def test_returns_redacted_lines_cursor_and_no_store(self, client, fetched):
        fetched["entries"] = [
            (T0, f"--wallet {WALLET} started"),
            (T0 + 1, "plain"),
        ]
        resp = await client.get("/api/logs/p2pool", headers=AUTH)
        body = await resp.json()
        assert resp.status == 200
        assert resp.headers["Cache-Control"] == "no-store"
        assert body["service"] == "p2pool"
        assert [row["line"] for row in body["lines"]] == [f"--wallet {WALLET} started", "plain"]
        assert body["since"] == api.format_cursor(T0 + 1)
        assert body["truncated"] is False
        assert fetched["calls"] == [("p2pool", None, api.DEFAULT_TAIL)]

    async def test_since_returns_only_newer_lines(self, client, fetched):
        fetched["entries"] = entries(3)
        resp = await client.get(f"/api/logs/tor?since={api.format_cursor(T0 + 1)}", headers=AUTH)
        body = await resp.json()
        assert [row["line"] for row in body["lines"]] == ["line 2"]

    async def test_empty_result_keeps_the_callers_cursor(self, client, fetched):
        cursor = api.format_cursor(T0)
        body = await (await client.get(f"/api/logs/tor?since={cursor}", headers=AUTH)).json()
        assert body["lines"] == [] and body["since"] == cursor

    async def test_response_never_exceeds_256_kib(self, client, fetched):
        fetched["entries"] = entries(500, text="y" * 16000)
        resp = await client.get("/api/logs/tor?lines=500", headers=AUTH)
        raw = await resp.read()
        assert len(raw) <= api.MAX_RESPONSE_BYTES
        assert (json.loads(raw))["truncated"] is True

    async def test_upstream_failure_is_502_and_audited(self, client, fetched):
        fetched["error"] = True
        assert (await client.get("/api/logs/tor", headers=AUTH)).status == 502
        assert audit_rows(client)[-1]["status"] == "502"

    async def test_every_request_writes_an_audit_row(self, client, fetched):
        await client.get("/api/logs/tor", headers=AUTH)
        await client.get("/api/logs/nope", headers=AUTH)
        rows = audit_rows(client)
        assert sorted(r["status"] for r in rows) == ["200", "404"]
        assert {r["actor"] for r in rows} == {"operator"}
        assert {r["action"] for r in rows} == {"log-read"}


@pytest.fixture
def fast(monkeypatch):
    monkeypatch.setattr(api, "POLL_INTERVAL_S", 0.01)
    monkeypatch.setattr(api, "MAX_LINES_PER_S", 1000)
    monkeypatch.setattr(api, "HEARTBEAT_S", 0.05)


async def read_events(resp):
    return (await resp.read()).decode()


class TestFollow:
    async def test_streams_new_lines_then_ends_idle(self, client, fetched, fast, monkeypatch):
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 0.3)
        fetched["entries"] = [(T0 + 1, "hello"), (T0 + 2, "second")]
        resp = await client.get(f"/api/logs/tor/follow?since={api.format_cursor(T0)}", headers=AUTH)
        text = await read_events(resp)
        assert resp.status == 200
        assert resp.headers["Content-Type"].startswith("text/event-stream")
        assert resp.headers["Cache-Control"] == "no-store"
        assert text.count("\nid: ") + text.startswith("id: ") == 2
        assert "second" in text and 'event: end\ndata: {"reason": "idle"}' in text
        assert ": keep-alive" in text
        assert client.app["log_gate"].active == 0

    async def test_lifetime_cap_ends_the_stream(self, client, fetched, fast, monkeypatch):
        monkeypatch.setattr(api, "LIFETIME_S", 0.2)
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 60)
        resp = await client.get("/api/logs/tor/follow", headers=AUTH)
        assert '"reason": "lifetime"' in await read_events(resp)

    async def test_fifth_follower_gets_429_and_a_slot_frees_on_end(
        self, client, fetched, fast, monkeypatch
    ):
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 60)
        monkeypatch.setattr(api, "LIFETIME_S", 60)
        held = [await client.get("/api/logs/tor/follow", headers=AUTH) for _ in range(4)]
        refused = await client.get("/api/logs/tor/follow", headers=AUTH)
        assert refused.status == 429
        assert refused.headers["Cache-Control"] == "no-store"
        assert client.app["log_gate"].active == 4
        for resp in held:
            resp.close()
        for _ in range(100):
            if client.app["log_gate"].active == 0:
                break
            await asyncio.sleep(0.02)
        assert client.app["log_gate"].active == 0
        assert "429" in [r["status"] for r in audit_rows(client)]

    async def test_disconnect_releases_the_slot(self, client, fetched, fast, monkeypatch):
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 60)
        monkeypatch.setattr(api, "LIFETIME_S", 60)
        resp = await client.get("/api/logs/tor/follow", headers=AUTH)
        assert client.app["log_gate"].active == 1
        resp.close()
        for _ in range(100):
            if client.app["log_gate"].active == 0:
                break
            await asyncio.sleep(0.02)
        assert client.app["log_gate"].active == 0


class TestRedactionThroughTheRoutes:
    async def test_tail_and_follow_never_carry_the_raw_secret(
        self, client, aiohttp_server, monkeypatch, fast
    ):
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 0.2)
        payload = (
            f"2026-11-23T10:00:05.000000000Z p2pool --wallet {WALLET} --rpc-login u:p\n".encode()
        )
        raw = bytes([1, 0, 0, 0]) + struct.pack(">I", len(payload)) + payload

        async def logs(request):
            return web.Response(body=raw)

        app = web.Application()
        app.router.add_get("/containers/{name}/logs", logs)
        server = await aiohttp_server(app)
        monkeypatch.setattr(config, "DOCKER_PROXY_URL", f"tcp://127.0.0.1:{server.port}")
        tail = await (await client.get("/api/logs/p2pool", headers=AUTH)).text()
        follow = await read_events(
            await client.get("/api/logs/p2pool/follow?since=2026-11-23T10:00:00Z", headers=AUTH)
        )
        for text in (tail, follow):
            assert WALLET not in text
            assert "u:p" not in text
            assert "--wallet [redacted-address]" in text


class TestReviewFixes:
    async def test_non_ascii_lines_cannot_push_the_body_past_256_kib(self, client, fetched):
        fetched["entries"] = entries(500, text="\u00e9" * 500)
        resp = await client.get("/api/logs/tor?lines=500", headers=AUTH)
        raw = await resp.read()
        assert len(raw) <= api.MAX_RESPONSE_BYTES
        assert resp.headers["Content-Type"].startswith("application/json")
        assert json.loads(raw)["truncated"] is True

    async def test_a_full_page_after_the_cursor_is_flagged_truncated(self, client, fetched):
        fetched["entries"] = entries(600)
        cursor = api.format_cursor(T0 - 1)
        body = await (
            await client.get(f"/api/logs/tor?since={cursor}&lines=500", headers=AUTH)
        ).json()
        assert len(body["lines"]) == 500
        assert body["truncated"] is True

    async def test_follow_resumes_from_last_event_id(self, client, fetched, fast, monkeypatch):
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 0.2)
        fetched["entries"] = entries(3)
        headers = {**AUTH, "Last-Event-ID": api.format_cursor(T0 + 1)}
        text = await read_events(await client.get("/api/logs/tor/follow", headers=headers))
        assert "line 2" in text and "line 1" not in text and "line 0" not in text

    async def test_follow_reports_a_gap_when_a_poll_is_full(
        self, client, fetched, fast, monkeypatch
    ):
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 0.2)
        fetched["entries"] = entries(api.MAX_TAIL + 20)
        cursor = api.format_cursor(T0 - 1)
        text = await read_events(
            await client.get(f"/api/logs/tor/follow?since={cursor}", headers=AUTH)
        )
        assert "event: gap" in text

    async def test_follow_reports_an_unreachable_proxy_once(
        self, client, fetched, fast, monkeypatch
    ):
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 0.2)
        fetched["error"] = True
        text = await read_events(await client.get("/api/logs/tor/follow", headers=AUTH))
        assert text.count("event: error") == 1

    async def test_lifetime_is_enforced_inside_a_long_batch(self, client, fetched, monkeypatch):
        monkeypatch.setattr(api, "POLL_INTERVAL_S", 0.01)
        monkeypatch.setattr(api, "MAX_LINES_PER_S", 20)
        monkeypatch.setattr(api, "LIFETIME_S", 0.3)
        monkeypatch.setattr(api, "IDLE_TIMEOUT_S", 60)
        fetched["entries"] = entries(200)
        cursor = api.format_cursor(T0 - 1)
        text = await read_events(
            await client.get(f"/api/logs/tor/follow?since={cursor}", headers=AUTH)
        )
        assert text.count("\nid: ") + text.startswith("id: ") < 20
        assert '"reason": "lifetime"' in text

    async def test_a_stalled_reader_times_out_instead_of_holding_the_slot(self, monkeypatch):
        from mining_dashboard.web.views import log_views

        class Stalled:
            async def write(self, data):
                await asyncio.sleep(60)

        monkeypatch.setattr(api, "WRITE_TIMEOUT_S", 0.05)
        with pytest.raises(TimeoutError):
            await log_views._send(Stalled(), "x")
