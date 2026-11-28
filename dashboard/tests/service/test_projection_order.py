import copy
import pickle
import time
from collections import deque

import pytest

import mining_dashboard.service.metrics as metrics
import mining_dashboard.service.row_order as row_order
import mining_dashboard.web.views.charts as charts
import mining_dashboard.web.views.series_views as series_views
from mining_dashboard.helper import utils
from mining_dashboard.helper.time_rows import (
    TimeOrdered,
    numeric_column,
    rows_ordered,
    window_rows,
)
from mining_dashboard.service.row_order import RowOrder
from mining_dashboard.service.storage_service import StateManager

NOW = 1_700_000_000.0


class Row(dict):
    touched = 0

    def __getitem__(self, key):
        Row.touched += 1
        return super().__getitem__(key)

    def get(self, key, default=None):
        Row.touched += 1
        return super().get(key, default)


def ordered_history(n, step=30.0):
    return [
        Row(
            t=f"t{i}",
            timestamp=NOW - (n - i) * step,
            v=10.0,
            v_p2pool=10.0,
            v_xvb=0.0,
            accepted=1,
            rejected=0,
        )
        for i in range(n)
    ]


def ordered_shares(n, step=30.0):
    return [Row(ts=NOW - (n - i) * step, difficulty=5) for i in range(n)]


def marked(rows, field):
    view = RowOrder().view("x", field, rows)
    assert isinstance(view, TimeOrdered)
    return view


@pytest.fixture
def clock(monkeypatch):
    monkeypatch.setattr(time, "time", lambda: NOW)


class TestWindowRows:
    def test_ordered_view_returns_only_the_window(self):
        rows = marked(ordered_history(100), "timestamp")
        lo, hi = NOW - 1000, NOW - 500
        got = window_rows(rows, "timestamp", lo, hi)
        assert got == [r for r in rows if lo <= r["timestamp"] <= hi]
        assert 0 < len(got) < len(rows)
        assert window_rows(rows, "timestamp", lo) == [r for r in rows if r["timestamp"] >= lo]

    def test_edges_are_inclusive_and_ties_stay_together(self):
        rows = marked([{"ts": t} for t in (1, 2, 2, 2, 3, 3, 4)], "ts")
        assert window_rows(rows, "ts", 2, 3) == [{"ts": t} for t in (2, 2, 2, 3, 3)]
        assert window_rows(rows, "ts", 5, 9) == []
        assert window_rows(rows, "ts", 0, 0.5) == []
        assert window_rows(rows, "ts", 3, 2) == []

    def test_plain_list_is_returned_untouched(self):
        rows = [{"ts": 1}, {"ts": 2}]
        assert window_rows(rows, "ts", 2, 2) is rows

    def test_other_field_nan_bounds_and_mutated_views_fall_back_to_the_scan(self):
        rows = marked([{"ts": 1, "timestamp": 9}, {"ts": 2, "timestamp": 1}], "ts")
        assert window_rows(rows, "timestamp", 5) is rows
        assert window_rows(rows, "ts", float("nan")) is rows
        assert window_rows(rows, "ts", 1, float("nan")) is rows

    @pytest.mark.parametrize(
        "mutate",
        [
            lambda r: r.append({"ts": 0}),
            lambda r: r.extend([{"ts": 0}]),
            lambda r: r.insert(0, {"ts": 9}),
            lambda r: r.pop(),
            lambda r: r.remove(r[0]),
            lambda r: r.clear(),
            lambda r: r.sort(key=lambda x: -x["ts"]),
            lambda r: r.reverse(),
            lambda r: r.__setitem__(0, {"ts": 99}),
            lambda r: r.__delitem__(0),
            lambda r: r.__iadd__([{"ts": 0}]),
            lambda r: r.__imul__(2),
        ],
        ids=[
            "append",
            "extend",
            "insert",
            "pop",
            "remove",
            "clear",
            "sort",
            "reverse",
            "setitem",
            "delitem",
            "iadd",
            "imul",
        ],
    )
    def test_any_mutation_of_a_view_turns_the_fast_path_off(self, mutate):
        rows = marked([{"ts": 1}, {"ts": 2}, {"ts": 3}], "ts")
        mutate(rows)
        assert window_rows(rows, "ts", 2, 3) is rows

    def test_copies_of_a_view_do_not_claim_to_be_ordered(self):
        rows = marked([{"ts": 3}, {"ts": 4}], "ts")
        revived = pickle.loads(pickle.dumps(rows))  # noqa: S301
        for clone in (copy.copy(rows), copy.deepcopy(rows), revived):
            assert clone == rows
            assert [r for r in window_rows(clone, "ts", 4) if r["ts"] >= 4] == [{"ts": 4}]
        assert type(rows[0:1]) is list
        assert type(list(rows)) is list


class TestRowsOrdered:
    @pytest.mark.parametrize(
        ("rows", "expected"),
        [
            ([], True),
            ([{"ts": 1}], True),
            ([{"ts": 1}, {"ts": 1}, {"ts": 2.5}], True),
            ([{"ts": 2}, {"ts": 1}], False),
            ([{"ts": 1}, {"ts": 3}, {"ts": 2}, {"ts": 9}], False),
            ([{"ts": float("nan")}], False),
            ([{"ts": 1}, {"ts": float("nan")}], False),
            ([{"ts": 1}, {"ts": None}], False),
            ([{"ts": 1}, {"other": 2}], False),
            ([{"ts": 1}, {"ts": "2"}], False),
        ],
    )
    def test_cases(self, rows, expected):
        assert rows_ordered(rows, "ts") is expected


class TestNumericColumn:
    def test_only_a_single_exact_numeric_type_is_trusted(self):
        rows = lambda *vals: [{"c": v} for v in vals]  # noqa: E731
        assert numeric_column(rows(1.0, 0.0), "c") == [1.0, 0.0]
        assert numeric_column(rows(1, 0), "c") == [1, 0]
        assert numeric_column(rows(1, 0.0), "c") is None
        assert numeric_column(rows(True, False), "c") is None
        assert numeric_column(rows(1.0, None), "c") is None
        assert numeric_column(rows(1.0, "2"), "c") is None
        assert numeric_column([{"c": 1.0}, {}], "c") is None
        assert numeric_column(rows(1.0, 2.0), "c", frozenset({int})) is None
        assert numeric_column([5], "c") is None


class TestFastPathTouchesFewRows:
    N = 20000

    def setup_method(self):
        Row.touched = 0

    def test_metric_windows(self, clock):
        history = marked(ordered_history(self.N), "timestamp")
        Row.touched = 0
        metrics._avg_p2pool_over_window(history, 3600)
        metrics._avg_xvb_over_window(history, 3600)
        assert Row.touched < 800
        Row.touched = 0
        metrics._avg_p2pool_over_window(list(history), 3600)
        assert Row.touched >= self.N

    def test_reject_pct_and_stat_filters(self, clock):
        rows = marked(ordered_shares(self.N), "ts")
        Row.touched = 0
        metrics.share_reject_pct(rows, 3600)
        series_views._filter_share_stats(rows, "1h")
        series_views._filter_share_stats(rows, "all", None)
        series_views._filter_share_stats(rows, "x", (NOW - 900, NOW - 300))
        assert Row.touched < 1500

    def test_pplns_sums(self, clock):
        shares = marked(ordered_shares(self.N), "ts")
        Row.touched = 0
        assert utils.shares_in_pplns_window(shares, 60, 10) == 20
        assert utils.pplns_weight_in_window(shares, 60, 10) == 100
        assert Row.touched < 400

    def test_chart_range_filter(self, clock):
        history = marked(ordered_history(self.N), "timestamp")
        shares = marked(ordered_shares(self.N), "ts")
        Row.touched = 0
        got_h, got_s = charts._filter_range(history, shares, "1h")
        assert len(got_h) == len(got_s) == 120
        got_h, got_s = charts._filter_range(history, shares, "x", (NOW - 900, NOW - 300))
        assert len(got_h) == len(got_s) == 21
        assert Row.touched < 1500


class TestRowOrderView:
    def test_unchanged_rows_are_verified_once(self, monkeypatch):
        calls = []
        real = row_order.rows_ordered
        monkeypatch.setattr(row_order, "rows_ordered", lambda *a: calls.append(a) or real(*a))
        rows = [{"ts": 1}, {"ts": 2}]
        order = RowOrder()
        order.view("n", "ts", rows)
        order.view("n", "ts", rows)
        order.view("n", "ts", rows)
        assert len(calls) == 1

    def test_out_of_order_rows_come_back_as_a_plain_list(self):
        rows = [{"ts": 1}, {"ts": 5}, {"ts": 3}]
        view = RowOrder().view("n", "ts", rows)
        assert type(view) is list
        assert view == rows and view is not rows

    def test_views_are_copies(self):
        rows = [{"ts": 1}, {"ts": 2}]
        view = RowOrder().view("n", "ts", rows)
        view.append({"ts": 0})
        assert rows == [{"ts": 1}, {"ts": 2}]

    def test_append_that_breaks_the_order_is_noticed(self):
        rows = [{"ts": 1}, {"ts": 2}]
        order = RowOrder()
        assert isinstance(order.view("n", "ts", rows), TimeOrdered)
        rows.append({"ts": 1.5})
        assert type(order.view("n", "ts", rows)) is list

    def test_steady_state_append_and_popleft_is_noticed(self):
        rows = deque([{"ts": 1}, {"ts": 2}, {"ts": 3}])
        order = RowOrder()
        assert isinstance(order.view("n", "ts", rows), TimeOrdered)
        rows.append({"ts": 0})
        rows.popleft()
        assert len(rows) == 3
        assert type(order.view("n", "ts", rows)) is list
        rows.popleft()
        rows.popleft()
        rows.append({"ts": 7})
        assert isinstance(order.view("n", "ts", rows), TimeOrdered)

    def test_replaced_last_row_with_same_length_is_noticed(self):
        rows = [{"ts": 1}, {"ts": 2}]
        order = RowOrder()
        assert isinstance(order.view("n", "ts", rows), TimeOrdered)
        rows[-1] = {"ts": 0}
        assert type(order.view("n", "ts", rows)) is list

    def test_replaced_first_row_with_same_length_and_last_row_is_noticed(self):
        rows = [{"ts": 1}, {"ts": 2}, {"ts": 3}]
        order = RowOrder()
        assert isinstance(order.view("n", "ts", rows), TimeOrdered)
        rows[0] = {"ts": 99}
        assert type(order.view("n", "ts", rows)) is list

    def test_insert_in_the_middle_keeps_the_ends_but_is_noticed(self):
        rows = [{"ts": 1}, {"ts": 2}, {"ts": 3}]
        order = RowOrder()
        assert isinstance(order.view("n", "ts", rows), TimeOrdered)
        rows.insert(1, {"ts": 9})
        assert type(order.view("n", "ts", rows)) is list

    def test_replaced_container_with_the_same_ends_and_size_is_noticed(self):
        first, middle_a, middle_b, last = ({"ts": 1}, {"ts": 2}, {"ts": 3}, {"ts": 4})
        order = RowOrder()
        assert isinstance(order.view("n", "ts", [first, middle_a, middle_b, last]), TimeOrdered)
        assert type(order.view("n", "ts", [first, middle_b, middle_a, last])) is list

    def test_replaced_container_is_noticed(self):
        order = RowOrder()
        assert isinstance(order.view("n", "ts", [{"ts": 1}, {"ts": 2}]), TimeOrdered)
        assert type(order.view("n", "ts", [{"ts": 2}, {"ts": 1}])) is list

    def test_names_do_not_share_verdicts(self):
        order = RowOrder()
        assert isinstance(order.view("a", "ts", [{"ts": 1}, {"ts": 2}]), TimeOrdered)
        assert type(order.view("b", "ts", [{"ts": 2}, {"ts": 1}])) is list
        assert isinstance(order.view("a", "ts", [{"ts": 1}, {"ts": 2}]), TimeOrdered)

    def test_empty_rows(self):
        view = RowOrder().view("n", "ts", [])
        assert view == []


class TestStateManagerOrder:
    def test_backward_clock_step_keeps_the_scan(self, state_manager, monkeypatch):
        clock = {"now": NOW}
        monkeypatch.setattr(time, "time", lambda: clock["now"])
        for offset in (0, 30, 60):
            clock["now"] = NOW + offset
            state_manager.update_history(100.0, 60.0, 40.0)
        assert isinstance(state_manager.get_history(), TimeOrdered)
        clock["now"] = NOW - 7200
        state_manager.update_history(100.0, 60.0, 40.0)
        for offset in (100, 130):
            clock["now"] = NOW + offset
            state_manager.update_history(100.0, 60.0, 40.0)
        history = state_manager.get_history()
        assert type(history) is list
        clock["now"] = NOW + 130
        cutoff = NOW + 20
        kept, _ = charts._filter_range(history, [], "x", (cutoff, NOW + 1000))
        assert [x["timestamp"] for x in kept] == [NOW + 30, NOW + 60, NOW + 100, NOW + 130]
        assert metrics._avg_p2pool_over_window(history, 110) == 60.0

    def test_steady_state_retention_keeps_the_view_honest(self, state_manager, monkeypatch):
        monkeypatch.setattr("mining_dashboard.service.storage_service.HISTORY_RETENTION_SEC", 100.0)
        clock = {"now": NOW}
        monkeypatch.setattr(time, "time", lambda: clock["now"])
        for _ in range(5):
            clock["now"] += 30
            state_manager.update_history(1.0)
            assert isinstance(state_manager.get_history(), TimeOrdered)
        clock["now"] -= 10
        state_manager.update_history(1.0)
        clock["now"] += 40
        state_manager.update_history(1.0)
        assert type(state_manager.get_history()) is list

    def test_shares_and_share_stats_follow_their_order(self, state_manager, monkeypatch):
        monkeypatch.setattr(time, "time", lambda: NOW)
        for ts in (NOW - 300, NOW - 200, NOW - 100):
            state_manager.add_share(ts, 5)
            state_manager.add_share_stats(ts, accepted=1)
        assert isinstance(state_manager.get_shares(), TimeOrdered)
        assert isinstance(state_manager.get_share_stats(), TimeOrdered)
        state_manager.add_share(NOW - 250, 5)
        state_manager.add_share_stats(NOW - 250, accepted=1)
        shares = state_manager.get_shares()
        stats = state_manager.get_share_stats()
        assert type(shares) is list and type(stats) is list
        assert [s["ts"] for s in shares] == [NOW - 300, NOW - 200, NOW - 100, NOW - 250]
        assert utils.shares_in_pplns_window(shares, 1, 260) == 3
        assert metrics.share_reject_pct(stats, 260) == 0.0

    def test_reload_from_the_database_is_ordered(self, tmp_path, monkeypatch):
        monkeypatch.setattr(time, "time", lambda: NOW)
        path = str(tmp_path / "state.db")
        first = StateManager(db_path=path)
        for ts in (NOW - 90, NOW - 60, NOW - 30):
            monkeypatch.setattr(time, "time", lambda ts=ts: ts)
            first.update_history(10.0)
            first.add_share(ts, 1)
            first.add_share_stats(ts, accepted=1)
        first.close()
        monkeypatch.setattr(time, "time", lambda: NOW)
        second = StateManager(db_path=path)
        try:
            for rows in (second.get_history(), second.get_shares(), second.get_share_stats()):
                assert isinstance(rows, TimeOrdered)
                assert len(rows) == 3
        finally:
            second.close()

    def test_direct_pokes_into_the_state_are_noticed(self, state_manager):
        state_manager.state["hashrate_history"].append({"t": "a", "timestamp": 5.0})
        assert isinstance(state_manager.get_history(), TimeOrdered)
        state_manager.state["hashrate_history"].append({"t": "b", "timestamp": 1.0})
        assert type(state_manager.get_history()) is list
        state_manager.state["shares"] = [{"ts": 2, "difficulty": 1}, {"ts": 1, "difficulty": 1}]
        assert type(state_manager.get_shares()) is list
