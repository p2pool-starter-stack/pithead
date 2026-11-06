# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestXvbStatsSync:
    async def test_successful_fetch_persists_stats(self, xvb_service):
        svc, sm = xvb_service
        svc.xvb_client.get_stats.return_value = {
            "avg_1h": 12_000.0,
            "avg_24h": 11_000.0,
            "fail_count": 2,
        }
        await svc._sync_xvb_stats()
        stats = sm.get_xvb_stats()
        assert stats["avg_1h"] == 12_000.0
        assert stats["avg_24h"] == 11_000.0
        assert stats["fail_count"] == 2
        assert stats["last_update"] > 0

    async def test_failed_fetch_writes_nothing(self, xvb_service, monkeypatch):
        svc, sm = xvb_service
        monkeypatch.setattr(time, "time", lambda: 10_000.0)
        svc.xvb_client.get_stats.return_value = {
            "avg_1h": 12_000.0,
            "avg_24h": 11_000.0,
            "fail_count": 0,
        }
        await svc._sync_xvb_stats()
        before = sm.get_xvb_stats()
        monkeypatch.setattr(time, "time", lambda: 20_000.0)
        svc.xvb_client.get_stats.return_value = None
        await svc._sync_xvb_stats()
        after = sm.get_xvb_stats()
        for key in ("avg_1h", "avg_24h", "last_update"):
            assert after[key] == before[key]

    def _svc_with_real_storage(self):
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
