# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestWorkerEdges:
    def test_offline_then_recovered(self, _down, _on):
        # Offline is driven by the DOWN status the dashboard shows, not by the rig vanishing.
        svc = _svc()
        assert _ev(svc, workers=_on("rig-1"), workers_expected=True, now=0) == []
        assert _ev(svc, workers=_down("rig-1"), workers_expected=True, now=0) == []
        assert _keys(_ev(svc, workers=_down("rig-1"), workers_expected=True, now=300)) == [
            AlertService.EVT_WORKER_OFFLINE
        ]
        _ev(svc, workers=_on("rig-1"), workers_expected=True, now=300)
        assert _keys(_ev(svc, workers=_on("rig-1"), workers_expected=True, now=420)) == [
            AlertService.EVT_WORKER_RECOVERED
        ]

    def test_not_expected_resets_and_silences(self, _down, _on):
        svc = _svc()
        _ev(svc, workers=_on("rig-1"), workers_expected=True, now=0)
        _ev(svc, workers=_down("rig-1"), workers_expected=True, now=0)
        _ev(svc, workers=_down("rig-1"), workers_expected=True, now=300)  # rig-1 now offline
        # Proxy intentionally stopped (sync hold / failover): reset, no alert.
        assert _ev(svc, workers=[], workers_expected=False, now=330) == []
        # Re-admission re-baselines silently — no spurious "recovered".
        assert _ev(svc, workers=_on("rig-1"), workers_expected=True, now=360) == []
