import pytest

import mining_dashboard.web.views.charts as charts
import mining_dashboard.web.views.series_views as series_views
from mining_dashboard.config.config import (
    DEFAULT_HASHRATE_WINDOW,
    HASHRATE_WINDOW_COLUMNS,
    HASHRATE_WINDOWS,
)
from mining_dashboard.helper.time_rows import TimeOrdered
from mining_dashboard.service.row_order import RowOrder
from tests.web.views.projection_inputs import (
    CASES,
    GAUGE_COLUMNS,
    HISTORY_COLUMNS,
    STAT_COLUMNS,
    SUM_CELLS,
    history_rows,
    make_rng,
    modes,
    outcome,
    pick_bounds,
    pick_now,
    pin_clock,
    share_rows,
    sizes,
    views_of,
)
from tests.web.views.projection_oracle import (
    old_build_chart,
    old_downsample_gauge_rows,
    old_downsample_history,
    old_downsample_share_stats,
    old_filter_range,
    old_share_points,
)


@pytest.fixture
def pinned_clock(monkeypatch):
    return pin_clock(monkeypatch)


def test_generator_reaches_the_fast_path_and_the_scan():
    rng = make_rng(11)
    marked = plain = 0
    for _ in range(300):
        rows = history_rows(rng, sizes(rng), modes(rng))
        if isinstance(views_of(rows, "timestamp", RowOrder()), TimeOrdered):
            marked += 1
        else:
            plain += 1
    assert marked > 60 and plain > 60


def test_filter_range_matches_old(pinned_clock):
    rng = make_rng(1001)
    for _ in range(CASES):
        history = history_rows(rng, sizes(rng), modes(rng))
        shares = share_rows(rng, sizes(rng), modes(rng))
        pinned_clock["now"] = pick_now(rng, history, "timestamp")
        window = None
        if rng.random() < 0.5:
            window = pick_bounds(rng, history + shares, rng.choice(["timestamp", "ts"]))
        range_arg = rng.choice(["all", "1h", "24h", "1w", "1m", "bogus", ""])
        expected = outcome(old_filter_range, history, shares, range_arg, window)
        order = RowOrder()
        marked = (views_of(history, "timestamp", order), views_of(shares, "ts", order))
        assert outcome(charts._filter_range, history, shares, range_arg, window) == expected
        assert outcome(charts._filter_range, *marked, range_arg, window) == expected


@pytest.mark.parametrize("avg_window", list(HASHRATE_WINDOWS) + ["bogus"])
def test_build_chart_matches_old(pinned_clock, avg_window):
    rng = make_rng(2002 + len(avg_window))
    for _ in range(CASES // 4):
        history = history_rows(rng, rng.choice([0, 1, 5, 150, 900, 2500]), modes(rng), False)
        shares = share_rows(rng, sizes(rng), modes(rng))
        pinned_clock["now"] = pick_now(rng, history, "timestamp")
        window = pick_bounds(rng, history, "timestamp") if rng.random() < 0.4 else None
        range_arg = rng.choice(["all", "1h", "24h", "1w", "1m", "bogus"])
        expected = outcome(old_build_chart, history, shares, range_arg, window, avg_window)
        order = RowOrder()
        marked = (views_of(history, "timestamp", order), views_of(shares, "ts", order))
        assert (
            outcome(charts.build_chart, history, shares, range_arg, window, avg_window) == expected
        )
        assert outcome(charts.build_chart, *marked, range_arg, window, avg_window) == expected


def test_downsample_history_default_columns_match_old():
    rng = make_rng(3003)
    for _ in range(CASES // 5):
        history = history_rows(rng, rng.choice([700, 701, 1400, 3001]), modes(rng))
        duration = rng.choice([7200, 80_000, 500_000, 2_000_000])
        expected = outcome(old_downsample_history, history, duration)
        assert outcome(charts._downsample_history, history, duration) == expected


def test_share_points_match_old_including_ties_and_unsorted_history():
    rng = make_rng(4004)
    for _ in range(CASES):
        history = history_rows(rng, sizes(rng), modes(rng))
        shares = share_rows(rng, sizes(rng), modes(rng))
        if history and rng.random() < 0.5:
            shares += [{"ts": r["timestamp"], "difficulty": 1} for r in history[:3]]
            shares += [
                {"ts": (a["timestamp"] + b["timestamp"]) / 2, "difficulty": 1}
                for a, b in zip(history, history[1:], strict=False)
                if isinstance(a["timestamp"], int | float)
                and isinstance(b["timestamp"], int | float)
            ][:6]
        assert outcome(charts._share_points, history, shares) == outcome(
            old_share_points, history, shares
        )


def test_share_points_with_empty_history_count_nothing():
    shares = [{"ts": 5.0, "difficulty": 1}, {"ts": 9.0, "difficulty": 1}]
    assert charts._share_points([], shares) == []
    assert old_share_points([], shares) == []


def test_share_points_tie_goes_to_the_right_neighbour():
    history = [{"timestamp": 10.0}, {"timestamp": 20.0}]
    points = charts._share_points(history, [{"ts": 15.0}])
    assert [p["x"] for p in points] == [20_000]
    assert points == old_share_points(history, [{"ts": 15.0}])


@pytest.mark.parametrize("values", SUM_CELLS, ids=[repr(v) for v in SUM_CELLS])
@pytest.mark.parametrize("copies", [1, 3, 7])
def test_chart_and_stat_sums_keep_the_float_bits(values, copies):
    count = 701 * copies
    cycle = [values[i % len(values)] for i in range(count)]
    history = [
        {"t": "t", "timestamp": float(i), **dict.fromkeys(HISTORY_COLUMNS, v)}
        for i, v in enumerate(cycle)
    ]
    assert outcome(charts._downsample_history, history, 80_000) == outcome(
        old_downsample_history, history, 80_000
    )
    stats = [{"ts": float(i), **dict.fromkeys(STAT_COLUMNS, v)} for i, v in enumerate(cycle)]
    assert outcome(series_views._downsample_share_stats, stats) == outcome(
        old_downsample_share_stats, stats
    )
    gauge = [{"ts": float(i), **dict.fromkeys(GAUGE_COLUMNS, v)} for i, v in enumerate(cycle)]
    assert outcome(series_views._downsample_gauge_rows, gauge, GAUGE_COLUMNS) == outcome(
        old_downsample_gauge_rows, gauge, GAUGE_COLUMNS
    )


def test_window_columns_cover_what_the_chart_reads():
    for avg_window in list(HASHRATE_WINDOWS) + ["bogus", None]:
        columns = set(charts._chart_columns(avg_window))
        assert (
            set(HASHRATE_WINDOW_COLUMNS.get(avg_window, HASHRATE_WINDOW_COLUMNS["10m"])) <= columns
        )
        if avg_window == DEFAULT_HASHRATE_WINDOW:
            assert "v" in columns
