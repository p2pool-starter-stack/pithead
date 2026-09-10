# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestNodeEdges:
    def test_first_cycle_seeds_baseline_silently(self):
        svc = _svc()
        # Already-down at startup must not replay as a fresh alert (restart semantics).
        assert _ev(svc, monero_down=True) == []

    def test_down_then_recovered(self):
        svc = _svc()
        _ev(svc, monero_down=False)  # seed
        assert _keys(_ev(svc, monero_down=True)) == [AlertService.EVT_NODE_DOWN]
        assert _ev(svc, monero_down=True) == []  # no repeat while still down
        assert _keys(_ev(svc, monero_down=False)) == [AlertService.EVT_NODE_RECOVERED]

    def test_node_text_names_the_chain(self):
        svc = _svc()
        _ev(svc, monero_down=False)
        _, text = _ev(svc, monero_down=True)[0]
        assert "Monero" in text
