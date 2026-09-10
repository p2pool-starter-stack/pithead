# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestSyncFinished:
    def test_fires_once_when_gate_opens(self):
        svc = _svc()
        _ev(svc, miner_released=False)  # seed: still syncing
        assert _keys(_ev(svc, miner_released=True)) == [AlertService.EVT_SYNC_FINISHED]
        assert _ev(svc, miner_released=True) == []  # one-shot

    def test_no_alert_on_restart_after_sync(self):
        svc = _svc()
        # First observation is already-released (restart after sync) -> baseline, no alert.
        assert _ev(svc, miner_released=True) == []
