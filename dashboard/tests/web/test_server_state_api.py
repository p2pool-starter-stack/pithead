# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestStateApi:
    async def test_get_state_ok_json(self, client):
        resp = await client.get("/api/state")
        assert resp.status == 200
        assert resp.content_type == "application/json"
        body = await resp.json()
        for key in ("badges", "hashrate", "system", "sync", "workers", "chart", "tari"):
            assert key in body

    async def test_range_query_accepted(self, client):
        resp = await client.get("/api/state?range=24h")
        assert resp.status == 200
        assert (await resp.json())["range"] == "24h"

    async def test_from_to_window_accepted(self, client):
        # A manual-zoom window (Issue #47) is parsed and echoed back in the payload.
        resp = await client.get("/api/state?from=1000&to=2000")
        assert resp.status == 200
        assert (await resp.json())["window"] == {"from": 1000.0, "to": 2000.0}

    async def test_malformed_from_to_falls_back(self, client):
        # Garbage from/to must not 500 — it falls back to the preset range, window null.
        resp = await client.get("/api/state?from=foo&to=2000")
        assert resp.status == 200
        assert (await resp.json())["window"] is None

    async def test_window_filters_history_end_to_end(self, aiohttp_client):
        # Functionality through the whole stack (Issue #47): a from/to window restricts the
        # chart series to that span. 20 minute-spaced points; a window over 5 of them returns 5.
        sm = StateManager(db_path=":memory:")
        base = 1_000_000
        for i in range(20):
            sm.state["hashrate_history"].append(
                {"t": "x", "v": 100, "v_p2pool": 100, "v_xvb": 0, "timestamp": base + i * 60}
            )
        data = {
            "shares": [],
            "workers": [],
            "global_sync": False,
            "monero_sync": {"percent": 100, "current": 1, "target": 1},
            "tari_sync": {"percent": 100, "current": 1, "target": 1},
        }
        cli = await aiohttp_client(create_app(sm, data))
        resp = await cli.get(f"/api/state?from={base + 300}&to={base + 540}")  # indices 5..9
        body = await resp.json()
        sm.close()
        pts = [p for p in body["chart"]["p2pool"] if p["y"] is not None]
        assert len(pts) == 5
        assert body["window"] == {"from": base + 300, "to": base + 540}

    async def test_node_down_badges_in_state(self, aiohttp_client):
        # When a node is down / workers rejected, the state surfaces it (Issue #31).
        data = {
            "shares": [],
            "workers": [],
            "global_sync": False,
            "monero_sync": {"percent": 100, "current": 10, "target": 10, "down": True},
            "tari_sync": {"percent": 100, "current": 10, "target": 10, "down": False},
            "workers_rejected": True,
        }
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, data))
        texts = [b["text"] for b in (await (await cli.get("/api/state")).json())["badges"]]
        sm.close()
        assert "monerod DOWN" in texts
        assert "Tari DOWN" not in texts
        assert "Workers rejected" in texts

    async def test_passive_tari_badge_in_state(self, aiohttp_client):
        # Non-blocking Tari (Issue #51): operational, with a top-bar "Tari syncing" badge.
        data = {
            "shares": [],
            "workers": [],
            "global_sync": False,
            "monero_sync": {"percent": 100, "current": 10, "target": 10},
            "tari_sync": {"percent": 42, "current": 42, "target": 100},
            "tari_syncing_passive": True,
        }
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, data))
        texts = [b["text"] for b in (await (await cli.get("/api/state")).json())["badges"]]
        sm.close()
        assert "Tari syncing 42%" in texts

    async def test_state_error_is_sanitized_json(self, aiohttp_client, app_data):
        # A state manager whose get_history blows up forces the except branch -> JSON 500.
        bad_sm = MagicMock()
        bad_sm.get_history.side_effect = RuntimeError("SECRET internal detail")
        cli = await aiohttp_client(create_app(bad_sm, app_data))
        resp = await cli.get("/api/state")
        assert resp.status == 500
        body = await resp.json()
        assert "error" in body
        assert "SECRET internal detail" not in str(body)  # no leak
        assert "X-Frame-Options" in resp.headers  # headers still applied
