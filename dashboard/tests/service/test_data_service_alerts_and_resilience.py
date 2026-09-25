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

    async def test_run_wires_computed_signals_into_the_alerter(self):
        # Wiring guard: the unit tests prove each signal → the right alert in isolation; this proves
        # the data loop actually hands the alerter the full contract each cycle (so a dropped/renamed
        # kwarg, or forgetting the daily-summary call, fails here rather than silently going dark).
        svc, sm, proxy = _make_service()
        sm.is_db_healthy.return_value = True
        proxy.get_workers.return_value = {"workers": []}
        svc._apply_worker_rejection = AsyncMock()
        svc.alert_service = MagicMock()
        # Disabled → the loop skips the per-cycle build_metrics (a MagicMock state_manager can't feed
        # it); process()/maybe_daily_summary are still called every cycle regardless.
        svc.alert_service.enabled = False
        svc.alert_service.process = AsyncMock()
        svc.alert_service.maybe_daily_summary = AsyncMock()

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
            patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
            patch.object(ds_mod, "get_tari_stats", return_value={"active": True, "height": 3}),
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
            patch.object(ds_mod, "get_disk_usage", return_value={"percent": 42}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(StopAsyncIteration):
                await svc.run()

        svc.alert_service.process.assert_awaited_once()
        kw = svc.alert_service.process.await_args.kwargs
        # The full signal contract the AlertService.evaluate() unit tests rely on.
        assert set(kw) >= {
            "monero_down",
            "tari_down",
            "tari_required",
            "miner_released",
            "workers",
            "workers_expected",
            "disk_percent",
            "db_healthy",
            "xvb_enabled",
            "shares_in_window",
            "clearnet_active",
            "xvb_registration_state",
            "update_available",
            "low_hr_warning",
            "hugepages_reserved",
            "low_ram",
            "blocks_found_total",
            "block_height",
            "containers",
        }
        # ...sourced from the real computed values, not placeholders.
        assert kw["db_healthy"] is True  # from state_manager.is_db_healthy()
        assert kw["disk_percent"] == 42  # from get_disk_usage()
        assert isinstance(kw["workers"], list)
        # The once-daily digest is wired in too.
        svc.alert_service.maybe_daily_summary.assert_awaited_once()

    async def test_run_releases_despite_height_override(self):
        # Both nodes are synced per their RPC/gRPC, but p2pool is held so its stats file is
        # empty → get_network_stats height 0 trips the UI "syncing" override. The gate must
        # key off the raw sync signals (captured before the override) or it would deadlock,
        # never starting p2pool because p2pool isn't running. (Releases → start the miner.)
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}

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
            patch.object(ds_mod, "get_network_stats", return_value={"height": 0}),
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

        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        assert svc.miner_released is True
        # The UI override still marks Monero as syncing for display — that's fine; only the
        # gate must ignore it.
        assert svc.latest_data["monero_sync"]["is_syncing"] is True

    async def test_run_nonblocking_tari_releases_and_stays_operational(self):
        # Monero synced, Tari still syncing, Tari non-blocking (#51): release the miner (don't
        # wait for Tari), keep the operational view (global_sync False), and flag Tari's
        # passive sync so the UI shows a "Tari syncing" indicator instead of the takeover.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}

        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(
            return_value={
                "is_syncing": True,
                "reachable": True,
                "percent": 42,
                "current": 42,
                "target": 100,
            }
        )
        tari_client.close = AsyncMock()

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "TARI_REQUIRED", False),
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

        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        assert svc.miner_released is True
        assert svc.latest_data["global_sync"] is False
        assert svc.latest_data["tari_syncing_passive"] is True

    async def test_stale_monitor_not_fed_without_a_synchronized_verdict(self):
        # No `synchronized` key (log-scrape fallback / remote node) = no verdict (#972): the
        # stale monitor must not be fed, so its streaks stay put across blind cycles.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.monero_sync_stale = MagicMock()
        svc.monero_sync_stale.down = False
        await self._run_one_iteration(
            svc,
            monero_sync={"is_syncing": False, "reachable": True},
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.monero_sync_stale.update.assert_not_called()
        assert svc.latest_data["monero_sync"]["stale"] is False

    async def test_stale_flag_fed_surfaced_and_passed_to_the_alerter(self):
        # RPC verdict present (#972): the monitor is fed the raw flag, its debounced `down`
        # lands in the snapshot as `stale`, and the alerter receives it as monero_stale.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.monero_sync_stale = MagicMock()
        svc.monero_sync_stale.down = True
        svc.alert_service.process = AsyncMock(return_value=[])
        await self._run_one_iteration(
            svc,
            monero_sync={"is_syncing": False, "reachable": True, "synchronized": False},
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.monero_sync_stale.update.assert_called_once_with(False)
        assert svc.latest_data["monero_sync"]["stale"] is True
        assert svc.alert_service.process.await_args.kwargs["monero_stale"] is True

    async def test_healthchecks_pinged_when_healthy(self):
        # Enabled + healthy → a plain liveness ping (no args) each cycle.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.healthchecks = MagicMock()
        svc.healthchecks.enabled = True
        svc.healthchecks.ping.return_value = True

        await self._run_one_iteration(
            svc,
            monero_sync={
                "is_syncing": False,
                "reachable": True,
                "percent": 100,
                "current": 100,
                "target": 100,
            },
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.healthchecks.ping.assert_called_once_with()

    async def test_healthchecks_pinged_even_when_a_node_is_down(self):
        # Pure dead-man's switch: the heartbeat reports only that the STACK is alive, so a node
        # being down must NOT change or suppress the ping (that's the Telegram alerter's job, #121).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.healthchecks = MagicMock()
        svc.healthchecks.enabled = True
        svc.healthchecks.ping.return_value = True

        await self._run_one_iteration(
            svc,
            monero_sync={"is_syncing": False, "reachable": False},  # monerod down
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.healthchecks.ping.assert_called_once_with()

    async def test_healthchecks_not_pinged_when_disabled(self):
        # Default: the disabled client is never invoked from the loop (no worker thread).
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        svc.healthchecks = MagicMock()
        svc.healthchecks.enabled = False

        await self._run_one_iteration(
            svc,
            monero_sync={"is_syncing": False, "reachable": True},
            tari_sync={"is_syncing": False, "reachable": True},
        )
        svc.healthchecks.ping.assert_not_called()

    async def test_iteration_survives_collector_error(self):
        svc, sm, proxy = _make_service()
        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value={})

        with (
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "get_stratum_stats", side_effect=RuntimeError("boom")),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            # The error is caught inside the loop; the sleep after it raises to stop us.
            with pytest.raises(StopAsyncIteration):
                await svc.run()
