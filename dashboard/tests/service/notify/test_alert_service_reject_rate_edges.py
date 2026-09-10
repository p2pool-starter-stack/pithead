# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestRejectRateEdges:
    """#116: trailing-1h reject rate (from the persisted share deltas) crossing REJECT_ALERT_PCT."""

    def test_fires_once_then_recovers(self):
        svc = _svc()
        assert _ev(svc, reject_rate_1h=1.0) == []  # seed silently
        assert _keys(_ev(svc, reject_rate_1h=8.0)) == [AlertService.EVT_HIGH_REJECT_RATE]
        assert _ev(svc, reject_rate_1h=9.5) == []  # still high, no repeat
        _, text = _ev(svc, reject_rate_1h=0.5)[0]  # -> recovered
        assert "back to normal" in text

    def test_seed_high_does_not_replay(self):
        # Already-high at startup must not fire (restart semantics, like the other edges).
        svc = _svc()
        assert _ev(svc, reject_rate_1h=50.0) == []

    def test_none_is_no_verdict_and_resets_baseline(self):
        # No shares in the window (proxy idle/held) -> quiet, and resumed mining seeds fresh
        # rather than firing a recovery for a state that never alerted.
        svc = _svc()
        assert _ev(svc, reject_rate_1h=9.0) == []  # seed high
        assert _ev(svc, reject_rate_1h=None) == []  # proxy went idle
        assert _ev(svc, reject_rate_1h=0.5) == []  # re-seed, no stale "recovered"
        assert _keys(_ev(svc, reject_rate_1h=6.0)) == [AlertService.EVT_HIGH_REJECT_RATE]

    def test_threshold_boundary(self):
        svc = _svc()
        assert _ev(svc, reject_rate_1h=0.0) == []  # seed ok
        assert _ev(svc, reject_rate_1h=4.99) == []  # below the 5% threshold
        assert _keys(_ev(svc, reject_rate_1h=5.0)) == [AlertService.EVT_HIGH_REJECT_RATE]
