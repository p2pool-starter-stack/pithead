import os
import time
from types import SimpleNamespace

import dashboard_earnings_plugin as adapter
import pytest

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _paired(operation, *args, **kwargs):
    expected = adapter.python_call(operation, *args, **kwargs)
    actual = adapter.NATIVES[operation](*args, **kwargs)
    return expected, actual


def _metrics(**values):
    fields = {
        "network_difficulty": 400_000_000_000,
        "p2pool_1h": 35_000.0,
        "p2pool_30d": 8_000.0,
        "tari_reward": 0.0,
        "tari_difficulty": 0.0,
        "tari_mining": False,
        "tari_local": None,
        "pool_difficulty": 1_000_000.0,
        "xvb_enabled": True,
    }
    return SimpleNamespace(**{**fields, **values})


@pytest.mark.parametrize(
    ("operation", "args"),
    [
        ("xmr_per_hs_day", (600_000_000_000, 400_000_000_000)),
        ("xmr_per_hs_day", (0, 400_000_000_000)),
        ("xtm_per_hs_day", (13_000, 420_000_000_000)),
        ("xtm_per_hs_day", (13_000, 0)),
        ("tari_seconds_to_block_per_hs", (1_677_000_000_000,)),
        ("tari_seconds_to_block_per_hs", (-1,)),
    ],
)
def test_scalar_models_match(operation, args):
    expected, actual = _paired(operation, *args)
    assert actual == pytest.approx(expected)


@pytest.mark.parametrize(
    ("operation", "difficulty"),
    [
        ("xmr_per_hs_day", 3),
        ("xmr_per_hs_day", 3.5),
        ("xtm_per_hs_day", 3),
        ("xtm_per_hs_day", 3.5),
    ],
)
def test_scalar_models_preserve_python_wide_integer_division(operation, difficulty):
    expected, actual = _paired(operation, 2**53 + 1, difficulty)
    assert actual == expected


def test_subnormal_difficulty_preserves_positive_infinity():
    expected, actual = _paired("xmr_per_hs_day", 1.0, 5e-324)
    assert expected == float("inf")
    assert actual == expected


@pytest.mark.parametrize(
    ("zone", "now", "hours", "start_date", "end_date"),
    [
        ("America/Chicago", (2026, 3, 9, 12, 0, 0), 23, (2026, 3, 8), (2026, 3, 9)),
        ("America/Chicago", (2026, 11, 2, 12, 0, 0), 25, (2026, 11, 1), (2026, 11, 2)),
        ("America/Sao_Paulo", (2018, 11, 5, 12, 0, 0), 23, (2018, 11, 4), (2018, 11, 5)),
        ("Pacific/Apia", (2011, 12, 31, 12, 0, 0), 24, (2011, 12, 29), (2011, 12, 31)),
    ],
)
def test_previous_local_day_matches_across_dst(monkeypatch, zone, now, hours, start_date, end_date):
    try:
        with monkeypatch.context() as scoped:
            scoped.setenv("TZ", zone)
            time.tzset()
            stamp = time.mktime((*now, 0, 0, -1))
            expected, actual = _paired("previous_local_day", stamp)
            assert actual == expected
            assert actual[1] - actual[0] == hours * 3600
            assert time.localtime(actual[0])[:3] == start_date
            assert time.localtime(actual[1])[:3] == end_date
    finally:
        time.tzset()


def test_confirmed_disabled_empty_and_wallet_status_match():
    now = 1_800_000_000
    for payouts, wallet in ((None, None), ([], None), ([], {}), ([], {"reachable": False})):
        expected, actual = _paired(
            "confirmed_payouts_summary", payouts, now=now, wallet_status=wallet
        )
        assert actual == expected


def test_confirmed_wide_atomic_sums_are_exact_at_the_json_edge():
    now = 1_800_000_000
    payouts = [
        {"ts": now - 1, "amount_atomic": 9_007_199_254_740_993},
        {"ts": now - 2, "amount_atomic": 9_007_199_254_740_995},
        {"ts": now - 40 * 86_400, "amount_atomic": 7},
    ]
    expected, actual = _paired(
        "confirmed_payouts_summary", payouts, now=now, divisor=1, unit="atomic"
    )
    assert actual == expected
    assert actual["atomic_30d"] == float(18_014_398_509_481_988)
    assert actual["atomic_all"] == float(18_014_398_509_481_995)


def test_confirmed_mixed_float_sums_follow_python_order():
    now = 1_800_000_000
    payouts = [
        {"ts": now - 3, "amount_atomic": 1e16},
        {"ts": now - 2, "amount_atomic": 1.0},
        {"ts": now - 1, "amount_atomic": -1e16},
    ]
    expected, actual = _paired(
        "confirmed_payouts_summary", payouts, now=now, divisor=1.0, unit="atomic"
    )
    assert expected["atomic_all"] == 0.0
    assert actual == expected


def test_confirmed_large_integer_and_float_divisor_match():
    now = 1_800_000_000
    payouts = [{"ts": now, "amount_atomic": 9_007_199_254_740_993}]
    expected, actual = _paired(
        "confirmed_payouts_summary", payouts, now=now, divisor=3.5, unit="atomic"
    )
    assert actual == expected


def test_confirmed_zero_clock_and_marker_shaped_wallet_data_match(monkeypatch):
    try:
        with monkeypatch.context() as scoped:
            scoped.setenv("TZ", "UTC")
            time.tzset()
            wallet = {"detail": {"__pithead_nonfinite_static": "inf"}, "reachable": True}
            expected, actual = _paired(
                "confirmed_payouts_summary",
                [{"amount_atomic": 1}],
                now=0,
                divisor=1,
                unit="atomic",
                wallet_status=wallet,
            )
            assert actual == expected
            assert actual["detail"] == wallet["detail"]
    finally:
        time.tzset()


def test_confirmed_half_open_yesterday_missing_zero_and_future_match(monkeypatch):
    try:
        with monkeypatch.context() as scoped:
            scoped.setenv("TZ", "America/Chicago")
            time.tzset()
            now = time.mktime((2026, 7, 28, 12, 0, 0, 0, 0, -1))
            start = time.mktime((2026, 7, 27, 0, 0, 0, 0, 0, -1))
            end = time.mktime((2026, 7, 28, 0, 0, 0, 0, 0, -1))
            payouts = [
                {"amount_atomic": 1},
                {"ts": 0, "amount_atomic": 2},
                {"ts": start, "amount_atomic": 4},
                {"ts": end - 1, "amount_atomic": 8},
                {"ts": end, "amount_atomic": 16},
                {"ts": now + 1, "amount_atomic": 32},
            ]
            expected, actual = _paired(
                "confirmed_payouts_summary", payouts, now=now, divisor=1, unit="atomic"
            )
            assert actual == expected
            assert actual["atomic_yesterday"] == 12
            assert actual["last_ts"] == now + 1
            assert actual["since_ts"] == start
    finally:
        time.tzset()


def test_build_earnings_matches_with_disabled_and_empty_confirmations():
    data = {
        "network": {"reward": 600_000_000_000},
        "payout_wallet": {"monero": {"reachable": True}, "tari": {"reachable": False}},
    }
    metrics = _metrics(
        p2pool_1h=35_000,
        network_difficulty=400_000_000_000,
        tari_mining=True,
        tari_reward=13_000,
        tari_difficulty=420_000_000_000,
    )
    for payouts, tari_payouts in ((None, None), ([], [])):
        expected, actual = _paired("build_earnings", data, metrics, payouts, tari_payouts, 0.002)
        assert actual == expected


def test_build_earnings_formats_wide_block_reward_exactly():
    reward = 2**53 + 1
    data = {
        "network": {"reward": reward},
        "payout_wallet": {"monero": {"reachable": True}},
    }
    metrics = _metrics(network_difficulty=3)
    expected, actual = _paired("build_earnings", data, metrics, None, None, None)
    assert actual == expected
    assert actual["block_reward"] == f"{reward / 1e12:.4f} XMR"


def test_earnings_vs_actual_rounding_cutoff_matches():
    earnings = {
        "coeff_day": 1e-8,
        "xvb_day": None,
        "confirmed": {"enabled": True, "xmr_30d": 1e-8 * 8000 * 30 * 9.99, "partial": {}},
        "tari_confirmed": {"enabled": False},
    }
    metrics = _metrics(p2pool_30d=8000.0)
    expected, actual = _paired("build_earnings_vs_actual", metrics, earnings, [], 1_760_000_000)
    assert actual == expected
    assert actual["xmr"]["pct"] == 999
    earnings["confirmed"]["xmr_30d"] *= 1.0011
    expected, actual = _paired("build_earnings_vs_actual", metrics, earnings, [], 1_760_000_000)
    assert actual == expected
    assert actual["xmr"]["pct"] is None


def test_prepared_builders_reject_shape_and_preserve_xvb_day():
    from mining_dashboard import go_earnings

    fields = {
        "available",
        "p2pool_hr",
        "p2pool_hr_str",
        "coeff_day",
        "tari_available",
        "tari_coeff_day",
        "tari_difficulty",
        "tari_reward",
        "xvb_day",
        "pool_difficulty",
        "block_reward",
        "disclaimer",
        "confirmed",
        "tari_confirmed",
    }
    prepared = dict.fromkeys(fields)
    for malformed in (None, {}, {**prepared, "extra": True}):
        with pytest.raises(RuntimeError, match="native earnings inputs unavailable"):
            go_earnings.builders(malformed, {}, {"now": 1, "zone": "UTC"})
    builders = go_earnings.builders(prepared, {}, {"now": 1, "zone": "UTC"})
    value = builders["build_earnings"]({}, _metrics(), [], [], 0.004)
    assert value == {**prepared, "xvb_day": 0.004}


def test_prepared_summary_captures_frozen_clock():
    from mining_dashboard import go_earnings

    captured = {}
    prepared = dict.fromkeys(
        {
            "available",
            "p2pool_hr",
            "p2pool_hr_str",
            "coeff_day",
            "tari_available",
            "tari_coeff_day",
            "tari_difficulty",
            "tari_reward",
            "xvb_day",
            "pool_difficulty",
            "block_reward",
            "disclaimer",
            "confirmed",
            "tari_confirmed",
        }
    )
    builders = go_earnings.builders(
        prepared, captured, {"now": 1_760_000_000, "zone": "America/Chicago"}
    )
    builders["build_earnings_vs_actual"](_metrics(), prepared, [], expected_wins_day=0.5)
    request = captured["earnings_summary"]
    assert request["now"] == 1_760_000_000
    assert request["zone"] == "America/Chicago"
    assert request["args"][3:] == [0.5, None]


@pytest.mark.asyncio
async def test_http_state_owns_earnings_bodies(aiohttp_client, monkeypatch):
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server
    from mining_dashboard.web.views import views, xvb_views

    build = adapter.REFERENCE_BODIES["build_earnings"]
    summary = adapter.REFERENCE_BODIES["build_earnings_vs_actual"]
    monkeypatch.setattr(views, "build_earnings", build)
    monkeypatch.setattr(views, "build_earnings_vs_actual", summary)
    monkeypatch.setattr(xvb_views, "build_earnings", build)
    monkeypatch.setattr(xvb_views, "build_earnings_vs_actual", summary)
    state = StateManager(db_path=":memory:")
    data = {
        "shares": [],
        "workers": [],
        "system": {},
        "global_sync": False,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 5, "target": 5},
    }
    try:
        client = await aiohttp_client(server.create_app(state, data))
        response = await client.get("/api/state")
        assert response.status == 200
        body = await response.json()
        assert set(body["earnings_summary"]) == {"xmr", "tari", "xvb"}
        assert "confirmed" in body["earnings"]
        assert not adapter.FALLBACKS
    finally:
        state.close()
