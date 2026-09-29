# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


def _h(**kw):
    base = {"level": "green", "peers_visible": True, "peers_out": 8, "peers_in": 1, "height": 5}
    return {**base, **kw}


def _mh(svc, health):
    return svc.evaluate(
        monero_down=False,
        monero_health=health,
        tari_down=False,
        tari_required=True,
        miner_released=True,
        workers=[],
        workers_expected=False,
        now=0,
    )


class TestMoneroHealthEdges:
    """#2499: monero_peerless / monero_stalled edges, riding the node_down toggles."""

    def test_first_verdict_is_baseline_not_an_alert(self):
        svc = _svc()
        assert _mh(svc, _h(level="red", peerless=True, peers_out=0)) == []

    def test_peerless_edge_fires_once_names_the_numbers_and_recovers(self):
        svc = _svc()
        _mh(svc, _h())
        out = _mh(svc, _h(level="red", peerless=True, peers_out=0, peers_in=3))
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert "no outgoing peers (0 out, 3 in)" in out[0][1]
        assert "restart monerod" in out[0][1]
        assert _mh(svc, _h(level="red", peerless=True, peers_out=0)) == []  # no repeat
        assert _keys(_mh(svc, _h())) == [AlertService.EVT_NODE_RECOVERED]

    def test_stalled_edge_fires_once_names_height_and_age(self):
        svc = _svc()
        _mh(svc, _h())
        out = _mh(svc, _h(level="red", stalled=True, height=77, advance_age_sec=1900))
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert "height 77 has not moved for 31 min" in out[0][1]
        assert _mh(svc, _h(level="red", stalled=True, height=77, advance_age_sec=2000)) == []
        assert _keys(_mh(svc, _h())) == [AlertService.EVT_NODE_RECOVERED]

    def test_two_conditions_are_two_independent_edges(self):
        svc = _svc()
        _mh(svc, _h())
        both = _h(level="red", peerless=True, stalled=True, peers_out=0, advance_age_sec=1800)
        assert _keys(_mh(svc, both)) == [AlertService.EVT_NODE_DOWN] * 2
        assert _keys(_mh(svc, _h(level="red", stalled=True, advance_age_sec=1800))) == [
            AlertService.EVT_NODE_RECOVERED
        ]

    def test_no_visibility_keeps_state_and_never_fakes_a_recovery(self):
        svc = _svc()
        _mh(svc, _h())
        _mh(svc, _h(level="red", peerless=True, peers_out=0))
        assert _mh(svc, {"level": "unknown", "peers_visible": False}) == []
        # A node that stopped answering is node-down's alert, not "peers are back" (no fake recovery).
        assert _mh(svc, {"level": "unknown", "peers_visible": False, "reachable": False}) == []
        assert _mh(svc, None) == []
        assert _mh(svc, _h(level="red", peerless=True, peers_out=0)) == []  # still no repeat

    def test_counts_an_incident(self):
        svc = _svc()
        _mh(svc, _h())
        _mh(svc, _h(level="red", peerless=True, peers_out=0))
        assert svc.drain_incidents() == {AlertService.EVT_NODE_DOWN: 1}
