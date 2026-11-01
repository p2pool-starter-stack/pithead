import pytest

from mining_dashboard import go_bridge, go_domain
from mining_dashboard.service import metrics
from mining_dashboard.web.views import charts


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class State:
    def get_xvb_stats(self):
        return {}

    def get_tiers(self):
        return {}


@pytest.fixture
def history(monkeypatch):
    now = 3_000_000.0
    monkeypatch.setattr(metrics.time, "time", lambda: now)
    monkeypatch.setattr(charts.time, "time", lambda: now)
    rows = []
    for index in range(86_400):
        value = float(index % 100)
        rows.append(
            {
                "t": str(index),
                "timestamp": now - (86_399 - index) * 30,
                "v": value + 2,
                "v_p2pool": value,
                "v_xvb": 2.0,
                "v_p2pool_1m": value,
                "v_xvb_1m": 2.0,
                "v_p2pool_1h": value,
                "v_xvb_1h": 2.0,
                "v_p2pool_12h": value,
                "v_xvb_12h": 2.0,
                "v_p2pool_24h": value,
                "v_xvb_24h": 2.0,
            }
        )
    return now, rows


def test_compact_domain_uses_reference_averages_without_history(history):
    now, rows = history
    result = go_domain.collect({}, State(), history=rows, now=now, compact=True)

    require("history" not in result, "compact domain included history")
    require(
        result["averages"]
        == {
            "p2pool_1h": metrics._avg_p2pool_at(rows, 3600, now),
            "p2pool_24h": metrics._avg_p2pool_at(rows, 86400, now),
            "p2pool_30d": metrics._avg_p2pool_at(rows, 30 * 86400, now),
            "xvb_routed_1h": metrics._avg_xvb_at(rows, 3600, now),
            "xvb_routed_24h": metrics._avg_xvb_at(rows, 86400, now),
        },
        "compact averages differ from reference",
    )


@pytest.mark.parametrize(
    ("query", "maximum", "duration"),
    [
        ({}, 700, 86_399 * 30),
        ({"range": "1h"}, 121, 3600),
        ({"range": "unknown"}, 700, 86_399 * 30),
        ({"from": "2990000", "to": "2995000"}, 167, 5000),
    ],
)
def test_compact_chart_matches_reference_preparation(history, query, maximum, duration):
    _, rows = history
    shares = [{"ts": rows[-1]["timestamp"]}]
    prepared = go_bridge._compact_chart(rows, {"shares": shares}, query, rows[-1]["timestamp"])
    range_arg = query.get("range", "all")
    window = charts.parse_window(query.get("from"), query.get("to"))
    filtered, filtered_shares = charts._filter_range(
        rows, shares, range_arg, window, rows[-1]["timestamp"]
    )

    require(
        prepared["history"] == charts._downsample_history(filtered, duration),
        "prepared history differs from reference",
    )
    require(prepared["shares"] == filtered_shares, "prepared shares differ from reference")
    require(prepared["duration"] == duration, "prepared duration differs from reference")
    require(len(prepared["history"]) <= maximum, "prepared history exceeds its bound")
