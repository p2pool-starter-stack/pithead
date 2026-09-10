# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestEarningsVsActualTempering:
    NOW = 1_760_000_000

    def _e(self):
        return _summary_earnings(
            coeff_day=1e-8,
            xvb_day=0.016,
            confirmed={"enabled": True, "xmr_30d": 0.28, "partial": {"30d": False}},
        )

    def test_measured_realization_tempers_the_xvb_leg(self, _metrics):
        # The published leg (0.016 × 30 = 0.48) scales to the measured fraction; the factor and
        # its sample ride along for the tooltip. The P2Pool leg is untouched.
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=8000.0), self._e(), [], now=self.NOW, realization=(0.19, 15)
        )
        assert s["xmr"]["expected_30d"] == pytest.approx(1e-8 * 8000.0 * 30 + 0.016 * 30 * 0.19)
        assert s["xmr"]["xvb_realization_pct"] == 19
        assert s["xmr"]["xvb_wins_measured"] == 15
        assert s["xmr"]["includes_xvb"] is True

    def test_without_a_measured_factor_the_published_figure_stands(self, _metrics):
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), self._e(), [], now=self.NOW)
        assert s["xmr"]["expected_30d"] == pytest.approx(1e-8 * 8000.0 * 30 + 0.016 * 30)
        assert s["xmr"]["xvb_realization_pct"] is None
        assert s["xmr"]["xvb_wins_measured"] is None

    def test_realization_without_an_xvb_leg_is_ignored(self, _metrics):
        # XvB off (or no fresh estimate): there is no leg to temper — the factor must not leak
        # into the payload as if one existed.
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=8000.0, xvb_enabled=False),
            self._e(),
            [],
            now=self.NOW,
            realization=(0.19, 15),
        )
        assert s["xmr"]["xvb_realization_pct"] is None

    def test_expected_wins_fill_the_xvb_row(self, _metrics):
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=8000.0), self._e(), [], now=self.NOW, expected_wins_day=0.84
        )
        assert s["xvb"]["expected_wins_30d"] == pytest.approx(25.2)
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), self._e(), [], now=self.NOW)
        assert s["xvb"]["expected_wins_30d"] is None
