# ruff: noqa: F403, F405
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
        svc.tor_healer = MagicMock(failing=False)
        svc.monero_health.healthy = svc.tari_health.healthy = True
        return svc

    @staticmethod
    def _p2p(**kw):
        return {"p2p": {"uptime": 900, "out_peers": 2, "in_peers": 0, "zmq_active": 3, **kw}}

    def _cycle(self, svc, p2pool=None, health=None, tor=False):
        svc.tor_healer.failing = tor
        svc._update_mining_guard({"health": health or {"level": "green"}}, p2pool or self._p2p())
        return svc._apply_worker_rejection(False, False)

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
            ({"p2pool": {"p2p": {"uptime": 9, "out_peers": 0, "in_peers": 0}}}, "no sidechain"),
            ({"p2pool": {"p2p": {"uptime": 9, "out_peers": 1, "zmq_active": 900}}}, "ZMQ"),
        ],
    )
    async def test_invalid_work_stops_the_proxy_and_names_the_trigger(self, kwargs, needle):
        svc = self._svc()
        clock = [0]
        svc.mining_guard._clock = lambda: clock[0]
        await self._cycle(svc, **kwargs)
        clock[0] = 10_000
        await self._cycle(svc, **kwargs)
        assert svc.workers_rejected is True
        svc.docker_control.stop.assert_awaited_once_with(ds_mod.REJECT_WORKERS_CONTAINER)
        assert needle in svc.mining_guard.pause["reason"]

    async def test_p2pool_isolation_inside_grace_does_not_stop_the_proxy(self):
        svc = self._svc()
        isolated = {"p2p": {"uptime": 9, "out_peers": 0, "in_peers": 0}}
        await self._cycle(svc, p2pool=isolated)
        assert svc.workers_rejected is False
        svc.docker_control.stop.assert_not_called()

    async def test_tor_failure_past_grace_stops_the_proxy(self):
        svc = self._svc()
        clock = [0]
        svc.mining_guard._clock = lambda: clock[0]
        await self._cycle(svc, tor=True)
        assert svc.workers_rejected is False
        clock[0] = 10_000
        await self._cycle(svc, tor=True)
        assert svc.workers_rejected is True
        assert "Tor" in svc.mining_guard.pause["reason"]

    async def test_readmits_only_after_every_trigger_clears_and_recovers(self):
        svc = self._svc()
        clock = [0]
        svc.mining_guard._clock = lambda: clock[0]
        zmq_stale = {"p2p": {"uptime": 9, "out_peers": 1, "zmq_active": 900}}
        await self._cycle(svc, p2pool=zmq_stale)
        clock[0] = 100
        await self._cycle(svc, p2pool=zmq_stale)
        assert svc.workers_rejected is True
        for at in (110, 169):
            clock[0] = at
            await self._cycle(svc)
            assert svc.workers_rejected is True
        clock[0] = 170
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
