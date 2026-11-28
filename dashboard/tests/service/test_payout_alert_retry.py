import asyncio
import time
from unittest.mock import AsyncMock, MagicMock

import pytest

from mining_dashboard.config import config
from mining_dashboard.service import payout_sync
from mining_dashboard.service.notify.alert_service import AlertService
from mining_dashboard.service.payout_identity import configured_wallet_id
from mining_dashboard.service.storage_service import StateManager
from tests.service.notify._alert_service_support import _FakeNotifier, _svc


class _Sink(_FakeNotifier):
    def __init__(self, ok=False, **kw):
        super().__init__(**kw)
        self.ok = ok

    def send(self, text, event=""):
        super().send(text, event)
        return self.ok


@pytest.fixture(autouse=True)
def _wallets(monkeypatch):
    monkeypatch.setattr(config, "MONERO_WALLET_ADDRESS", "fixture-wallet")
    monkeypatch.setattr(config, "TARI_WALLET_ADDRESS", "fixture-wallet")


def _scan(chain, payouts):
    if chain == "monero":
        client = MagicMock()
        client.payout_addresses.return_value = ["fixture-wallet"]
        client.scan.return_value = (payouts, True)
        return client, payout_sync.sync_monero
    client = MagicMock()
    client.payout_addresses = AsyncMock(return_value=(["fixture-wallet"], True))
    client.scan = AsyncMock(return_value=(payouts, True))
    return client, payout_sync.sync_tari


class TestAlertServiceResult:
    async def test_all_sinks_failing_reports_false(self):
        a, b = _Sink(ok=False), _Sink(ok=False)
        svc = _svc(notifier=a, sinks=[a, b])
        assert await svc.payout_confirmed_alert("monero", 1, "txid1234") is False
        assert len(a.sent) == len(b.sent) == 1

    async def test_one_sink_succeeding_reports_the_text(self):
        a, b = _Sink(ok=False), _Sink(ok=True)
        svc = _svc(notifier=a, sinks=[a, b])
        assert "Payout CONFIRMED" in await svc.payout_confirmed_alert("tari", 1, "txid1234")


@pytest.mark.parametrize("chain", ["monero", "tari"])
class TestPayoutAlertRetry:
    def _setup(self, chain, tmp_path, ok=False):
        db = str(tmp_path / "m.db")
        sm = StateManager(db_path=db)
        sink = _Sink(ok=ok)
        alerts = _svc(notifier=sink, sinks=[sink])
        payout = {"txid": "tx-aaaaaaaa", "height": 10, "ts": 1.0, "amount_atomic": 5}
        client, sync = _scan(chain, [payout])
        return db, sm, sink, alerts, client, sync

    def _run(self, sync, sm, client, alerts):
        return asyncio.run(sync(sm, client, alerts))

    def test_fail_then_recover_delivers_exactly_one_alert(self, chain, tmp_path):
        db, sm, sink, alerts, client, sync = self._setup(chain, tmp_path)
        try:
            self._run(sync, sm, client, alerts)
            assert len(sink.sent) == 1
            sink.ok = True
            self._run(sync, sm, client, alerts)
            assert len(sink.sent) == 2
            self._run(sync, sm, client, alerts)
            self._run(sync, sm, client, alerts)
            assert len(sink.sent) == 2
            assert sm.get_payout_alert_retries(chain, configured_wallet_id(chain)) == []
        finally:
            sm.close()

    def test_still_failing_keeps_retrying_until_delivered(self, chain, tmp_path):
        db, sm, sink, alerts, client, sync = self._setup(chain, tmp_path)
        try:
            for _ in range(3):
                self._run(sync, sm, client, alerts)
            assert len(sink.sent) == 3
            assert len(sm.get_payout_alert_retries(chain, configured_wallet_id(chain))) == 1
        finally:
            sm.close()

    def test_delivered_first_time_is_never_retried(self, chain, tmp_path):
        db, sm, sink, alerts, client, sync = self._setup(chain, tmp_path, ok=True)
        try:
            self._run(sync, sm, client, alerts)
            self._run(sync, sm, client, alerts)
            assert len(sink.sent) == 1
        finally:
            sm.close()

    def test_pending_alert_survives_a_dashboard_restart(self, chain, tmp_path):
        db, sm, sink, alerts, client, sync = self._setup(chain, tmp_path)
        self._run(sync, sm, client, alerts)
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            sink.ok = True
            empty_client, _ = _scan(chain, [])
            self._run(sync, sm2, empty_client, alerts)
            assert len(sink.sent) == 2
            self._run(sync, sm2, empty_client, alerts)
            assert len(sink.sent) == 2
        finally:
            sm2.close()

    def test_toggled_off_drops_the_pending_row_without_sending(self, chain, tmp_path):
        db, sm, sink, alerts, client, sync = self._setup(chain, tmp_path)
        try:
            self._run(sync, sm, client, alerts)
            sink._allow = set()
            self._run(sync, sm, client, alerts)
            assert len(sink.sent) == 1
            assert sm.get_payout_alert_retries(chain, configured_wallet_id(chain)) == []
        finally:
            sm.close()

    def test_no_sinks_never_records_a_retry(self, chain, tmp_path):
        sm = StateManager(db_path=str(tmp_path / "m.db"))
        try:
            client, sync = _scan(
                chain, [{"txid": "tx-bbbbbbbb", "height": 1, "ts": 1.0, "amount_atomic": 1}]
            )
            alerts = AlertService(notifier=_Sink(enabled=False), sinks=[])
            self._run(sync, sm, client, alerts)
            assert sm.get_payout_alert_retries(chain, configured_wallet_id(chain)) == []
        finally:
            sm.close()

    def test_expired_pending_row_is_dropped_unsent(self, chain, tmp_path):
        db, sm, sink, alerts, client, sync = self._setup(chain, tmp_path)
        try:
            wid = configured_wallet_id(chain)
            old = time.time() - payout_sync.PAYOUT_ALERT_RETRY_SEC - 10
            sm.add_payouts(chain, wid, [{"txid": "tx-old", "height": 1, "amount_atomic": 1}], True)
            sm._conn.execute("UPDATE payout_alert_retry SET first_ts = ?", (old,))
            sm._conn.commit()
            empty_client, _ = _scan(chain, [])
            self._run(sync, sm, empty_client, alerts)
            assert sink.sent == []
            assert sm.get_payout_alert_retries(chain, wid) == []
        finally:
            sm.close()

    def test_a_raising_sender_is_queued_for_retry(self, chain, tmp_path):
        db, sm, sink, alerts, client, sync = self._setup(chain, tmp_path)
        try:
            alerts.payout_confirmed_alert = AsyncMock(side_effect=RuntimeError("boom"))
            self._run(sync, sm, client, alerts)
            assert len(sm.get_payout_alert_retries(chain, configured_wallet_id(chain))) == 1
        finally:
            sm.close()

    def test_a_restart_before_any_send_still_delivers(self, chain, tmp_path):
        db = str(tmp_path / "m.db")
        sm = StateManager(db_path=db)
        wid = configured_wallet_id(chain)
        sm.add_payouts(chain, wid, [{"txid": "tx-cccccccc", "height": 3, "amount_atomic": 7}], True)
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            sink = _Sink(ok=True)
            client, sync = _scan(chain, [])
            self._run(sync, sm2, client, _svc(notifier=sink, sinks=[sink]))
            assert len(sink.sent) == 1
            assert sm2.get_payout_alert_retries(chain, wid) == []
        finally:
            sm2.close()

    def test_rows_of_a_previous_wallet_are_pruned(self, chain, tmp_path):
        db, sm, sink, alerts, client, sync = self._setup(chain, tmp_path)
        try:
            sm.add_payouts(
                chain, "old-wallet", [{"txid": "tx-d", "height": 1, "amount_atomic": 1}], True
            )
            empty_client, _ = _scan(chain, [])
            self._run(sync, sm, empty_client, alerts)
            assert sink.sent == []
            assert sm.get_payout_alert_retries(chain, "old-wallet") == []
        finally:
            sm.close()


class TestPayoutAlertStoreGuards:
    def test_no_wallet_reads_nothing(self):
        sm = StateManager(db_path=":memory:")
        try:
            assert sm.get_payout_alert_retries("monero", None) == []
        finally:
            sm.close()

    def test_without_a_connection_reads_and_clears_are_noops(self):
        sm = StateManager(db_path=":memory:")
        sm.close()
        sm._conn = None
        assert sm.get_payout_alert_retries("monero", "w") == []
        assert sm.clear_payout_alert_retry("monero", "w", "tx") is None

    def test_a_missing_table_is_logged_not_raised(self):
        sm = StateManager(db_path=":memory:")
        try:
            sm._conn.execute("DROP TABLE payout_alert_retry")
            assert sm.get_payout_alert_retries("monero", "w") == []
            sm.clear_payout_alert_retry("monero", "w", "tx")
            assert sm.is_db_healthy() is False
        finally:
            sm.close()
