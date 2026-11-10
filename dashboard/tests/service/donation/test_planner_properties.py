from dataclasses import replace

import pytest
from hypothesis import example, given, settings
from hypothesis import strategies as st

from mining_dashboard.service.donation.planner import plan_cycle
from mining_dashboard.sim.project_slice_model import simulate

_xvb = st.one_of(st.just(0), st.integers(15_000, 570_000), st.just(600_000))


@settings(max_examples=200, deadline=None)
@given(
    xvb_ms=_xvb,
    debt_ms=st.integers(0, 3_600_000),
    percent=st.floats(0.1, 10, allow_nan=False, allow_infinity=False),
    max_fraction=st.floats(0, 0.85, allow_nan=False, allow_infinity=False),
)
def test_cycle_invariants(xvb_ms, debt_ms, percent, max_fraction):
    inputs = (xvb_ms, debt_ms, percent, max_fraction)
    segments, debt = plan_cycle(*inputs)
    assert plan_cycle(*inputs) == (segments, debt)
    durations = dict(segments)
    assert sum(durations.values()) == 600_000
    assert all(duration >= 15_000 for duration in durations.values())
    assert durations.get("xvb", 0) == xvb_ms
    project_ms = durations.get("project", 0)
    assert project_ms <= max(0, 600_000 * max_fraction - xvb_ms)
    assert 0 <= debt <= 1_800_000
    assert debt == pytest.approx(min(1_800_000, debt_ms + percent / 100 * 600_000 - project_ms))
    assert [name for name, _ in segments] == [
        name for name in ("xvb", "p2pool", "project") if name in durations
    ]
    if xvb_ms == 600_000:
        assert project_ms == 0
        assert debt >= min(debt_ms, 1_800_000)


@settings(max_examples=50, deadline=None)
@given(
    percent=st.integers(1, 10),
    xvb_ms=st.one_of(st.just(0), st.integers(15_000, 300_000)),
)
def test_daily_share_with_room(percent, xvb_ms):
    result = simulate([xvb_ms] * 144, percent, 0.85)
    assert result.project_share == pytest.approx(percent / 100, rel=0.05)


@settings(max_examples=50, deadline=None)
@given(
    percent=st.floats(0.1, 10, allow_nan=False, allow_infinity=False),
    xvb_ms=st.one_of(st.just(0), st.integers(15_000, 300_000)),
)
@example(percent=0.28, xvb_ms=0)
def test_weekly_share_with_room_stays_within_one_slice(percent, xvb_ms):
    cycles = 7 * 144
    result = simulate([xvb_ms] * cycles, percent, 0.85)
    target_ms = cycles * 600_000 * percent / 100
    assert 0 <= target_ms - result.project_ms < 60_000
    assert result.debt_ms == pytest.approx(target_ms - result.project_ms, rel=0, abs=1e-6)


@pytest.mark.parametrize("percent", [0.1, 0.28])
@pytest.mark.parametrize("drift_ms", [-0.001, 0.001])
def test_weekly_debt_rejects_accounting_drift(monkeypatch, percent, drift_ms):
    result = simulate([0] * (7 * 144), percent, 0.85)
    monkeypatch.setattr(
        f"{__name__}.simulate",
        lambda *_args: replace(result, debt_ms=result.debt_ms + drift_ms),
    )
    with pytest.raises(AssertionError):
        test_weekly_share_with_room_stays_within_one_slice.hypothesis.inner_test(
            percent=percent, xvb_ms=0
        )
