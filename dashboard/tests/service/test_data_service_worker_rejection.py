# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestWorkerRejection:
    """The rejection decision table (#31, narrowed by #897): monerod-down is the only thing
    that ever rejects workers. Tari — required or not — never does; a Tari-only outage stays
    admitted and surfaces through the Tari panel/alerts instead."""

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        return svc

    async def test_stop_when_monero_down(self):
        # monerod is required, so its outage always rejects.
        svc = self._svc()
        with patch.object(ds_mod, "REJECT_WORKERS_CONTAINER", "xmrig-proxy"):
            await svc._apply_worker_rejection(monero_down=True)
        svc.docker_control.stop.assert_awaited_once_with("xmrig-proxy")
        assert svc.workers_rejected is True

    async def test_stop_failure_keeps_flag_false_for_retry(self):
        svc = self._svc()
        svc.docker_control.stop = AsyncMock(return_value=False)
        await svc._apply_worker_rejection(monero_down=True)
        assert svc.workers_rejected is False  # so the next cycle retries

    async def test_no_double_stop_when_already_rejected(self):
        svc = self._svc()
        svc.workers_rejected = True
        await svc._apply_worker_rejection(monero_down=True)
        svc.docker_control.stop.assert_not_called()
        svc.docker_control.start.assert_not_called()

    async def test_readmit_when_monero_healthy(self):
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = True
        await svc._apply_worker_rejection(monero_down=False)
        svc.docker_control.start.assert_awaited_once()
        assert svc.workers_rejected is False

    async def test_no_readmit_until_monero_healthy(self):
        # monerod is mandatory: never readmit while it's unconfirmed.
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = False
        await svc._apply_worker_rejection(monero_down=False)
        svc.docker_control.start.assert_not_called()
        assert svc.workers_rejected is True

    async def test_readmit_ignores_tari_state_entirely(self):
        # Tari can no longer be the reason workers were rejected, so a required Tari that's
        # unhealthy — or has never been reachable this run — must not hold a healthy monerod's
        # workers off. This is what's left of the readmission ever-up guard after #897: the
        # guard itself (in NodeHealthMonitor) still protects monerod-down detection, but Tari's
        # copy of it is now moot for readmission because Tari can't gate rejection either.
        svc = self._svc()
        svc.workers_rejected = True
        svc.monero_health.healthy = True
        svc.tari_health.healthy = False
        assert svc.tari_health.ever_up is False
        with patch.object(ds_mod, "TARI_REQUIRED", True):
            await svc._apply_worker_rejection(monero_down=False)
        svc.docker_control.start.assert_awaited_once()
        assert svc.workers_rejected is False
