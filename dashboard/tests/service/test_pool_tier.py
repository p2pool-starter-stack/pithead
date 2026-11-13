from copy import deepcopy

import pytest

from mining_dashboard.service.pool_tier import suggest_pool_tier


@pytest.mark.parametrize(
    "rate,tier", [(0, "nano"), (9999, "nano"), (10000, "mini"), (99999, "mini"), (100000, "main")]
)
def test_provisional_boundaries(rate, tier):
    history = [{"timestamp": t, "v": rate} for t in (0, 43200, 86400)]
    before = deepcopy(history)
    current = "main" if tier != "main" else "mini"
    assert suggest_pool_tier(history, current, now=86400) == {
        "tier": tier,
        "hashrate_24h": rate,
        "provisional": True,
    }
    assert suggest_pool_tier(history, tier, now=86400) is None
    assert history == before


@pytest.mark.parametrize(
    "history",
    [
        [],
        [{"timestamp": 1, "v": 100}],
        [{"timestamp": 0, "v": 100}, {"timestamp": 86000, "v": 100}],
    ],
)
def test_incomplete_or_stale_measurements_do_not_suggest(history):
    assert suggest_pool_tier(history, "main", now=86400) is None


def test_only_trailing_measurements_count_and_unknown_tier_stays_unchanged():
    history = [
        {"timestamp": -1, "v": 1000000},
        {"timestamp": 0, "v": 5000},
        {"timestamp": 86400, "v": 15000},
    ]
    assert suggest_pool_tier(history, "nano", now=86400)["tier"] == "mini"
    assert suggest_pool_tier(history, "unknown", now=86400) is None
    assert suggest_pool_tier([{"timestamp": 0, "v": float("nan")}], "main", now=86400) is None
