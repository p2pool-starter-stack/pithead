import tests.web.views.test_views as test_views_module
from mining_dashboard.web.views.worker_detail import build_worker_detail

_shared = test_views_module.TestBuildWorkerHashrateHistory()


def test_recorded_rate_and_source_reach_the_chart(monkeypatch):
    sm, data, range_arg, window = _shared._detail(monkeypatch)
    try:
        sm.add_worker_history(
            [
                {
                    "ts": 1000.0,
                    "name": "rig1",
                    "h15": 0.0,
                    "accepted": 0,
                    "rejected": 0,
                    "rate": 96.5,
                    "source": "rig",
                }
            ]
        )
        d = build_worker_detail("rig1", data, sm, range_arg, window)
    finally:
        sm.close()
    assert d["hashrate_history"]["hashrate"] == [{"x": 1000000, "y": 96.5, "source": "rig"}]


def test_legacy_rows_fall_back_to_h15_without_a_source(monkeypatch):
    sm, data, range_arg, window = _shared._detail(monkeypatch)
    try:
        sm.add_worker_history(
            [
                {
                    "ts": 1000.0,
                    "name": "rig1",
                    "h15": 512.0,
                    "accepted": 0,
                    "rejected": 0,
                    "rate": None,
                    "source": None,
                }
            ]
        )
        d = build_worker_detail("rig1", data, sm, range_arg, window)
    finally:
        sm.close()
    assert d["hashrate_history"]["hashrate"] == [{"x": 1000000, "y": 512.0, "source": None}]


def test_disconnect_shows_a_gap_marker_not_a_zero(monkeypatch):
    sm, data, range_arg, window = _shared._detail(monkeypatch)
    try:
        sm.add_worker_history(
            [
                {"ts": 1000.0, "name": "rig1", "h15": 100.0, "accepted": 0, "rejected": 0},
                {"ts": 1700.0, "name": "rig1", "h15": 200.0, "accepted": 0, "rejected": 0},
            ]
        )
        d = build_worker_detail("rig1", data, sm, range_arg, window)
    finally:
        sm.close()
    series = d["hashrate_history"]["hashrate"]
    assert [p["y"] for p in series] == [100.0, None, 200.0]
    assert series[1]["x"] == 1350000
    assert series[1]["source"] is None


def test_no_gap_marker_under_two_capture_intervals(monkeypatch):
    sm, data, range_arg, window = _shared._detail(monkeypatch)
    try:
        sm.add_worker_history(
            [
                {"ts": 1000.0, "name": "rig1", "h15": 100.0, "accepted": 0, "rejected": 0},
                {"ts": 1400.0, "name": "rig1", "h15": 200.0, "accepted": 0, "rejected": 0},
            ]
        )
        d = build_worker_detail("rig1", data, sm, range_arg, window)
    finally:
        sm.close()
    series = d["hashrate_history"]["hashrate"]
    assert [p["y"] for p in series] == [100.0, 200.0]
    assert all(p["source"] is None for p in series)
