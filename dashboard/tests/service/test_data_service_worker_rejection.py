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
