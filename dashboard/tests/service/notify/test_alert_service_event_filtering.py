# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestEventFiltering:
    def test_disabled_events_are_dropped(self, _down, _on):
        svc = _svc(notifier=_FakeNotifier(allow={AlertService.EVT_NODE_DOWN}))
        _ev(svc, workers=_on("rig-1"), workers_expected=True, now=0)
        _ev(svc, workers=_down("rig-1"), workers_expected=True, now=0)
        # worker_offline is computed but filtered out because it's not in the allow-set.
        assert _ev(svc, workers=_down("rig-1"), workers_expected=True, now=300) == []
