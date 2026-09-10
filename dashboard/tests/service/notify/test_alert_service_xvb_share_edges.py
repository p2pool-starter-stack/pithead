# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestXvbShareEdges:
    def test_no_share_then_restored(self):
        svc = _svc()
        assert _ev(svc, xvb_enabled=True, shares_in_window=3) == []  # seed: has a share
        assert _keys(_ev(svc, xvb_enabled=True, shares_in_window=0)) == [
            AlertService.EVT_XVB_NO_SHARE
        ]
        assert _ev(svc, xvb_enabled=True, shares_in_window=0) == []  # no repeat
        _, text = _ev(svc, xvb_enabled=True, shares_in_window=1)[0]  # restored
        assert "restored" in text

    def test_silent_while_xvb_disabled(self):
        svc = _svc()
        # XvB off → the share gate doesn't apply, even with zero shares.
        assert _ev(svc, xvb_enabled=False, shares_in_window=0) == []
        # Turning XvB on re-seeds silently (no stale replay), then alerts on a real loss.
        assert _ev(svc, xvb_enabled=True, shares_in_window=2) == []
        assert _keys(_ev(svc, xvb_enabled=True, shares_in_window=0)) == [
            AlertService.EVT_XVB_NO_SHARE
        ]
