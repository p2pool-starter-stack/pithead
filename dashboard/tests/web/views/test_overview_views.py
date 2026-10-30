from types import SimpleNamespace

import pytest

from mining_dashboard.config import config
from mining_dashboard.web.views.overview_views import build_mining_activity, build_overview


def build(data, payouts=None):
    return build_overview(
        data,
        SimpleNamespace(p2pool_24h=100, xvb_routed_24h=20),
        payouts,
        [{"timestamp": 1}] if data.get("timestamp") else [],
    )


def test_p2pool_readings_are_raw_and_preserve_missing_values(monkeypatch):
    monkeypatch.setattr(config, "TARI_MODE", "off")
    monkeypatch.setattr(config, "ENABLE_XVB", False)
    result = build(
        {
            "timestamp": 100,
            "stratum": {"shares_found": 3, "shares_failed": 2, "current_effort": 42.5},
        }
    )
    assert result["shares_found"] == 3
    assert result["shares_failed"] == 2
    assert result["effort"] == 42.5
    assert result["hashrate_24h"] == "120.00 H/s"
    assert result["tari_enabled"] is False
    assert result["xvb_enabled"] is False
    assert build({})["shares_failed"] is None
    assert build({})["effort"] is None
    assert build({})["hashrate_24h"] is None


@pytest.mark.parametrize("bad", [-1, True, "2", float("nan"), float("inf"), None])
def test_malformed_readings_do_not_become_healthy_zeroes(bad):
    result = build({"stratum": {"shares_failed": bad, "current_effort": bad}})
    assert result["shares_failed"] is None
    assert result["effort"] is None


def test_latest_confirmed_payout_is_independent_of_chart_range_and_has_no_wallet():
    result = build(
        {},
        [
            {"ts": 1, "amount_atomic": 10},
            {"ts": 3, "amount_atomic": 30, "wallet": "not-for-display"},
            {"ts": 2, "amount_atomic": 20},
        ],
    )
    assert result["last_payout"] == {"ts": 3, "amount": 30}
    assert build({})["last_payout"] is None


def test_resource_availability_and_enabled_modes(monkeypatch):
    monkeypatch.setattr(config, "TARI_MODE", "remote")
    monkeypatch.setattr(config, "ENABLE_XVB", True)
    result = build({"system": {"hugepages": ["Enabled", "ok", "4/4"]}})
    assert result["system_available"] is True
    assert result["hugepages_available"] is True
    assert result["tari_enabled"] is True
    assert result["xvb_enabled"] is True
    assert build({})["system_available"] is False


def test_missing_live_rate_and_incomplete_payout_stay_unavailable():
    assert build({"timestamp": 1})["hashrate_now"] is None
    assert build({"timestamp": 1, "total_live_h15": 0})["hashrate_now"] == "0.00 H/s"
    assert build({}, [{"ts": 3}])["last_payout"] is None
    assert build({}, [{"ts": 3, "amount_atomic": None}])["last_payout"] is None


def test_activity_is_range_independent_bounded_and_drops_raw_details():
    shares = [{"ts": 1, "wallet": "secret"}]
    events = [{"ts": 2, "detail": "secret-token"}]
    result = build_mining_activity(shares, events, [], [{"ts": 3}], [])
    assert [entry["ts"] for entry in result["entries"]] == [3, 2, 1]
    assert "secret" not in str(result)
    assert result["truncated"] is False
    result = build_mining_activity([{"ts": i + 1} for i in range(1002)], [], [], [], [])
    assert len(result["entries"]) == 1000
    assert result["entries"][0]["ts"] == 1002
    assert result["truncated"] is True


def test_state_exposes_raw_readings_and_range_independent_activity(_data, _state_mgr):
    from mining_dashboard.web.views.views import build_state

    data = _data(
        timestamp=100,
        stratum={"shares_found": 3, "shares_failed": 2, "current_effort": 42},
        shares=[{"ts": 10, "difficulty": 1}],
    )
    manager = _state_mgr()
    manager.get_events.return_value = [
        {"ts": 20, "type": "hashrate_loss", "detail": "private detail"}
    ]
    result = build_state(data, manager, "1h")
    assert result["overview"]["shares_failed"] == 2
    assert result["overview"]["effort"] == 42
    assert [entry["ts"] for entry in result["overview_activity"]["entries"]] == [20, 10]
    assert "private detail" not in str(result["overview_activity"])
