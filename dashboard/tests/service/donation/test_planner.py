import pytest

from mining_dashboard.service.donation.planner import plan_cycle
from mining_dashboard.sim.project_slice_model import simulate


def test_accrual_trigger_and_exact_order():
    segments, debt = plan_cycle(120_000, 54_000, 1, 0.85)
    assert segments == [("xvb", 120_000), ("p2pool", 420_000), ("project", 60_000)]
    assert debt == 0
    assert plan_cycle(120_000, 0, 1, 0.85) == (
        [("xvb", 120_000), ("p2pool", 480_000)],
        6_000,
    )


def test_reserve_trims_below_trigger_and_carries_unspent_debt():
    assert plan_cycle(480_000, 60_000, 1, 0.85) == (
        [("xvb", 480_000), ("p2pool", 90_000), ("project", 30_000)],
        36_000,
    )


def test_sub_dwell_capacity_is_deferred():
    assert plan_cycle(500_000, 60_000, 1, 0.85) == (
        [("xvb", 500_000), ("p2pool", 100_000)],
        66_000,
    )


def test_full_cycle_and_reserve_exhaustion_preserve_xvb():
    assert plan_cycle(600_000, 10_000, 1, 0.85) == ([("xvb", 600_000)], 16_000)
    assert plan_cycle(540_000, 60_000, 1, 0.85) == (
        [("xvb", 540_000), ("p2pool", 60_000)],
        66_000,
    )


def test_debt_cap_and_no_room():
    assert plan_cycle(0, 1_800_000, 10, 0) == ([("p2pool", 600_000)], 1_800_000)


def test_p2pool_tail_is_retained_without_reducing_xvb_or_exceeding_cap():
    assert plan_cycle(540_000, 60_000, 1, 1) == (
        [("xvb", 540_000), ("p2pool", 30_000), ("project", 30_000)],
        36_000,
    )


@pytest.mark.parametrize("xvb_ms", [-1, 1, 14_999, 570_001, 599_999, 600_001])
def test_invalid_xvb_durations_have_clear_reason(xvb_ms):
    with pytest.raises(ValueError, match="xvb_ms"):
        plan_cycle(xvb_ms, 0, 1, 0.85)


@pytest.mark.parametrize("xvb_ms", [0, 15_000, 570_000, 600_000])
def test_valid_xvb_boundaries(xvb_ms):
    segments, _ = plan_cycle(xvb_ms, 0, 1, 0.85)
    assert dict(segments).get("xvb", 0) == xvb_ms


def test_overhead_is_included_in_routed_wall_time():
    expected = ([("p2pool", 540_000), ("project", 60_000)], 0)
    assert plan_cycle(0, 54_000, 1, 0.85, overhead_ms=0) == expected
    assert plan_cycle(0, 54_000, 1, 0.85, overhead_ms=5_000) == expected


def test_custom_cycle_trigger_and_dwell():
    assert plan_cycle(
        20_000,
        30_000,
        10,
        0.75,
        cycle_ms=120_000,
        min_slice_ms=40_000,
        min_dwell_ms=20_000,
    ) == ([("xvb", 20_000), ("p2pool", 58_000), ("project", 42_000)], 0)
    assert plan_cycle(0, 500_000, 10, 1, min_dwell_ms=100_000) == (
        [("p2pool", 100_000), ("project", 500_000)],
        60_000,
    )


@pytest.mark.parametrize(
    "kwargs, field",
    [
        ({"debt_ms": -1}, "debt_ms"),
        ({"debt_ms": float("inf")}, "debt_ms"),
        ({"percent": 0}, "percent"),
        ({"percent": 0.099}, "percent"),
        ({"percent": 11}, "percent"),
        ({"percent": float("nan")}, "percent"),
        ({"max_fraction": -0.1}, "max_fraction"),
        ({"max_fraction": 1.1}, "max_fraction"),
        ({"max_fraction": float("inf")}, "max_fraction"),
        ({"cycle_ms": 0}, "cycle_ms"),
        ({"cycle_ms": 20_000}, "cycle_ms"),
        ({"min_dwell_ms": 0}, "min_dwell_ms"),
        ({"min_slice_ms": 0}, "min_slice_ms"),
        ({"overhead_ms": -1}, "overhead_ms"),
        ({"overhead_ms": float("nan")}, "overhead_ms"),
        ({"xvb_ms": 15_000.5}, "xvb_ms"),
    ],
)
def test_invalid_parameters(kwargs, field):
    inputs = {"xvb_ms": 0, "debt_ms": 0, "percent": 1, "max_fraction": 0.85}
    inputs.update(kwargs)
    with pytest.raises(ValueError, match=field):
        plan_cycle(**inputs)


@pytest.mark.parametrize("percent, minutes", [(1, 14), (2, 28), (5, 72)])
def test_daily_donation_table(percent, minutes):
    result = simulate([120_000] * 144, percent, 0.85)
    assert result.project_ms / 60_000 == minutes
    assert result.project_share == pytest.approx(percent / 100, rel=0.05)


def test_simulator_schedule_switches_and_carried_debt():
    result = simulate([600_000, 0, 0], 10, 0.85)
    assert result.project_ms == 180_000
    assert result.project_share == 0.1
    assert result.switches_per_hour == 8
    assert result.debt_ms == 0


def test_empty_simulation():
    assert simulate([], 1, 0.85).project_share == 0
    assert simulate([], 1, 0.85).switches_per_hour == 0


def test_tenth_percent_over_a_week_stays_within_one_slice():
    cycles = 7 * 144
    result = simulate([120_000] * cycles, 0.1, 0.85)
    target_ms = cycles * 600_000 * 0.1 / 100
    assert 0 <= target_ms - result.project_ms < 60_000
    assert result.project_ms == 600_000
    assert result.debt_ms == pytest.approx(target_ms - result.project_ms)
