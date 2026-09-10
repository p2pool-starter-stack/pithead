# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestDiskEdges:
    def test_warn_then_critical_then_recover(self):
        svc = _svc()
        assert _ev(svc, disk_percent=40) == []  # seed silently
        assert _keys(_ev(svc, disk_percent=88)) == [AlertService.EVT_DISK_SPACE]  # -> warn
        assert _ev(svc, disk_percent=90) == []  # still warn, no repeat
        assert _keys(_ev(svc, disk_percent=97)) == [AlertService.EVT_DISK_SPACE]  # -> critical
        _, text = _ev(svc, disk_percent=40)[0]  # -> recovered
        assert "healthy" in text

    def test_seed_high_does_not_replay(self):
        svc = _svc()
        # Already-full at startup must not fire (restart semantics).
        assert _ev(svc, disk_percent=99) == []
