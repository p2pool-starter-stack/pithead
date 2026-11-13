import pytest

import mining_dashboard.web.views.paused_badge as paused_badge
from mining_dashboard.web.views.paused_badge import paused_badges


@pytest.fixture(autouse=True)
def _local_node(monkeypatch):
    monkeypatch.setattr(paused_badge, "monero_is_local", lambda: True)


def _rigs(*verdicts):
    return {"workers": [{"mining_verdict": v} for v in verdicts]}


def test_absent_while_serving(_metrics):
    data = {"pool": {"p2p": {"uptime": 50, "out_peers": 3, "in_peers": 1}}}
    assert paused_badges(data, _metrics()) == []


def test_node_out_of_sync_counts_rigs_on_backup(_metrics):
    data = {
        "monero_sync": {"health": {"level": "red"}},
        **_rigs("on_backup", "on_backup", "mining_here", "unknown"),
    }
    assert paused_badges(data, _metrics()) == [
        {"text": "Mining paused here: node out of sync, 2 rigs on backup pool", "variant": "bad"}
    ]


def test_remote_node_health_is_not_a_trigger(_metrics, monkeypatch):
    monkeypatch.setattr(paused_badge, "monero_is_local", lambda: False)
    assert paused_badges({"monero_sync": {"health": {"level": "red"}}}, _metrics()) == []


def test_stratum_closed_names_the_guard_trigger(_metrics):
    pause = {"reason": "P2Pool has no sidechain peers", "since": 1}
    data = {"stratum_closed": True, "mining_pause": pause}
    text = paused_badges(data, _metrics())[0]["text"]
    assert text == "Mining paused here: stratum closed (P2Pool has no sidechain peers)"


def test_rigs_clause_omitted_when_zero_and_singular_for_one(_metrics):
    data = {"stratum_closed": True, **_rigs("mining_here")}
    assert paused_badges(data, _metrics())[0]["text"] == "Mining paused here: stratum closed"
    data = {"stratum_closed": True, **_rigs("on_backup")}
    assert paused_badges(data, _metrics())[0]["text"].endswith(", 1 rig on backup pool")


def test_syncing_triggers(_metrics):
    out = paused_badges({}, _metrics(global_syncing=True))
    assert out[0]["text"] == "Mining paused here: node syncing"


def test_p2pool_isolated_only_when_running_and_peerless(_metrics):
    data = {"pool": {"p2p": {"uptime": 50, "out_peers": 0, "in_peers": 0}}}
    assert paused_badges(data, _metrics())[0]["text"] == "Mining paused here: P2Pool isolated"
    data = {"pool": {"p2p": {"uptime": 0, "out_peers": 0, "in_peers": 0}}}
    assert paused_badges(data, _metrics()) == []


def test_one_line_when_several_conditions_hold(_metrics):
    data = {"stratum_closed": True, "pool": {"p2p": {"uptime": 5}}}
    assert len(paused_badges(data, _metrics(global_syncing=True))) == 1


def test_rides_build_state_first_in_badges(_data, _state_mgr):
    from mining_dashboard.web.views import views

    data = _data()
    data["stratum_closed"] = True
    badges = views.build_state(data, _state_mgr(), "all")["badges"]
    assert badges[0]["text"] == "Mining paused here: stratum closed"
    assert sum(b["text"].startswith("Mining paused here") for b in badges) == 1
    assert not any(
        b["text"].startswith("Mining paused here")
        for b in views.build_state(_data(), _state_mgr(), "all")["badges"]
    )
