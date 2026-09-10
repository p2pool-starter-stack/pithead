# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestWorkerMembership:
    def test_joined_after_baseline(self, _on):
        svc = _svc()
        _ev(svc, workers=_on("rig-1"), workers_expected=True)  # prime
        assert _keys(_ev(svc, workers=_on("rig-1", "rig-2"), workers_expected=True)) == [
            AlertService.EVT_WORKER_JOINED
        ]

    def test_left_when_rig_drops_off_the_table(self, _on):
        svc = _svc()
        _ev(svc, workers=_on("rig-1", "rig-2"), workers_expected=True)  # prime
        assert _keys(_ev(svc, workers=_on("rig-1"), workers_expected=True)) == [
            AlertService.EVT_WORKER_LEFT
        ]
