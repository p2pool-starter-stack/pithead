# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestXvbRealization:
    NOW = _REALIZATION_NOW
    # 6 settled wins, hourly; face value 0.016 XMR/day at 1 expected win/day => 16 mXMR face/win.
    WINS = [{"ts": _REALIZATION_NOW - 86_400 - i * 3_600} for i in range(6)]

    def _payouts(self, per_win_atomic):
        # One payout landing 30 min after each win — squarely inside the attribution window.
        return [{"ts": w["ts"] + 1_800, "amount_atomic": per_win_atomic} for w in self.WINS]

    def test_measures_the_fraction_of_face_value_wins_actually_paid(self):
        # 3.2 mXMR realized per win against a 16 mXMR face => 0.2, with the sample size.
        out = xvb_realization(self._payouts(3_200_000_000), self.WINS, 0.016, 1.0, now=self.NOW)
        assert out == (pytest.approx(0.2), 6)

    def test_clamps_at_face_value_and_floors_at_zero(self):
        # A lucky window can overshoot face value — the factor is a discount, never a bonus.
        out = xvb_realization(self._payouts(32_000_000_000), self.WINS, 0.016, 1.0, now=self.NOW)
        assert out[0] == 1.0

    def test_too_few_wins_is_none_not_noise(self):
        out = xvb_realization(self._payouts(3_200_000_000), self.WINS[:4], 0.016, 1.0, now=self.NOW)
        assert out is None

    def test_unsettled_wins_are_left_out_of_the_sample(self):
        # A win still inside the settle window has payouts in flight — counting it would drag
        # the factor down for no reason. With it excluded the sample drops below the minimum.
        fresh = [{"ts": self.NOW - 600}] + self.WINS[:4]
        assert (
            xvb_realization(self._payouts(3_200_000_000), fresh, 0.016, 1.0, now=self.NOW) is None
        )

    def test_a_payout_in_two_overlapping_windows_counts_once(self):
        # Back-to-back wins share attribution windows; the payout sum iterates payouts, not
        # windows, so an overlapped payout cannot double-count.
        payout = {"ts": self.WINS[0]["ts"] + 900, "amount_atomic": 3_200_000_000}
        out = xvb_realization([payout], self.WINS, 0.016, 1.0, now=self.NOW)
        assert out == (pytest.approx(3.2e-3 / 6 / 0.016), 6)

    def test_missing_inputs_yield_none(self):
        assert xvb_realization(None, self.WINS, 0.016, 1.0, now=self.NOW) is None
        assert xvb_realization([], self.WINS, 0.016, 1.0, now=self.NOW) is None
        assert xvb_realization(self._payouts(1), None, 0.016, 1.0, now=self.NOW) is None
        assert xvb_realization(self._payouts(1), self.WINS, None, 1.0, now=self.NOW) is None
        assert xvb_realization(self._payouts(1), self.WINS, 0.016, None, now=self.NOW) is None
        assert xvb_realization(self._payouts(1), self.WINS, 0.016, 0.0, now=self.NOW) is None
        # A hostile/corrupt negative published figure gives a negative face value — no factor.
        assert xvb_realization(self._payouts(1), self.WINS, -0.016, 1.0, now=self.NOW) is None

    def test_baseline_subtraction_removes_ordinary_p2pool_leak(self):
        # Ordinary P2Pool payouts land inside win windows too; the box's linear rate over the
        # windowed hours is subtracted so the factor measures only the wins' excess. Here the
        # 4.8 mXMR gross per win contains 1.6 mXMR of baseline (6.4 mXMR/day × 6h): excess
        # 3.2 mXMR against a 16 mXMR face => 0.2, not the inflated 0.3.
        out = xvb_realization(
            self._payouts(4_800_000_000), self.WINS, 0.016, 1.0, now=self.NOW, p2pool_day=0.0064
        )
        assert out == (pytest.approx(0.2), 6)
