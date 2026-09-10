# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestMetricsEndpoint:
    async def test_metrics_ok_text_plain(self, client):
        # /metrics (#379): Prometheus exposition text from the same snapshot as /api/state.
        resp = await client.get("/metrics")
        assert resp.status == 200
        assert resp.content_type == "text/plain"
        # Exposition version parameter so scrapers negotiate the 0.0.4 text format.
        assert "version=0.0.4" in resp.headers["Content-Type"]
        body = await resp.text()
        assert "pithead_workers_total" in body
        assert "# TYPE pithead_workers_total gauge" in body
        # The batch's own signals ride the same endpoint: staleness + cumulative counters.
        assert "pithead_snapshot_age_seconds" in body
        assert "# TYPE pithead_shares_accepted_total counter" in body

    async def test_metrics_error_is_sanitized(self, aiohttp_client, app_data):
        # A blowing-up state manager forces the except branch -> 500, no traceback body.
        bad_sm = MagicMock()
        bad_sm.get_history.side_effect = RuntimeError("SECRET internal detail")
        cli = await aiohttp_client(create_app(bad_sm, app_data))
        resp = await cli.get("/metrics")
        assert resp.status == 500
        body = await resp.text()
        assert "SECRET internal detail" not in body
        assert "Traceback" not in body
