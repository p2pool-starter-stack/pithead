# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestXvbStatsSync:
    """XvB stats fetch → persist (#163), and the #311 precondition: a FAILED fetch must write
    nothing, so the last reading and ``last_update`` stay frozen and the staleness guard can fire.
    This is the integration seam the algo-level unit tests assume but can't see."""

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        xvb = MagicMock()
        return DataService(sm, MagicMock(), xvb), sm, xvb

    async def test_successful_fetch_persists_stats(self):
        svc, sm, xvb = self._svc()
        xvb.get_stats.return_value = {"avg_1h": 12_000.0, "avg_24h": 11_000.0, "fail_count": 0}
        await svc._sync_xvb_stats()
        sm.update_xvb_stats.assert_called_once_with(avg_1h=12_000.0, avg_24h=11_000.0, fail_count=0)

    async def test_failed_fetch_writes_nothing(self):
        # #311 linchpin: get_stats() returns None on a Tor timeout / 5xx. Persisting nothing is what
        # keeps last_update frozen so the controller can detect the feed is stale. If this regresses
        # to stamping on failure, the staleness guard silently never triggers.
        svc, sm, xvb = self._svc()
        xvb.get_stats.return_value = None
        await svc._sync_xvb_stats()
        sm.update_xvb_stats.assert_not_called()

    def _svc_with_real_storage(self):
        # v1.7 telemetry backbone (#196 Wave-0): a real in-memory StateManager so a captured
        # xvb_history row is provable, not just "the mock was called".
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    async def test_first_fetch_writes_an_xvb_history_row(self):
        svc, sm = self._svc_with_real_storage()
        try:
            svc.xvb_client.get_stats.return_value = {
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
            }
            await svc._sync_xvb_stats()
            rows = sm.get_xvb_history()
            assert len(rows) == 1
            assert rows[0]["avg_1h"] == 1000.0
            assert rows[0]["mode"] == "P2POOL"  # the default xvb state, before any mode switch
        finally:
            sm.close()

    async def test_wallclock_gate_suppresses_a_too_soon_second_write(self):
        # The capture cadence is a wall-clock gate (~5 min), not iteration-count-based — two
        # fetches back-to-back in the same test must not double-write.
        svc, sm = self._svc_with_real_storage()
        try:
            svc.xvb_client.get_stats.return_value = {
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
            }
            await svc._sync_xvb_stats()
            await svc._sync_xvb_stats()
            assert len(sm.get_xvb_history()) == 1
        finally:
            sm.close()

    async def test_gate_reopens_once_the_cadence_elapses(self):
        svc, sm = self._svc_with_real_storage()
        try:
            svc.xvb_client.get_stats.return_value = {
                "avg_1h": 1000.0,
                "avg_24h": 900.0,
                "fail_count": 0,
            }
            await svc._sync_xvb_stats()
            svc._last_xvb_history_write -= 301  # simulate 5+ minutes having passed
            await svc._sync_xvb_stats()
            assert len(sm.get_xvb_history()) == 2
        finally:
            sm.close()
