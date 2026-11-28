import pytest

import mining_dashboard.service.metrics as metrics
import mining_dashboard.web.views.series_views as series_views
from mining_dashboard.helper import utils
from mining_dashboard.service.row_order import RowOrder
from tests.web.views.projection_inputs import (
    CASES,
    GAUGE_COLUMNS,
    gauge_rows,
    history_rows,
    make_rng,
    modes,
    outcome,
    pick_bounds,
    pick_now,
    pin_clock,
    share_rows,
    sizes,
    stat_rows,
    views_of,
)
from tests.web.views.projection_oracle import (
    old_avg_p2pool_over_window,
    old_avg_xvb_over_window,
    old_downsample_gauge_rows,
    old_downsample_share_stats,
    old_filter_share_stats,
    old_pplns_weight_in_window,
    old_share_reject_pct,
    old_shares_in_pplns_window,
)


@pytest.fixture
def pinned_clock(monkeypatch):
    return pin_clock(monkeypatch)


@pytest.mark.parametrize("seconds", [60, 3600, 86_400, 30 * 86_400, 1e12, 0])
def test_metric_windows_match_old(pinned_clock, seconds):
    rng = make_rng(5005 + int(seconds))
    for _ in range(CASES // 2):
        history = history_rows(rng, sizes(rng), modes(rng))
        pinned_clock["now"] = pick_now(rng, history, "timestamp")
        marked = views_of(history, "timestamp", RowOrder())
        for new, old in (
            (metrics._avg_p2pool_over_window, old_avg_p2pool_over_window),
            (metrics._avg_xvb_over_window, old_avg_xvb_over_window),
        ):
            expected = outcome(old, history, seconds)
            assert outcome(new, history, seconds) == expected
            assert outcome(new, marked, seconds) == expected


def test_share_reject_pct_matches_old(pinned_clock):
    rng = make_rng(6006)
    for _ in range(CASES):
        rows = stat_rows(rng, sizes(rng), modes(rng))
        pinned_clock["now"] = pick_now(rng, rows, "ts")
        window = rng.choice([0, 60, 3600, 86_400, 1e12])
        now = rng.choice([None, pinned_clock["now"] - rng.choice([0, 50, 5000])])
        expected = outcome(old_share_reject_pct, rows, window, now)
        marked = views_of(rows, "ts", RowOrder())
        assert outcome(metrics.share_reject_pct, rows, window, now) == expected
        assert outcome(metrics.share_reject_pct, marked, window, now) == expected


def test_pplns_window_sums_match_old(pinned_clock):
    rng = make_rng(7007)
    for _ in range(CASES):
        shares = share_rows(rng, sizes(rng), modes(rng))
        pinned_clock["now"] = pick_now(rng, shares, "ts")
        window = rng.choice([0, 1, 2160, 8640, 1e9])
        block = rng.choice([10, 30, 0.5])
        now = rng.choice([None, pinned_clock["now"] - rng.choice([0, 10, 4000])])
        marked = views_of(shares, "ts", RowOrder())
        for new, old in (
            (utils.shares_in_pplns_window, old_shares_in_pplns_window),
            (utils.pplns_weight_in_window, old_pplns_weight_in_window),
        ):
            expected = outcome(old, shares, window, block, now)
            assert outcome(new, shares, window, block, now) == expected
            assert outcome(new, marked, window, block, now) == expected


def old_pipeline(rows, range_arg, window):
    return old_downsample_share_stats(old_filter_share_stats(rows, range_arg, window))


def new_pipeline(rows, range_arg, window):
    return series_views._downsample_share_stats(
        series_views._filter_share_stats(rows, range_arg, window)
    )


def test_share_stats_filter_and_sums_match_old(pinned_clock):
    rng = make_rng(8008)
    for _ in range(CASES):
        rows = stat_rows(rng, rng.choice([0, 1, 5, 699, 700, 701, 1500, 3000]), modes(rng))
        pinned_clock["now"] = pick_now(rng, rows, "ts")
        window = pick_bounds(rng, rows, "ts") if rng.random() < 0.4 else None
        range_arg = rng.choice(["all", "1h", "24h", "1w", "1m", "bogus"])
        marked = views_of(rows, "ts", RowOrder())
        expected = outcome(old_filter_share_stats, rows, range_arg, window)
        assert outcome(series_views._filter_share_stats, rows, range_arg, window) == expected
        assert outcome(series_views._filter_share_stats, marked, range_arg, window) == expected
        expected = outcome(old_downsample_share_stats, rows)
        assert outcome(series_views._downsample_share_stats, rows) == expected
        assert outcome(series_views._downsample_share_stats, marked) == expected
        expected = outcome(old_pipeline, rows, range_arg, window)
        assert outcome(new_pipeline, rows, range_arg, window) == expected
        assert outcome(new_pipeline, marked, range_arg, window) == expected


def test_gauge_downsample_matches_old():
    rng = make_rng(9009)
    for _ in range(CASES // 4):
        rows = gauge_rows(rng, rng.choice([0, 1, 700, 701, 1400, 2900]), modes(rng))
        expected = outcome(old_downsample_gauge_rows, rows, GAUGE_COLUMNS)
        assert outcome(series_views._downsample_gauge_rows, rows, GAUGE_COLUMNS) == expected
