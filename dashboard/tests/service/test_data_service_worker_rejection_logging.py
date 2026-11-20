# ruff: noqa: F403, F405
from tests.service import test_data_service_worker_rejection as base
from tests.service._data_service_support import *  # noqa: F403

_Guard = base.TestMiningGuardRejection


class TestWorkerRejectionLogging:
    _svc = _Guard._svc
    _p2p = staticmethod(_Guard._p2p)
    _cycle = _Guard._cycle
    _clock = staticmethod(_Guard._clock)
    _hold_past_grace = _Guard._hold_past_grace

    @pytest.mark.parametrize(
        "monero_down,tari_down,needle",
        [
            (True, False, "Monero node unreachable past the debounce"),
            (False, True, "Tari node unreachable past the debounce"),
        ],
    )
    async def test_debounce_trigger_is_named(self, monero_down, tari_down, needle, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        await svc._apply_worker_rejection(monero_down, tari_down)
        assert needle in caplog.text

    async def test_stop_line_carries_guard_and_debounce_reasons(self, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        down = {"tor": {"running": True, "restarting": False, "health": "unhealthy"}}
        await self._hold_past_grace(svc, containers=down)
        svc.workers_rejected = False
        await svc._apply_worker_rejection(True, False)
        line = [m for m in caplog.messages if "Mining work is not valid" in m][-1]
        assert "Tor container is unhealthy; Monero node unreachable past the debounce" in line

    async def test_readmission_line_has_elapsed_seconds(self, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        with patch.object(ds_mod.time, "monotonic", side_effect=[100.0, 142.0]):
            await svc._apply_worker_rejection(True, False)
            await svc._apply_worker_rejection(False, False)
        assert svc.workers_rejected is False
        assert "to readmit workers, 42s after it was stopped" in caplog.text

    async def test_readmission_after_restart_says_the_stop_predates_the_process(self, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        svc.workers_rejected = True
        await svc._apply_worker_rejection(False, False)
        assert "after a stop that predates this dashboard process" in caplog.text

    async def test_blocked_readmission_logs_once_per_change(self, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = False
        for _ in range(3):
            await svc._apply_worker_rejection(False, False)
        svc.tari_health.healthy = False
        with patch.object(ds_mod, "TARI_REQUIRED", True):
            await svc._apply_worker_rejection(False, False)
        lines = [m for m in caplog.messages if "stays stopped" in m]
        assert len(lines) == 2
        assert "Monero node not yet confirmed healthy" in lines[0]
        assert "Tari node not yet confirmed healthy" in lines[1]

    async def test_blocked_readmission_names_guard_triggers(self, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        svc.workers_rejected = True
        isolated = {"p2p": {"uptime": 9, "out_peers": 0, "in_peers": 0}}
        await self._cycle(svc, p2pool=isolated)
        assert "guard triggers still holding or recovering: p2pool_peers" in caplog.text

    async def test_failed_stop_and_start_each_log_once_across_retries(self, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        svc.docker_control.stop.return_value = False
        for _ in range(3):
            await svc._apply_worker_rejection(True, False)
        assert caplog.text.count("Mining work is not valid") == 1
        svc.docker_control.stop.return_value = True
        await svc._apply_worker_rejection(True, False)
        svc.docker_control.start.return_value = False
        for _ in range(3):
            await svc._apply_worker_rejection(False, False)
        assert caplog.text.count("Readmitting workers failed") == 1

    async def test_stop_line_names_trigger_still_inside_its_grace(self, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        isolated = {"p2p": {"uptime": 9, "out_peers": 0, "in_peers": 0}}
        await self._cycle(svc, p2pool=isolated)
        await svc._apply_worker_rejection(True, False)
        assert "also holding inside its grace: p2pool_peers" in caplog.text

    async def test_persisted_stop_names_the_holding_triggers_once(self, caplog):
        caplog.set_level("INFO", logger="DataService")
        svc = self._svc()
        svc.workers_rejected = True
        for _ in range(3):
            await svc._apply_worker_rejection(True, False)
        lines = [m for m in caplog.messages if "already stopped when this dashboard started" in m]
        assert len(lines) == 1
        assert "persisted workers_rejected" in lines[0]
        assert "Monero node unreachable past the debounce" in lines[0]
        svc.docker_control.stop.assert_not_called()
