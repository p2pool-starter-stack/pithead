import threading
from concurrent.futures import ThreadPoolExecutor

import pytest

from mining_dashboard import go_bridge, go_forecast

# ruff: noqa: S101

FIELDS = (
    "current_key",
    "forecast_key",
    "xvb_day",
    "expected_wins_day",
    "realization",
    "tempered_day",
    "xvb_calc",
)


class Request:
    def __init__(self, prepared):
        self.prepared = prepared
        self.query = {}

    def clone(self, **_kwargs):
        return self

    async def json(self):
        return self.prepared


def prepared_generation(name):
    return {
        "current_key": name + "-current",
        "forecast_key": name + "-forecast",
        "xvb_day": 1.0 if name == "old" else 2.0,
        "expected_wins_day": 3.0 if name == "old" else 4.0,
        "realization": [0.2, 6] if name == "old" else [0.8, 12],
        "tempered_day": 0.2 if name == "old" else 1.6,
        "xvb_calc": {"generation": name},
    }


@pytest.mark.asyncio
@pytest.mark.parametrize("marker", [None, False, 1, "true"])
async def test_invalid_native_forecast_marker_is_fatal(marker):
    prepared = {"snapshot": {"storage": {}, "settings": {}}, "forecast": marker}
    with pytest.raises(RuntimeError, match="invalid native XvB forecast marker"):
        await go_bridge._finish_state(Request(prepared))


@pytest.mark.asyncio
async def test_claimed_native_forecast_cannot_omit_prepared_result():
    prepared = {
        "snapshot": {"storage": {}, "settings": {}},
        "forecast": True,
        "sections": {},
    }
    with pytest.raises(KeyError, match="xvb_forecast"):
        await go_bridge._finish_state(Request(prepared))


@pytest.mark.parametrize(
    "prepared",
    [None, {}, dict.fromkeys(FIELDS[:-1]), {**dict.fromkeys(FIELDS), "extra": True}],
)
def test_forecast_builders_reject_malformed_prepared_result(prepared):
    with pytest.raises(RuntimeError, match="native XvB forecast unavailable"):
        go_forecast.builders(prepared)


def test_prepared_generations_remain_coherent_under_forced_interleaving():
    old = prepared_generation("old")
    new = prepared_generation("new")
    old_builders = go_forecast.builders(old)
    new_builders = go_forecast.builders(new)
    barrier = threading.Barrier(2)

    def read(builders, order):
        barrier.wait()
        return {name: builders[name]() for name in order}

    operations = tuple(
        name
        for name in (
            "xvb_current_tier_key",
            "xvb_forecast_tier_key",
            "xvb_current_tier_reward_day",
            "xvb_expected_wins_day",
            "xvb_realization",
            "xvb_tempered_day",
            "build_xvb_calc",
        )
    )
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(read, old_builders, operations)
        second = pool.submit(read, new_builders, tuple(reversed(operations)))
    expected_old = go_forecast.builders(old)
    expected_new = go_forecast.builders(new)
    assert first.result() == {name: expected_old[name]() for name in operations}
    assert second.result() == {name: expected_new[name]() for name in reversed(operations)}
