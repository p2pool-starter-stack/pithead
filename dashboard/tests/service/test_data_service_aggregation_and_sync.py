# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestRunIteration:
    async def _run_one_iteration(self, svc, monero_sync, tari_sync):
        """Drive a single loop iteration with the given per-node sync signals."""
        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value=tari_sync)
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            # The real get_stratum_stats returns a dict ({} on a missing/unreadable stats file);
            # the wallet tripwire (#375) reads .get("wallet") off it, so the mock must match.
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(ds_mod, "get_monero_sync_status", AsyncMock(return_value=monero_sync)),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

    async def test_single_iteration_aggregates(self):
        svc, sm, proxy = _make_service()

        # A proxy worker in the 6.x list format (>=13 fields): connections=1 (online),
        # idx8=1.0 kH/s, idx9=2.0 kH/s -> h15 = 2000 H/s.
        worker_row = ["rig1", "10.0.0.1", 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]
        proxy.get_workers.return_value = {"workers": [worker_row]}
        proxy.get_summary.return_value = {
            "results": {
                "accepted": 100,
                "rejected": 5,
                "invalid": 1,
                "expired": 2,
                "best": [123456],
            }
        }

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})  # direct API unreachable
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False})
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(
                    return_value={
                        "is_syncing": False,
                        "percent": 100,
                        "target": 100,
                        "current": 100,
                    }
                ),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        # The worker was aggregated and totals computed from proxy-derived hashrate.
        assert svc.latest_data["workers"][0]["name"] == "rig1"
        assert svc.latest_data["workers"][0]["status"] == "online"
        assert svc.latest_data["total_live_h15"] == 2000.0
        # The proxy /summary totals were collected and surfaced (Issue #82).
        assert svc.latest_data["proxy_summary"] == {
            "accepted": 100,
            "rejected": 5,
            "invalid": 1,
            "expired": 2,
            "best": 123456,
        }
        sm.update_history.assert_called()
        sm.save_snapshot.assert_called()

    async def test_share_stat_deltas_persisted(self, _totals):
        # #116 wiring: with a baseline from a previous poll, one iteration writes the counters'
        # deltas via add_share_stats (the delta rules themselves are unit-tested above).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        proxy.get_summary.return_value = {
            "results": {"accepted": 110, "rejected": 6, "invalid": 1, "expired": 2, "best": [1]}
        }
        svc._last_share_totals = _totals(accepted=100, rejected=5, invalid=1, expired=2)

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False})
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "percent": 100}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        # Only accepted (+10) and rejected (+1) advanced; the deltas — not the counters — landed.
        assert sm.add_share_stats.call_args.kwargs == {
            "accepted": 10,
            "rejected": 1,
            "invalid": 0,
            "expired": 0,
        }
        # Baseline advanced to the new cumulative totals for the next poll.
        assert svc._last_share_totals == _totals(accepted=110, rejected=6, invalid=1, expired=2)

    async def test_degradation_edge_records_event_and_alerts(self):
        # #99 wiring: when the detector reports an edge, the loop persists a chart marker and pushes
        # the hashrate_loss alert. Stub the detector so a single iteration produces a deterministic
        # edge (the debounce itself is unit-tested in test_degradation.py).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        proxy.get_summary.return_value = {"results": {}}
        svc.degradation = MagicMock()
        svc.degradation.update.return_value = ("loss", 0.6, 1000.0, 400.0)
        svc.alert_service.degradation_alert = AsyncMock()

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={"is_syncing": False})
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False, "percent": 100}),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        assert sm.add_event.call_args.args[1] == "hashrate_loss"
        svc.alert_service.degradation_alert.assert_awaited_once_with("loss", 0.6)

    async def test_run_holds_miner_while_syncing(self):
        # A syncing Monero node → gate holds p2pool + xmrig-proxy and #31's failover stays
        # dormant (no workers to fail over before we've even started mining).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc._apply_worker_rejection = AsyncMock()

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
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(
                ds_mod, "get_tari_stats", return_value={"active": True, "status": "OK", "height": 3}
            ),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(
                ds_mod,
                "get_monero_sync_status",
                AsyncMock(
                    return_value={
                        "is_syncing": True,
                        "reachable": True,
                        "percent": 50,
                        "current": 50,
                        "target": 100,
                    }
                ),
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        stopped = {c.args[0] for c in svc.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        svc.docker_control.start.assert_not_called()
        svc._apply_worker_rejection.assert_not_called()
        assert svc.miner_released is False
        assert svc.latest_data["miner_held"] is True
