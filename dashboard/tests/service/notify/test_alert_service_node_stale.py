# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestNodeStale:
    """The #972 peer-loss strand: monerod reachable but out of sync. Rides the node_down /
    node_recovered toggles (same conversation), so it needs no new config surface."""

    def test_first_cycle_seeds_baseline_silently(self):
        svc = _svc()
        # Already-stale at dashboard startup must not replay as a fresh alert.
        assert _ev(svc, monero_stale=True) == []

    def test_stale_then_back_in_sync(self):
        svc = _svc()
        _ev(svc, monero_stale=False)  # seed
        assert _keys(_ev(svc, monero_stale=True)) == [AlertService.EVT_NODE_DOWN]
        assert _ev(svc, monero_stale=True) == []  # no repeat while still stale
        assert _keys(_ev(svc, monero_stale=False)) == [AlertService.EVT_NODE_RECOVERED]

    def test_stale_text_names_the_fix_and_counts_an_incident(self):
        svc = _svc()
        _ev(svc, monero_stale=False)
        _, text = _ev(svc, monero_stale=True)[0]
        assert "OUT OF SYNC" in text and "restart monerod" in text
        assert svc.drain_incidents() == {AlertService.EVT_NODE_DOWN: 1}

    def test_independent_of_node_down_edge(self):
        # Down and stale are different failure modes: a down edge must not clear or mask the
        # stale baseline, and both can alert in the same cycle.
        svc = _svc()
        _ev(svc, monero_down=False, monero_stale=False)  # seed both
        keys = _keys(_ev(svc, monero_down=True, monero_stale=True))
        assert keys.count(AlertService.EVT_NODE_DOWN) == 2
