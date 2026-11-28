# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403

PROXY = "xmrig-proxy"


class TestRejectReassert:
    def _svc(self, running=None, rejected=True):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        svc.workers_rejected = rejected
        if running is not None:
            svc.container_snapshot = {PROXY: {"running": running}}
        return svc

    async def test_running_proxy_is_stopped_again_once_with_one_warning(self, caplog):
        svc = self._svc(running=True)
        await svc._apply_worker_rejection(True, False)
        svc.docker_control.stop.assert_awaited_once_with(PROXY, quiet=True)
        assert caplog.text.count("found running while workers are rejected") == 1
        assert svc.workers_rejected is True

    async def test_failed_restop_retries_without_a_new_warning(self, caplog):
        svc = self._svc(running=True)
        svc.docker_control.stop.side_effect = [False, False, True]
        for _ in range(3):
            await svc._apply_worker_rejection(True, False)
        assert svc.docker_control.stop.await_count == 3
        assert caplog.text.count("found running while workers are rejected") == 1

    async def test_stopped_or_unlisted_proxy_is_left_alone(self):
        for svc in (self._svc(running=False), self._svc()):
            await svc._apply_worker_rejection(True, False)
            svc.docker_control.stop.assert_not_called()

    async def test_persisted_rejection_with_running_proxy_stops_on_first_cycle(self):
        svc = self._svc(running=True)
        assert svc._rejected_at is None
        with patch.object(ds_mod, "TARI_REQUIRED", True):
            await svc._apply_worker_rejection(False, True)
        svc.docker_control.stop.assert_awaited_once_with(PROXY, quiet=True)

    async def test_mining_guard_refreshes_the_snapshot(self):
        svc = self._svc()
        states = {PROXY: {"running": True}}
        with patch.object(ds_mod, "get_container_health", AsyncMock(return_value=states)):
            await svc._update_mining_guard({}, {})
        assert svc.container_snapshot is states

    @pytest.mark.parametrize(
        "rejected,guard_active,proxy_started",
        [(True, False, False), (False, True, False), (False, False, True)],
    )
    async def test_fail_closed_release_starts_proxy_only_when_not_held(
        self, rejected, guard_active, proxy_started, caplog
    ):
        caplog.set_level("INFO")
        svc = self._svc(rejected=rejected)
        svc.miner_released = True
        svc.fail_closed_held = True
        svc.mining_guard.active = {"x": 1} if guard_active else {}
        with (
            patch.object(ds_mod, "DASHBOARD_FAIL_CLOSED", True),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", PROXY]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=False)
        started = [c.args[0] for c in svc.docker_control.start.await_args_list]
        assert ("p2pool" in started) and (PROXY in started) is proxy_started
        assert svc.fail_closed_held is False
        assert ("mining can resume" in caplog.text) is proxy_started
        assert ("stays stopped until workers are readmitted" in caplog.text) is not proxy_started
