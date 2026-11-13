from types import SimpleNamespace

from mining_dashboard.service.data_setup import DataSetupMixin
from mining_dashboard.service.health.monero_health import MoneroChainHealth
from mining_dashboard.web.views.views import build_state


def test_build_state_carries_the_node_alert_from_the_health_verdicts(_data, _state_mgr):
    assert build_state(_data(), _state_mgr(), "all")["node_alert"] is None
    data = _data()
    data["monero_sync"] = {"health": {"level": "red", "reasons": ["0 outgoing peers"]}}
    data["tor_heal"] = {"enabled": True, "attempts": 0}
    alert = build_state(data, _state_mgr(), "all")["node_alert"]
    assert alert["title"] == "Monero node offline"
    assert alert["reasons"] == ["0 outgoing peers"]
    assert alert["heal"] == ["Tor auto-heal: no action taken yet."]


def test_each_poll_publishes_the_tor_heal_state_beside_the_monero_verdict():
    healer = SimpleNamespace(enabled=False)
    node = SimpleNamespace(monero_chain=MoneroChainHealth(), tor_healer=healer, latest_data={})
    DataSetupMixin._observe_monero(node, {"reachable": False})
    assert node.latest_data["tor_heal"] == {"enabled": False}


def test_build_state_reports_a_tor_outage_and_the_spent_attempt_cap(_data, _state_mgr):
    data = _data()
    data["tor_heal"] = {
        "enabled": True,
        "broken_sec": 3600,
        "attempts": 3,
        "last_action": "Tor restart",
        "last_action_age_sec": 300,
    }
    alert = build_state(data, _state_mgr(), "all")["node_alert"]
    assert alert["reasons"] == ["Tor clearnet egress has failed for 60 min"]
    assert alert["heal"][0] == "Tor auto-heal last action: Tor restart, 5 min ago (attempt 3 of 3)."
    assert alert["heal"][1].startswith("Tor auto-heal stopped after 3 attempts")
