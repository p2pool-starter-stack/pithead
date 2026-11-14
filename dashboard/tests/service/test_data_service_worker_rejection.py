# ruff: noqa: F403, F405
from mining_dashboard.collector import pools as pools_collector
from tests.service._data_service_support import *  # noqa: F403


class TestWorkerRejection:
    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        return svc

    @pytest.mark.parametrize("required", [True, False])
    @pytest.mark.parametrize(
        "monero_down,tari_down", [(True, False), (False, True), (True, True), (False, False)]
    )
    async def test_rejection_decision_table(self, required, monero_down, tari_down):
        svc = self._svc()
        with patch.object(ds_mod, "TARI_REQUIRED", required):
            await svc._apply_worker_rejection(monero_down, tari_down)
        expected = monero_down or (required and tari_down)
        assert svc.workers_rejected is expected
        assert svc.docker_control.stop.await_count == int(expected)
        svc.docker_control.start.assert_not_called()

    async def test_stop_failure_retries(self):
        svc = self._svc()
        svc.docker_control.stop.side_effect = [False, True]
        with patch.object(ds_mod, "TARI_REQUIRED", True):
            await svc._apply_worker_rejection(False, True)
            assert svc.workers_rejected is False
            await svc._apply_worker_rejection(False, True)
        assert svc.workers_rejected is True
        assert svc.docker_control.stop.await_count == 2

    @pytest.mark.parametrize("required", [True, False])
    @pytest.mark.parametrize(
        "monero_healthy,tari_healthy", [(True, True), (True, False), (False, True), (False, False)]
    )
    async def test_readmission_requires_confirmed_health(
        self, required, monero_healthy, tari_healthy
    ):
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = monero_healthy
        svc.tari_health.healthy = tari_healthy
        with patch.object(ds_mod, "TARI_REQUIRED", required):
            await svc._apply_worker_rejection(False, False)
        expected = monero_healthy and (tari_healthy or not required)
        assert svc.workers_rejected is not expected
        assert svc.docker_control.start.await_count == int(expected)

    async def test_no_double_stop_or_readmit_during_outage(self):
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = svc.tari_health.healthy = True
        with patch.object(ds_mod, "TARI_REQUIRED", True):
            await svc._apply_worker_rejection(False, True)
        svc.docker_control.stop.assert_not_called()
        svc.docker_control.start.assert_not_called()

    async def test_start_failure_retries_then_no_double_start(self):
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = svc.tari_health.healthy = True
        svc.docker_control.start.side_effect = [False, True]
        for expected in (True, False, False):
            await svc._apply_worker_rejection(False, False)
            assert svc.workers_rejected is expected
        assert svc.docker_control.start.await_count == 2

    async def test_required_tari_uses_outage_and_recovery_debounce(self):
        svc = self._svc()
        now = [0]
        svc.tari_health._clock = lambda: now[0]
        svc.tari_health.down_after = 4
        svc.tari_health.recovery_after = 3
        svc.monero_health.healthy = True
        with patch.object(ds_mod, "TARI_REQUIRED", True):
            for time, reachable, rejected in (
                (0, True, False),
                (1, False, False),
                (4, False, False),
                (5, False, True),
                (6, True, True),
                (8, True, True),
                (9, True, False),
            ):
                now[0] = time
                await svc._apply_worker_rejection(False, svc.tari_health.update(reachable))
                assert svc.workers_rejected is rejected
        svc.docker_control.stop.assert_awaited_once()
        svc.docker_control.start.assert_awaited_once()

    @pytest.mark.parametrize("local", [True, False])
    @pytest.mark.parametrize("required", [True, False])
    async def test_local_and_remote_rpc_outages_reject(self, local, required):
        from mining_dashboard.collector import logs

        svc = self._svc()
        svc.monero_health.down_after = 0
        with (
            patch.object(ds_mod, "TARI_REQUIRED", required),
            patch.object(logs, "LOCAL_MONERO_HOST", "local.example"),
            patch.object(logs, "MONERO_NODE_HOST", "local.example" if local else "remote.example"),
            patch.object(logs, "get_monero_peers", AsyncMock(return_value={})),
            patch.object(
                logs,
                "_get_monero_sync_status_from_logs",
                AsyncMock(return_value={"is_syncing": False}),
            ),
            patch.object(
                logs,
                "_get_remote_monero_sync_status",
                AsyncMock(return_value={"is_syncing": False}),
            ),
            patch.object(
                logs._monero_client, "get_sync_status", side_effect=[{"is_syncing": False}, None]
            ),
        ):
            for _ in range(2):
                sync = await logs.get_monero_sync_status()
                await svc._apply_worker_rejection(
                    svc.monero_health.update(sync["reachable"]), False
                )
        svc.docker_control.stop.assert_awaited_once_with(ds_mod.REJECT_WORKERS_CONTAINER)
        assert svc.workers_rejected is True

    def test_tari_outage_default_is_fifteen_minutes_without_changing_monero(self):
        from mining_dashboard.config.config import NODE_DOWN_AFTER_SEC

        svc = self._svc()
        assert svc.tari_health.down_after == 15 * 60
        assert svc.monero_health.down_after == NODE_DOWN_AFTER_SEC

    async def test_long_tari_outage_requires_the_full_default_window(self):
        svc = self._svc()
        now = [0]
        svc.tari_health._clock = lambda: now[0]
        svc.monero_health.healthy = True
        with patch.object(ds_mod, "TARI_REQUIRED", True):
            svc.tari_health.update(True)
            for time, rejected in ((0, False), (90, False), (899, False), (900, True)):
                now[0] = time
                await svc._apply_worker_rejection(False, svc.tari_health.update(False))
                assert svc.workers_rejected is rejected


class TestMiningGuardRejection:
    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        svc.monero_health.healthy = svc.tari_health.healthy = True
        return svc

    @staticmethod
    def _p2p(**kw):
        return {"p2p": {"uptime": 900, "out_peers": 2, "in_peers": 0, "zmq_active": 3, **kw}}

    async def _cycle(self, svc, p2pool=None, health=None, sync=None, containers=None, signals=None):
        monero_sync = {"health": health or {"level": "green"}, **(sync or {})}
        with (
            patch.object(ds_mod, "get_container_health", AsyncMock(return_value=containers or {})),
            patch.object(
                pools_collector,
                "get_p2pool_log_signals",
                AsyncMock(return_value=signals or {"lag": 0, "monerod_unsynced": False}),
            ),
        ):
            await svc._update_mining_guard(monero_sync, p2pool or self._p2p())
        await svc._apply_worker_rejection(False, False)

    @staticmethod
    def _clock(svc):
        now = [0]
        svc.mining_guard._clock = lambda: now[0]
        return now

    async def _hold_past_grace(self, svc, **kwargs):
        now = self._clock(svc)
        await self._cycle(svc, **kwargs)
        now[0] = 10_000
        await self._cycle(svc, **kwargs)
        return now

    async def test_healthy_node_never_rejects(self):
        svc = self._svc()
        await self._cycle(svc)
        assert svc.workers_rejected is False
        svc.docker_control.stop.assert_not_called()

    @pytest.mark.parametrize(
        "kwargs,needle",
        [
            (
                {"health": {"level": "red", "reasons": ["0 outgoing peers for 10 min"]}},
                "0 outgoing peers",
            ),
            ({"health": {"peers_out": 0}}, "0 outgoing peers"),
            ({"sync": {"synchronized": False}}, "not synchronized"),
            ({"p2pool": {"p2p": {"uptime": 9, "out_peers": 0, "in_peers": 0}}}, "no sidechain"),
            ({"p2pool": {"p2p": {"uptime": 9, "out_peers": 1, "zmq_active": 900}}}, "ZMQ"),
            (
                {
                    "health": {"advance_age_sec": 900},
                    "signals": {"lag": 480, "monerod_unsynced": False},
                },
                "480 blocks behind",
            ),
            (
                {"signals": {"lag": 0, "monerod_unsynced": True}},
                "P2Pool reports monerod is not synchronized",
            ),
            (
                {"containers": {"p2pool": {"running": False, "restarting": False, "health": None}}},
                "P2Pool container is not running",
            ),
            (
                {
                    "containers": {
                        "tor": {"running": True, "restarting": False, "health": "starting"}
                    }
                },
                "Tor container is starting",
            ),
        ],
    )
    async def test_invalid_work_stops_the_proxy_and_names_the_trigger(self, kwargs, needle):
        svc = self._svc()
        await self._hold_past_grace(svc, **kwargs)
        assert svc.workers_rejected is True
        svc.docker_control.stop.assert_awaited_once_with(ds_mod.REJECT_WORKERS_CONTAINER)
        assert needle in svc.mining_guard.pause["reason"]

    async def test_isolation_inside_grace_does_not_stop_the_proxy(self):
        svc = self._svc()
        isolated = {"p2p": {"uptime": 9, "out_peers": 0, "in_peers": 0}}
        await self._cycle(svc, p2pool=isolated)
        assert svc.workers_rejected is False
        svc.docker_control.stop.assert_not_called()

    async def test_default_config_tor_failure_stops_the_proxy(self):
        svc = self._svc()
        assert svc.tor_healer.enabled is False
        tor = {"tor": {"running": True, "restarting": False, "health": "unhealthy"}}
        await self._hold_past_grace(svc, containers=tor)
        assert svc.workers_rejected is True

    async def test_readmits_only_after_every_trigger_clears_and_recovers(self):
        svc = self._svc()
        zmq_stale = {"p2p": {"uptime": 9, "out_peers": 1, "zmq_active": 900}}
        now = await self._hold_past_grace(svc, p2pool=zmq_stale)
        assert svc.workers_rejected is True
        for at in (10_010, 10_069):
            now[0] = at
            await self._cycle(svc)
            assert svc.workers_rejected is True
        now[0] = 10_070
        await self._cycle(svc)
        assert svc.workers_rejected is False
        svc.docker_control.start.assert_awaited_once_with(ds_mod.REJECT_WORKERS_CONTAINER)

    async def test_a_relapse_inside_grace_blocks_readmission(self):
        svc = self._svc()
        svc.workers_rejected = True
        isolated = {"p2p": {"uptime": 9, "out_peers": 0, "in_peers": 0}}
        await self._cycle(svc, p2pool=isolated)
        assert svc.workers_rejected is True
        svc.docker_control.start.assert_not_called()

    async def test_restart_mid_pause_does_not_readmit_onto_a_peerless_node(self):
        svc = self._svc()
        svc.workers_rejected = True
        await self._cycle(svc, health={"level": "unknown", "peers_out": 0})
        assert svc.workers_rejected is True
        svc.docker_control.start.assert_not_called()

    async def test_a_failed_read_keeps_the_pause_instead_of_clearing_it(self):
        svc = self._svc()
        down = {"p2pool": {"running": False, "restarting": False, "health": None}}
        now = await self._hold_past_grace(svc, containers=down)
        assert svc.workers_rejected is True
        for at in (10_100, 10_500):
            now[0] = at
            await self._cycle(svc, containers={})
            assert svc.workers_rejected is True
        svc.docker_control.start.assert_not_called()
