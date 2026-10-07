"""Initial P2Pool sidechain sync must not look like live pool statistics."""

from unittest.mock import patch

import pytest

from mining_dashboard.collector import pools
from mining_dashboard.config.config import POOL_STATS_PATH

PLACEHOLDER = {
    "hashRate": 10000,
    "miners": 870,
    "totalHashes": 400000,
    "totalBlocksFound": 50,
    "pplnsWeight": 500000,
    "pplnsWindowSize": 2160,
    "sidechainDifficulty": 100000,
    "sidechainHeight": 3,
}


def collect(values):
    with patch.object(
        pools,
        "_read_json",
        side_effect=lambda path: {"pool_statistics": values} if path == POOL_STATS_PATH else {},
    ):
        return pools.get_p2pool_stats()["pool"]


def test_owner_placeholder_is_syncing_even_before_peers_are_known():
    assert collect(PLACEHOLDER)["syncing"] is True


@pytest.mark.parametrize(
    "height,difficulty,syncing",
    [
        (0, 100000, True),
        (2159, 100000, True),
        (2160, 100000, False),
        (14973049, 100000, False),
        (3, 100001, False),
        (14973049, 25000000, False),
    ],
)
def test_sync_requires_both_minimum_difficulty_and_short_chain(height, difficulty, syncing):
    result = collect({**PLACEHOLDER, "sidechainHeight": height, "sidechainDifficulty": difficulty})
    assert result["syncing"] is syncing
    assert result["sidechain_height"] == height
    assert result["difficulty"] == difficulty


@pytest.mark.parametrize(
    "field,value",
    [
        ("sidechainHeight", None),
        ("sidechainHeight", -1),
        ("sidechainHeight", "3"),
        ("sidechainDifficulty", None),
        ("sidechainDifficulty", 0),
        ("pplnsWindowSize", 0),
        ("pplnsWindowSize", None),
    ],
)
def test_invalid_or_missing_evidence_does_not_claim_sync(field, value):
    assert collect({**PLACEHOLDER, field: value})["syncing"] is False
    values = {**PLACEHOLDER}
    del values[field]
    assert collect(values)["syncing"] is False


def test_sync_verdict_recovers_on_next_poll():
    assert collect(PLACEHOLDER)["syncing"] is True
    assert collect({**PLACEHOLDER, "sidechainHeight": 14973049})["syncing"] is False
