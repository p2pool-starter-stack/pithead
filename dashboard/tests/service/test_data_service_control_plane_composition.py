# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestControlPlaneComposition:
    """Compositions of the sync-gate (#35) and failover (#31) the per-feature tests don't
    cover on their own: the required-Tari hold, and the two features coexisting after release."""

    async def test_run_holds_when_tari_required_and_only_monero_synced(self):
        # Monero synced, Tari still syncing, Tari REQUIRED: the gate condition
        # `monero_synced AND (tari_synced OR NOT TARI_REQUIRED)` is NOT satisfied, so the
        # miner stays held until Tari also finishes — the mirror of the non-blocking case.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc._apply_worker_rejection = AsyncMock()

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={
                "is_syncing": True,
                "reachable": True,
                "percent": 80,
                "current": 80,
                "target": 100,
            }
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "TARI_REQUIRED", True),
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
                AsyncMock(return_value={"is_syncing": False, "reachable": True}),
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
        assert svc.miner_released is False
        assert svc.latest_data["miner_held"] is True

    async def test_post_release_blip_lets_failover_act_without_rehold(self):
        # After release, a node-down event must NOT be re-held by the sync gate (the #35
        # one-way latch), yet #31 failover must still stop the proxy so workers fail over.
        # The two coexist: gate no-ops, rejection acts on the proxy only.
        svc, _sm, _proxy = _make_service()
        svc.miner_released = True
        with (
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"),
        ):
            await svc._apply_sync_gate(gate_satisfied=False)  # latch → no-op
            await svc._apply_worker_rejection(monero_down=True)
        stopped = [c.args[0] for c in svc.docker_control.stop.await_args_list]
        assert stopped == ["xmrig-proxy"]  # p2pool was NOT re-held
        svc.docker_control.start.assert_not_called()
        assert svc.workers_rejected is True

    async def test_both_nodes_down_rejects_via_monero_leg(self):
        # A simultaneous Monero+Tari outage still rejects — driven by the monerod leg alone,
        # since Tari is no longer part of the decision (#897).
        svc, _sm, _proxy = _make_service()
        with patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"):
            await svc._apply_worker_rejection(monero_down=True)
        svc.docker_control.stop.assert_awaited_once_with("xmrig-proxy")
        assert svc.workers_rejected is True

    async def test_tari_only_outage_keeps_mining(self):
        # The #897 fix at the full-loop level: monerod healthy, Tari unreachable and required
        # ⇒ the proxy is never stopped, so workers keep mining Monero through the Tari outage.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.miner_released = True

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={"is_syncing": False, "reachable": False}
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"),
            patch.object(ds_mod, "TARI_REQUIRED", True),
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
                        "reachable": True,
                        "percent": 100,
                        "current": 100,
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

        svc.docker_control.stop.assert_not_called()
        assert svc.workers_rejected is False
