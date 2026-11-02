from mining_dashboard.helper import utils
from mining_dashboard.web.views import xvb_views


def settings():
    from mining_dashboard.web.views import xvb_calculator

    return {
        "stale_after_s": utils.XVB_STATS_STALE_AFTER_S,
        "max_fraction": xvb_calculator.XVB_MAX_DONATION_FRACTION,
        "prior": list(xvb_views.XVB_REALIZATION_PRIOR),
        "published_rewards": dict(xvb_views.XVB_PUBLISHED_REWARD_FALLBACK),
        "published_date": xvb_views.XVB_PUBLISHED_REWARD_FALLBACK_DATE,
        "tier_note": xvb_views._XVB_TIER_NOTE,
        "sidechain_note": xvb_views._XVB_SIDECHAIN_NOTE,
        "payout_window_s": xvb_views._XVB_WIN_PAYOUT_WINDOW_S,
        "settle_s": xvb_views._XVB_WIN_SETTLE_S,
        "min_wins": xvb_views._XVB_REALIZATION_MIN_WINS,
        "realization_window_s": xvb_views._XVB_REALIZATION_WINDOW_S,
    }


def tiers(values):
    return [
        {"name": name, "threshold": threshold, "display": utils.get_tier_info(threshold, values)[0]}
        for name, threshold in values.items()
    ]


def builders(prepared):
    fields = {
        "current_key",
        "forecast_key",
        "xvb_day",
        "expected_wins_day",
        "realization",
        "tempered_day",
        "xvb_calc",
    }
    if not isinstance(prepared, dict) or set(prepared) != fields:
        raise RuntimeError("native XvB forecast unavailable")
    operations = {
        "xvb_current_tier_key": "current_key",
        "xvb_forecast_tier_key": "forecast_key",
        "xvb_current_tier_reward_day": "xvb_day",
        "xvb_expected_wins_day": "expected_wins_day",
        "xvb_realization": "realization",
        "xvb_tempered_day": "tempered_day",
        "build_xvb_calc": "xvb_calc",
    }
    result = {}
    for name, field in operations.items():

        def value(*_args, field=field, **_kwargs):
            return prepared[field]

        result[name] = value
    return result
