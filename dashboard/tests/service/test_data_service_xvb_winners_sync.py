# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestXvbWinnersSync:
    _WIN = {"ts": 1000.0, "hashrate": 4.2e6, "height": 100, "block_id": "aa11", "tier": "donor"}
    _STATS = {"types": {"donor": {"rounds": 4, "players_avg": 70.0}}, "span_days": 4.0}

    def _fetch(self, wins, stats=None):
        return {"wins": wins, "round_stats": stats if stats is not None else self._STATS}

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        # Adaptive-gate reads (#892): defaults that resolve to the 30-min baseline.
        sm.get_xvb_stats.return_value = {}
        sm.get_tiers.return_value = {}
        sm.get_raffle_wins.return_value = []
        xvb = MagicMock()
        return DataService(sm, MagicMock(), xvb), sm, xvb

    async def test_successful_fetch_persists_wins(self, xvb_service):
        svc, sm = xvb_service
        svc.xvb_client.get_recent_wins.return_value = self._fetch([self._WIN])
        await svc._sync_xvb_winners()
        assert sm.get_raffle_wins(0) == [self._WIN]
        cached = sm.get_xvb_round_stats()
        assert cached["stats"] == self._STATS
        assert cached["last_update"] > 0
        assert svc._last_xvb_winners_sync > 0

    async def test_unparseable_round_stats_do_not_overwrite_the_cached_aggregate(
        self, xvb_service, monkeypatch
    ):
        svc, sm = xvb_service
        monkeypatch.setattr(time, "time", lambda: 10_000.0)
        svc.xvb_client.get_recent_wins.return_value = self._fetch([self._WIN])
        await svc._sync_xvb_winners()
        before = sm.get_xvb_round_stats()
        svc._last_xvb_winners_sync = 0.0
        monkeypatch.setattr(time, "time", lambda: 20_000.0)
        new_win = {**self._WIN, "block_id": "bb22", "height": 101, "ts": 2000.0}
        svc.xvb_client.get_recent_wins.return_value = self._fetch(
            [new_win], stats={"types": {}, "span_days": 0.0}
        )
        await svc._sync_xvb_winners()
        assert sm.get_xvb_round_stats() == before
        assert sm.get_raffle_wins(0) == [self._WIN, new_win]

    async def test_failed_fetch_writes_nothing_and_leaves_the_gate_open(self):
        svc, sm, xvb = self._svc()
        xvb.get_recent_wins.return_value = None
        await svc._sync_xvb_winners()
        sm.add_raffle_wins.assert_not_called()
        sm.set_xvb_round_stats.assert_not_called()
        # Gate NOT stamped: the next eligible poll retries instead of waiting out 30 min.
        assert svc._last_xvb_winners_sync == 0.0

    async def test_wallclock_gate_suppresses_a_too_soon_second_fetch(self):
        svc, sm, xvb = self._svc()
        xvb.get_recent_wins.return_value = self._fetch([])
        await svc._sync_xvb_winners()
        await svc._sync_xvb_winners()
        assert xvb.get_recent_wins.call_count == 1

    async def test_gate_reopens_once_the_cadence_elapses(self):
        svc, sm, xvb = self._svc()
        xvb.get_recent_wins.return_value = self._fetch([])
        await svc._sync_xvb_winners()
        svc._last_xvb_winners_sync -= 1801  # simulate 30+ minutes having passed
        await svc._sync_xvb_winners()
        assert xvb.get_recent_wins.call_count == 2

    async def test_a_new_win_round_trips_through_real_storage(self):
        # A real in-memory StateManager so the persisted row is provable end to end — and the
        # raffle_win alert fires exactly once per new win: the idempotent insert means the
        # second sync re-reading the same file window neither re-stores nor re-alerts.
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.alert_service = AsyncMock()
        try:
            svc.xvb_client.get_recent_wins.return_value = self._fetch([self._WIN])
            await svc._sync_xvb_winners()
            rows = sm.get_raffle_wins()
            assert len(rows) == 1
            assert rows[0]["block_id"] == "aa11"
            svc.alert_service.raffle_win_alert.assert_awaited_once_with("donor", 4.2e6)
            # A second sync past the gate re-reads the same file window — still one row, no re-alert.
            svc._last_xvb_winners_sync -= 1801
            await svc._sync_xvb_winners()
            assert len(sm.get_raffle_wins()) == 1
            svc.alert_service.raffle_win_alert.assert_awaited_once()
        finally:
            sm.close()
