import copy
import os
from types import SimpleNamespace

import dashboard_forecast_plugin as adapter
import pytest

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

NOW = 1_760_000_000
TIERS = {
    "donor_mega": 1_000_000.0,
    "donor_whale": 100_000.0,
    "donor_vip": 10_000.0,
    "donor": 1_000.0,
    "off": 0.0,
}
ROUND_STATE = {
    "stats": {
        "types": {
            "donor": {"rounds": 7, "players_avg": 70.0},
            "donor_vip": {"rounds": 28, "players_avg": 28.0},
            "donor_whale": {"rounds": 56, "players_avg": 8.0},
            "donor_mega": {"rounds": 63, "players_avg": 1.0},
        },
        "span_days": 7.0,
    },
    "last_update": NOW,
}
ESTIMATE_STATE = {
    "estimates": {
        "donor": 0.06,
        "donor_vip": 0.81,
        "donor_whale": 6.17,
        "donor_mega": 56.9,
    },
    "last_update": NOW,
}


class State:
    def __init__(self, tiers=TIERS, rounds=ROUND_STATE, estimates=ESTIMATE_STATE):
        self.tiers = tiers
        self.rounds = rounds
        self.estimates = estimates

    def get_tiers(self):
        return self.tiers

    def get_xvb_round_stats(self):
        return self.rounds

    def get_xvb_reward_estimates(self):
        return self.estimates


def metrics(**values):
    fields = {
        "xvb_enabled": True,
        "xvb_1h": 100_000.0,
        "xvb_24h": 100_000.0,
        "target_threshold": 10_000.0,
        "current_tier": "Whale (100.00 kH/s+)",
        "target_tier": "Vip (10.00 kH/s+)",
        "target_sustainable": True,
        "pool_type": "Main",
        "p2pool_30d": 8_000.0,
    }
    return SimpleNamespace(**{**fields, **values})


def paired(operation, *args, **kwargs):
    expected = adapter.python_call(operation, *args, **kwargs)
    actual = adapter.NATIVES[operation](*args, **kwargs)
    return expected, actual


@pytest.mark.parametrize(
    ("one_hour", "day", "target", "current", "forecast"),
    [
        (100_000.0, 100_000.0, 10_000.0, "donor_whale", "donor_whale"),
        (100_000.0, 999.0, 10_000.0, None, "donor_vip"),
        (0.0, 0.0, 0.0, None, None),
        (0.0, 0.0, 123.0, None, None),
    ],
)
def test_tier_selection_boundaries_match(one_hour, day, target, current, forecast):
    value = metrics(xvb_1h=one_hour, xvb_24h=day, target_threshold=target)
    assert paired("xvb_current_tier_key", value, TIERS) == (current, current)
    assert paired("xvb_forecast_tier_key", value, TIERS) == (forecast, forecast)


def test_equal_thresholds_keep_first_insertion_and_inputs_immutable():
    tiers = {"first": 1_000.0, "second": 1_000.0, "off": 0.0}
    value = metrics(xvb_1h=1_000.0, xvb_24h=1_000.0)
    before = copy.deepcopy(tiers)
    assert paired("xvb_current_tier_key", value, tiers) == ("first", "first")
    assert tiers == before


@pytest.mark.parametrize(
    ("enabled", "last_update", "reward"),
    [
        (True, NOW, 6.17 / 365),
        (False, NOW, None),
        (True, 1, None),
    ],
)
def test_current_reward_disabled_and_staleness_match(enabled, last_update, reward):
    state = State(estimates={**ESTIMATE_STATE, "last_update": last_update})
    expected, actual = paired(
        "xvb_current_tier_reward_day", metrics(xvb_enabled=enabled), state, now=NOW
    )
    if reward is None:
        assert expected is actual is None
    else:
        assert actual == pytest.approx(expected)
        assert actual == pytest.approx(reward)


def test_current_reward_rejects_missing_and_nonpositive_estimates():
    for estimates in ({}, {"donor_whale": 0}, {"donor_whale": -1}):
        state = State(estimates={"estimates": estimates, "last_update": NOW})
        assert paired("xvb_current_tier_reward_day", metrics(), state, now=NOW) == (None, None)


def test_expected_wins_sum_and_stale_boundaries_match():
    expected, actual = paired("xvb_expected_wins_day", ROUND_STATE, "donor_whale", TIERS, now=NOW)
    assert actual == pytest.approx(expected)
    assert actual == pytest.approx((56 / 7) / 8 + (28 / 7) / 28 + (7 / 7) / 70)
    stale = {**ROUND_STATE, "last_update": 1}
    assert paired("xvb_expected_wins_day", stale, "donor_whale", TIERS, now=NOW) == (
        None,
        None,
    )
    assert paired("xvb_expected_wins_day", ROUND_STATE, None, TIERS, now=NOW) == (None, None)


@pytest.mark.parametrize("operation", ["xvb_expected_wins_day", "build_xvb_calc"])
def test_wide_round_span_division_matches_python_exactly(operation):
    tiers = {"donor": 1_000.0}
    rounds = (1 << 53) + 3
    span = (1 << 53) + 1
    round_state = {
        "stats": {
            "types": {"donor": {"rounds": rounds, "players_avg": 1}},
            "span_days": span,
        },
        "last_update": NOW,
    }
    if operation == "xvb_expected_wins_day":
        expected, actual = paired(operation, round_state, "donor", tiers, now=NOW)
    else:
        expected_calc, actual_calc = paired(
            operation, metrics(), State(tiers=tiers, rounds=round_state), now=NOW
        )
        expected = expected_calc["tiers"][0]["win_odds_day"]
        actual = actual_calc["tiers"][0]["win_odds_day"]
    assert expected == 1.0000000000000002
    assert actual == expected


def wins(count=6):
    return [{"ts": NOW - 86_400 - index * 3_600} for index in range(count)]


def payouts(rows, amount):
    return [{"ts": row["ts"] + 1_800, "amount_atomic": amount} for row in rows]


def test_realization_minimum_overlap_and_baseline_match():
    rows = wins()
    assert paired(
        "xvb_realization", payouts(rows, 3_200_000_000), rows[:4], 0.016, 1.0, now=NOW
    ) == (None, None)
    overlap = [{"ts": rows[0]["ts"] + 900, "amount_atomic": 3_200_000_000}]
    expected, actual = paired("xvb_realization", overlap, rows, 0.016, 1.0, now=NOW)
    assert actual[1] == expected[1] == 6
    assert actual[0] == pytest.approx(expected[0])
    expected, actual = paired(
        "xvb_realization",
        payouts(rows, 4_800_000_000),
        rows,
        0.016,
        1.0,
        now=NOW,
        p2pool_day=0.0064,
    )
    assert actual[0] == pytest.approx(expected[0])
    assert actual == pytest.approx((0.2, 6))


def test_realization_clamps_and_missing_inputs_match():
    rows = wins()
    expected, actual = paired(
        "xvb_realization", payouts(rows, 32_000_000_000), rows, 0.016, 1.0, now=NOW
    )
    assert actual == expected == (1.0, 6)
    for values in ((None, rows, 0.016, 1.0), ([], rows, 0.016, 1.0), ([], [], None, 0.0)):
        assert paired("xvb_realization", *values, now=NOW) == (None, None)


def test_tempered_measured_prior_and_empty_match():
    for day, realization in ((0.016, (0.19, 15)), (0.016, None), (None, None), (0.0, None)):
        expected, actual = paired("xvb_tempered_day", day, realization)
        if expected is None:
            assert actual is None
        else:
            assert actual == pytest.approx(expected)


def test_calc_disabled_fallback_stale_enabled_and_labels_match():
    stale = {**ESTIMATE_STATE, "last_update": 1}
    disabled = metrics(
        xvb_enabled=False, current_tier="Disabled", target_tier="Disabled", pool_type="Mini"
    )
    for value, state in ((metrics(), State()), (disabled, State(estimates=stale))):
        expected, actual = paired("build_xvb_calc", value, state, now=NOW)
        assert actual == expected
        assert [row["threshold"] for row in actual["tiers"]] == [
            1_000.0,
            10_000.0,
            100_000.0,
            1_000_000.0,
        ]
    assert actual["estimates_source"] == "published"
    assert actual["mode_note"] is not None
    enabled = adapter.NATIVES["build_xvb_calc"](metrics(), State(estimates=stale), now=NOW)
    assert enabled["estimates_source"] == "none"


def test_calc_measured_realization_and_input_immutability_match():
    state = State()
    before = copy.deepcopy((TIERS, ROUND_STATE, ESTIMATE_STATE))
    expected, actual = paired("build_xvb_calc", metrics(), state, (0.19, 15), now=NOW)
    assert actual == expected
    assert actual["realization_pct"] == 19
    assert all(row["assumed_reward_year_range"] is None for row in actual["tiers"])
    assert (TIERS, ROUND_STATE, ESTIMATE_STATE) == before


def test_aggregate_matches_one_frozen_python_generation_and_is_immutable():
    value = metrics()
    rows = wins()
    pays = payouts(rows, 4_800_000_000)
    inputs = copy.deepcopy((TIERS, ROUND_STATE, ESTIMATE_STATE, pays, rows))
    current = adapter.python_call("xvb_current_tier_key", value, TIERS)
    forecast = adapter.python_call("xvb_forecast_tier_key", value, TIERS)
    face = adapter.python_call("xvb_current_tier_reward_day", value, State(), now=NOW)
    expected_wins = adapter.python_call(
        "xvb_expected_wins_day", ROUND_STATE, forecast, TIERS, now=NOW
    )
    realization = adapter.python_call(
        "xvb_realization",
        pays,
        rows,
        face,
        expected_wins,
        now=NOW,
        p2pool_day=0.0064,
    )
    expected = {
        "current_key": current,
        "forecast_key": forecast,
        "xvb_day": face,
        "expected_wins_day": expected_wins,
        "realization": realization,
        "tempered_day": adapter.python_call("xvb_tempered_day", face, realization),
        "xvb_calc": adapter.python_call("build_xvb_calc", value, State(), realization, now=NOW),
    }
    actual = adapter.NATIVES["xvb_state"](
        value, TIERS, ROUND_STATE, ESTIMATE_STATE, pays, rows, 0.0064 / value.p2pool_30d, NOW
    )
    assert actual == expected
    assert (TIERS, ROUND_STATE, ESTIMATE_STATE, pays, rows) == inputs


def test_disabled_aggregate_gates_live_values_but_keeps_decision_table():
    value = metrics(xvb_enabled=False, xvb_1h=0.0, xvb_24h=0.0)
    actual = adapter.NATIVES["xvb_state"](
        value, TIERS, ROUND_STATE, ESTIMATE_STATE, [], [], 0.0, NOW
    )
    assert actual["xvb_day"] is None
    assert actual["expected_wins_day"] is None
    assert actual["realization"] is None
    assert actual["tempered_day"] is None
    assert actual["xvb_calc"]["tiers"]


@pytest.mark.asyncio
async def test_http_state_owns_forecast_bodies(aiohttp_client, monkeypatch):
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server
    from mining_dashboard.web.views import views, xvb_calculator, xvb_views

    for module in (views, xvb_calculator, xvb_views):
        for name, function in adapter.REFERENCE_BODIES.items():
            if hasattr(module, name):
                monkeypatch.setattr(module, name, function)
    state = StateManager(db_path=":memory:")
    data = {
        "shares": [],
        "workers": [],
        "system": {},
        "global_sync": False,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 5, "target": 5},
    }
    try:
        client = await aiohttp_client(server.create_app(state, data))
        response = await client.get("/api/state")
        assert response.status == 200
        body = await response.json()
        assert set(body["xvb_calc"]) >= {"enabled", "tiers", "max_fraction"}
        assert not adapter.FALLBACKS
    finally:
        state.close()
