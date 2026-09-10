# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestSyncPrices:
    """#520: the poll-loop price refresh — a no-op with the feed off, the cached PriceFeed result
    surfaced as latest_data["prices"] when on."""

    async def test_disabled_feed_never_fetches(self):
        svc, _, _ = _make_service()
        svc.price_feed = MagicMock(enabled=False)
        await svc._sync_prices()
        svc.price_feed.maybe_fetch.assert_not_called()
        assert "prices" not in svc.latest_data

    async def test_enabled_feed_surfaces_prices(self):
        svc, _, _ = _make_service()
        prices = {"xmr": 333.97, "tari": 0.0004, "currency": "USD", "fetched_at": 1000.0}
        svc.price_feed = MagicMock(enabled=True)
        svc.price_feed.maybe_fetch.return_value = prices
        await svc._sync_prices()
        assert svc.latest_data["prices"] == prices
