# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestTariPayoutSync:
    """Tari on-chain payout confirmation poll (#462): persist to the shared table with chain="tari",
    alert once, no replay — the Tari sibling of TestPayoutSync. The Tari client is async, so
    get_confirmed_payouts is an AsyncMock (awaited directly, not via to_thread)."""

    def _svc_with_real_storage(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.tari_wallet_client = MagicMock()
        svc.tari_wallet_client.get_confirmed_payouts = AsyncMock()
        svc.alert_service.payout_confirmed_alert = AsyncMock(return_value="sent")
        return svc, sm

    def test_new_tari_payout_persists_and_alerts_once(self):
        svc, sm = self._svc_with_real_storage()
        try:
            payout = {"txid": "t1", "height": 100, "ts": 1000.0, "amount_atomic": 250_000}
            svc.tari_wallet_client.get_confirmed_payouts.return_value = [payout]
            asyncio.run(svc._sync_tari_payouts())
            assert len(sm.get_payouts("tari")) == 1
            svc.alert_service.payout_confirmed_alert.assert_awaited_once_with("tari", 250_000, "t1")
            # It landed on the Tari side only — the Monero chain is untouched.
            assert sm.get_payouts("monero") == []
        finally:
            sm.close()

    def test_restart_replay_does_not_realert(self):
        svc, sm = self._svc_with_real_storage()
        try:
            payout = {"txid": "t1", "height": 100, "ts": 1000.0, "amount_atomic": 1}
            svc.tari_wallet_client.get_confirmed_payouts.return_value = [payout]
            asyncio.run(svc._sync_tari_payouts())
            asyncio.run(svc._sync_tari_payouts())
            assert svc.alert_service.payout_confirmed_alert.await_count == 1
            assert len(sm.get_payouts("tari")) == 1
        finally:
            sm.close()

    def test_seeds_min_height_from_stored_tari_max(self):
        svc, sm = self._svc_with_real_storage()
        try:
            sm.add_payouts("tari", [{"txid": "old", "height": 500, "ts": 1.0, "amount_atomic": 1}])
            svc.tari_wallet_client.get_confirmed_payouts.return_value = []
            asyncio.run(svc._sync_tari_payouts())
            svc.tari_wallet_client.get_confirmed_payouts.assert_awaited_once_with(500)
        finally:
            sm.close()

    def test_empty_poll_is_a_quiet_noop(self):
        svc, sm = self._svc_with_real_storage()
        try:
            svc.tari_wallet_client.get_confirmed_payouts.return_value = []
            asyncio.run(svc._sync_tari_payouts())
            svc.alert_service.payout_confirmed_alert.assert_not_awaited()
        finally:
            sm.close()

    def test_disabled_feature_leaves_no_tari_wallet_client(self, monkeypatch):
        monkeypatch.setattr(ds_mod, "TARI_PAYOUT_CONFIRM_ENABLED", False)
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.tari_wallet_client is None
