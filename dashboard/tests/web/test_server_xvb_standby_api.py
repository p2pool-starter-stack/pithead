# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestXvbStandbyApi:
    """The read-only endpoint a backup stack pulls to warm its donation split (#249)."""

    async def test_get_xvb_standby_ok_json(self, client):
        resp = await client.get("/api/xvb-standby")
        assert resp.status == 200
        assert resp.content_type == "application/json"
        body = await resp.json()
        for key in ("commanded_fraction", "avg_1h", "avg_24h", "mode", "donation_level", "ts"):
            assert key in body

    async def test_error_is_sanitized_500(self, aiohttp_client, app_data):
        sm = MagicMock()
        sm.get_xvb_stats.side_effect = RuntimeError("boom")
        cli = await aiohttp_client(create_app(sm, app_data))
        resp = await cli.get("/api/xvb-standby")
        assert resp.status == 500
        body = await resp.json()
        assert body == {"error": "Failed to build XvB standby state."}  # no internals leaked

    async def test_reflects_controller_state(self, aiohttp_client, app_data):
        sm = StateManager(db_path=":memory:")
        sm.update_xvb_stats(mode="XVB", avg_1h=1500.0, commanded_fraction=0.37)
        cli = await aiohttp_client(create_app(sm, app_data))
        try:
            body = await (await cli.get("/api/xvb-standby")).json()
            assert body["commanded_fraction"] == 0.37
            assert body["avg_1h"] == 1500.0
            assert body["mode"] == "XVB"
        finally:
            sm.close()
