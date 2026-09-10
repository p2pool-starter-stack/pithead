# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestTelemetryBackboneHooks:
    """v1.7 telemetry backbone (#196 Wave-0): the blocks/disk_growth/network_history/
    worker_history capture hooks wired into run(), verified end-to-end against a real in-memory
    StateManager so "a row landed" is provable, not just "the mock was called". (xvb_history's
    hook lives on ``_sync_xvb_stats`` and is covered directly in TestXvbStatsSync above.)"""

    def _svc(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        proxy = MagicMock()
        svc = DataService(sm, proxy, MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        return svc, sm, proxy

    async def _run_one(
        self, svc, *, p2pool_stats=None, network_stats=None, disk_usage=None, monero_sync=None
    ):
        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={"is_syncing": False, "reachable": True}
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(
                ds_mod, "get_network_stats", return_value=network_stats or {"height": 100}
            ),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value=p2pool_stats
                or {"pool": {"last_share_time": 0, "difficulty": 0, "blocks_found": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value=monero_sync or {"is_syncing": False, "reachable": True}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value=disk_usage or {}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

    async def test_block_hook_baselines_without_backfill_on_first_poll(self):
        # First-ever poll must never backfill the whole historical block count as one event.
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        await self._run_one(
            svc, p2pool_stats={"pool": {"last_share_time": 0, "difficulty": 0, "blocks_found": 3}}
        )
        assert sm.get_blocks() == []
        assert svc._last_blocks_found == 3

    async def test_block_hook_writes_a_row_on_a_new_block(self):
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        svc._last_blocks_found = 5  # a prior poll already baselined
        await self._run_one(
            svc,
            p2pool_stats={
                "pool": {
                    "last_share_time": 0,
                    "difficulty": 0,
                    "blocks_found": 6,
                    "last_block_found": 3_100_000,
                }
            },
            network_stats={"height": 100, "difficulty": 999.0},
        )
        rows = sm.get_blocks()
        assert len(rows) == 1
        assert rows[0]["height"] == 3_100_000
        assert rows[0]["difficulty"] == 999.0

    async def test_block_hook_quiet_when_counter_unchanged(self):
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        svc._last_blocks_found = 6
        await self._run_one(
            svc, p2pool_stats={"pool": {"last_share_time": 0, "difficulty": 0, "blocks_found": 6}}
        )
        assert sm.get_blocks() == []

    async def test_hourly_hooks_write_disk_growth_and_network_history_on_first_poll(self):
        # `_last_hourly_capture` starts at 0.0, so the first poll is always due.
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        await self._run_one(
            svc,
            network_stats={"height": 100, "difficulty": 1e9, "reward": 0.6},
            disk_usage={"used_gb": 100.0, "total_gb": 500.0},
            monero_sync={"is_syncing": False, "reachable": True, "db_size": 123456},
        )
        disk_rows = sm.get_disk_growth()
        assert len(disk_rows) == 1
        assert disk_rows[0]["monero_db_bytes"] == 123456
        assert disk_rows[0]["disk_used_gb"] == 100.0
        assert disk_rows[0]["disk_total_gb"] == 500.0
        net_rows = sm.get_network_history()
        assert len(net_rows) == 1
        assert net_rows[0]["difficulty"] == 1e9
        assert net_rows[0]["reward"] == 0.6

    async def test_hourly_hooks_suppressed_when_gate_not_due(self):
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        svc._last_hourly_capture = time.time()  # just captured — not due for another hour
        await self._run_one(svc)
        assert sm.get_disk_growth() == []
        assert sm.get_network_history() == []

    async def test_worker_history_hook_writes_a_row_for_each_online_worker(self):
        # proxy list row: connections=1 (online), idx8=1.0 kH/s (h10), idx9=2.0 kH/s (h15).
        svc, sm, proxy = self._svc()
        worker_row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        proxy.get_workers.return_value = {"workers": [worker_row]}
        proxy.get_summary.return_value = {"results": {}}
        await self._run_one(svc)
        rows = sm.get_worker_history()
        assert len(rows) == 1
        assert rows[0]["name"] == "rig1"
        assert rows[0]["h15"] == 2000.0

    async def test_worker_history_hook_skips_offline_workers(self):
        svc, sm, proxy = self._svc()
        offline_row = ["rig1", "10.0.0.1", 0, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]  # connections=0
        proxy.get_workers.return_value = {"workers": [offline_row]}
        await self._run_one(svc)
        assert sm.get_worker_history() == []

    async def test_worker_history_hook_suppressed_when_gate_not_due(self):
        svc, sm, proxy = self._svc()
        worker_row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        proxy.get_workers.return_value = {"workers": [worker_row]}
        svc._last_worker_capture = time.time()
        await self._run_one(svc)
        assert sm.get_worker_history() == []

    async def test_table_health_reflects_a_forced_block_write_failure(self):
        # The whole poll loop is one try/except, so a hook that starts failing must be visible
        # via the per-table health signal, not just swallowed silently.
        svc, sm, proxy = self._svc()
        proxy.get_workers.return_value = {"workers": []}
        with sm._db_lock:
            sm._conn.execute("DROP TABLE blocks")
        svc._last_blocks_found = 5
        await self._run_one(
            svc, p2pool_stats={"pool": {"last_share_time": 0, "difficulty": 0, "blocks_found": 6}}
        )
        assert sm.get_table_health()["blocks"]["healthy"] is False
