# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestXvbTemperedDay:
    """The calculator/energy figure ships tempered — never XvB's raw published number (#902)."""

    def test_measured_realization_beats_the_prior(self):
        assert xvb_tempered_day(0.016, (0.19, 15)) == pytest.approx(0.016 * 0.19)

    def test_unmeasured_falls_back_to_the_prior_midpoint(self):
        lo, hi = xvb_views.XVB_REALIZATION_PRIOR
        assert xvb_tempered_day(0.016, None) == pytest.approx(0.016 * (lo + hi) / 2)

    def test_never_the_raw_published_figure(self):
        # Whichever branch resolves, face value must not survive the tempering.
        assert xvb_tempered_day(0.016, None) < 0.016
        assert xvb_tempered_day(0.016, (0.99, 5)) < 0.016

    def test_nothing_published_passes_through(self):
        # None (no fresh estimate / XvB off) and 0 stay as-is — nothing fabricated either way.
        assert xvb_tempered_day(None, None) is None
        assert xvb_tempered_day(None, (0.19, 15)) is None
        assert xvb_tempered_day(0.0, (0.19, 15)) == 0.0

    def test_build_state_ships_tempered_while_the_summary_keeps_face_value(
        self, _data, _state_mgr, monkeypatch
    ):
        # The wiring the issue is about: est.xvbDay (earnings.xvb_day) leaves build_state
        # tempered, while the expected-vs-actual summary still works from the face value (it
        # applies the measured factor itself — feeding it the tempered figure would double-count).
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(service_metrics, "ENABLE_XVB", True)
        monkeypatch.setattr(views, "xvb_current_tier_reward_day", lambda m, s: 0.016)
        monkeypatch.setattr(views, "xvb_realization", lambda *a, **k: (0.25, 6))
        st = views.build_state(_data(), _state_mgr(), "all")
        assert st["earnings"]["xvb_day"] == pytest.approx(0.016 * 0.25)
        # Measured tempering applied exactly ONCE on the summary side (0.016 × 30 × 0.25).
        assert st["earnings_summary"]["xmr"]["expected_30d"] == pytest.approx(0.016 * 30 * 0.25)

    def test_build_state_unmeasured_box_ships_the_prior_midpoint(
        self, _data, _state_mgr, monkeypatch
    ):
        # No measured wins: the calculator figure drops to the prior midpoint; the summary keeps
        # the face value (its tooltip labels it an upper bound) — asymmetric by design.
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(service_metrics, "ENABLE_XVB", True)
        monkeypatch.setattr(views, "xvb_current_tier_reward_day", lambda m, s: 0.016)
        monkeypatch.setattr(views, "xvb_realization", lambda *a, **k: None)
        st = views.build_state(_data(), _state_mgr(), "all")
        lo, hi = xvb_views.XVB_REALIZATION_PRIOR
        assert st["earnings"]["xvb_day"] == pytest.approx(0.016 * (lo + hi) / 2)
        assert st["earnings_summary"]["xmr"]["expected_30d"] == pytest.approx(0.016 * 30)
