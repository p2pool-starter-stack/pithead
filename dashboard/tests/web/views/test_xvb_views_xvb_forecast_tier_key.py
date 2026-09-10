# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestXvbForecastTierKey:
    def test_held_tier_wins_over_target(self, _metrics):
        m = _metrics(xvb_1h=100_000.0, xvb_24h=100_000.0, target_threshold=10_000.0)
        assert xvb_views.xvb_forecast_tier_key(m, _WINS_TIERS) == "donor_whale"

    def test_falls_back_to_the_target_tier_while_none_is_held(self, _metrics):
        # A fleet still ramping (or weighing whether to enable donation at all) has zero credited
        # average — the forecast speaks to the TARGET tier instead of dashing out (#866).
        m = _metrics(xvb_1h=0.0, xvb_24h=0.0, target_threshold=1_000.0)
        assert xvb_views.xvb_forecast_tier_key(m, _WINS_TIERS) == "donor"

    def test_none_when_neither_held_nor_targeted(self, _metrics):
        m = _metrics(xvb_1h=0.0, xvb_24h=0.0, target_threshold=0.0)
        assert xvb_views.xvb_forecast_tier_key(m, _WINS_TIERS) is None
        # A target threshold matching no tier (drifted config) stays None, never a KeyError.
        m = _metrics(xvb_1h=0.0, xvb_24h=0.0, target_threshold=123.0)
        assert xvb_views.xvb_forecast_tier_key(m, _WINS_TIERS) is None
