# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestPayoutSync:
    """On-chain payout confirmation poll (#381): persist confirmed payouts, alert once, no replay."""

    def _svc_with_real_storage(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.wallet_client = MagicMock()
        svc.alert_service.payout_confirmed_alert = AsyncMock(return_value="sent")
        return svc, sm

    def test_new_payout_persists_and_alerts_once(self):
        svc, sm = self._svc_with_real_storage()
        try:
            payout = {"txid": "aa", "height": 100, "ts": 1000.0, "amount_atomic": 250_000_000_000}
            svc.wallet_client.get_confirmed_payouts.return_value = [payout]
            asyncio.run(svc._sync_payouts())
            assert len(sm.get_payouts("monero")) == 1
            svc.alert_service.payout_confirmed_alert.assert_awaited_once_with(
                "monero", 250_000_000_000, "aa"
            )
        finally:
            sm.close()

    def test_restart_replay_does_not_realert(self):
        # The same payout seen again (a re-scan of the tip) inserts nothing new → no second alert.
        svc, sm = self._svc_with_real_storage()
        try:
            payout = {"txid": "aa", "height": 100, "ts": 1000.0, "amount_atomic": 1}
            svc.wallet_client.get_confirmed_payouts.return_value = [payout]
            asyncio.run(svc._sync_payouts())
            asyncio.run(svc._sync_payouts())
            assert svc.alert_service.payout_confirmed_alert.await_count == 1
            assert len(sm.get_payouts("monero")) == 1
        finally:
            sm.close()

    def test_seeds_min_height_from_stored_max(self):
        # The poll must query from the highest stored height so it re-scans only the tip.
        svc, sm = self._svc_with_real_storage()
        try:
            sm.add_payouts(
                "monero", [{"txid": "old", "height": 500, "ts": 1.0, "amount_atomic": 1}]
            )
            svc.wallet_client.get_confirmed_payouts.return_value = []
            asyncio.run(svc._sync_payouts())
            svc.wallet_client.get_confirmed_payouts.assert_called_once_with(500)
        finally:
            sm.close()

    def test_empty_poll_is_a_quiet_noop(self):
        svc, sm = self._svc_with_real_storage()
        try:
            svc.wallet_client.get_confirmed_payouts.return_value = []
            asyncio.run(svc._sync_payouts())
            svc.alert_service.payout_confirmed_alert.assert_not_awaited()
        finally:
            sm.close()

    def test_disabled_feature_leaves_no_wallet_client(self, monkeypatch):
        monkeypatch.setattr(ds_mod, "PAYOUT_CONFIRM_ENABLED", False)
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.wallet_client is None
