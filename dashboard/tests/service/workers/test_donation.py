import pytest

from mining_dashboard.service.data_helpers import _merge_direct_stats
from mining_dashboard.service.workers.donation import fleet_donation, reported_level
from mining_dashboard.web.views.infra_views import build_workers


def _rig(name, h15, level, status="online"):
    return {"name": name, "ip": "8.8.8.8", "status": status, "h15": h15, "donate_level": level}


@pytest.mark.parametrize(
    "value,expected",
    [
        (0, 0),
        (1, 1),
        (5, 5),
        (100, 100),
        (-1, None),
        (101, None),
        (True, None),
        ("1", None),
        (1.5, None),
        (None, None),
    ],
)
def test_reported_level_accepts_only_whole_percents(value, expected):
    assert reported_level({"donate_level": value}) == expected


def test_reported_level_ignores_a_non_dict_payload():
    assert reported_level(None) is None


def _direct(extra):
    worker = {"name": "r1", "ip": "8.8.8.8", "status": "online", "uptime": 0}
    [row] = _merge_direct_stats([worker], [extra], "3333")
    return row


def test_direct_poll_records_the_level_the_miner_reports():
    assert _direct({"api_ok": True, "adopted": True, "donate_level": 1})["donate_level"] == 1


def test_direct_poll_without_a_level_leaves_it_unknown():
    assert "donate_level" not in _direct({"api_ok": True, "adopted": True})


def test_a_proxy_summary_level_is_not_a_rig_level():
    row = _direct({"api_ok": True, "kind": "proxy", "donate_level": 0})
    assert "donate_level" not in row


def test_fleet_percent_is_weighted_by_each_rigs_hashrate():
    out = fleet_donation([_rig("a", 3000, 1), _rig("b", 1000, 5), _rig("c", 6000, 0)])
    assert out["available"] is True
    assert out["percent"] == pytest.approx(0.8)
    assert (out["rigs"], out["donating"], out["unknown"]) == (3, 2, 0)


def test_all_off_fleet_reports_zero():
    out = fleet_donation([_rig("a", 100, 0), _rig("b", 200, 0)])
    assert out["available"] is True and out["percent"] == 0


def test_an_unknown_hashing_rig_makes_the_fleet_figure_unavailable_not_zero():
    out = fleet_donation([_rig("a", 100, 0), _rig("b", 200, None)])
    assert out["available"] is False and "percent" not in out
    assert out["unknown"] == 1


def test_offline_and_idle_known_rigs_do_not_weigh_in():
    out = fleet_donation([_rig("a", 100, 2), _rig("b", 0, 5), _rig("c", 900, None, "offline")])
    assert out["available"] is True and out["percent"] == 2


def test_an_idle_online_rig_with_no_level_still_blocks_an_off_verdict():
    out = fleet_donation([_rig("a", 100, 0), _rig("b", 0, None)])
    assert out["available"] is False and out["unknown"] == 1


def test_no_rigs_is_unavailable():
    assert fleet_donation([])["available"] is False


def test_worker_rows_carry_the_reported_level_or_none():
    rows = build_workers([_rig("a", 1, 1), {**_rig("b", 1, None)}])
    assert [r["donate_level"] for r in rows] == [1, None]
