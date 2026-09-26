import pytest

from tari_health import Health, TariObservation, evaluate


def obs(**changes):
    values = dict(process_running=True, channel_ready=True, node_height=100,
                  network_height=100, peer_count=1)
    values.update(changes)
    return TariObservation(**values)


def test_current_case_is_unhealthy_despite_ready_channel():
    result = evaluate(obs(node_height=342575, network_height=348684,
                          peer_count=0, rejected_blocks=21542, bans=2500))
    assert result is Health.UNHEALTHY


def test_ready_and_synced_with_peer_is_healthy():
    assert evaluate(obs(node_height=348684, network_height=348684)) is Health.HEALTHY


@pytest.mark.parametrize("change", [
    {"process_running": False}, {"channel_ready": False},
    {"peer_count": 0}, {"rejected_blocks": 1}, {"bans": 1},
    {"node_height": 80, "network_height": 100},
])
def test_failure_signals_are_not_green(change):
    assert evaluate(obs(**change)) is Health.UNHEALTHY


@pytest.mark.parametrize("change", [
    {"node_height": None}, {"network_height": None},
    {"peer_count": None}, {"channel_ready": None},
])
def test_missing_evidence_fails_closed_as_unknown(change):
    assert evaluate(obs(**change)) is Health.UNKNOWN


def test_negative_lag_is_unknown():
    assert evaluate(obs(node_height=101, network_height=100)) is Health.UNKNOWN


def test_threshold_is_inclusive():
    assert evaluate(obs(node_height=88, network_height=100), max_lag=12) is Health.HEALTHY


def test_invalid_policy_is_rejected():
    with pytest.raises(ValueError):
        evaluate(obs(), max_lag=-1)

