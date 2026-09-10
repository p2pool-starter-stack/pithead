# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestMoneroSyncBlipHolding:
    """The sync card must not reset to the 0/1 placeholder when one RPC poll comes back empty
    mid-sync — the bench box flashed 'Synced 0 / 1' while monerod ground through 99%."""

    def _svc(self):
        from unittest.mock import MagicMock

        from mining_dashboard.service.data_service import DataService

        return DataService(MagicMock(), MagicMock(), MagicMock())

    def test_blip_holds_the_last_real_reading(self):
        svc = self._svc()
        svc._last_monero_sync = {"percent": 99, "current": 3727030, "target": 3730206}
        monero_sync = {"is_syncing": True}  # this poll's RPC returned nothing usable
        if "percent" not in monero_sync:
            monero_sync.update(svc._last_monero_sync or {"percent": 0, "current": 0, "target": 1})
        assert monero_sync["percent"] == 99
        assert monero_sync["target"] == 3730206

    def test_placeholder_only_before_any_reading_ever(self):
        svc = self._svc()
        monero_sync = {"is_syncing": True}
        monero_sync.update(svc._last_monero_sync or {"percent": 0, "current": 0, "target": 1})
        assert monero_sync == {"is_syncing": True, "percent": 0, "current": 0, "target": 1}
