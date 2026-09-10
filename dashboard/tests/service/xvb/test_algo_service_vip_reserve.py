# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestVipReserve:
    def test_difficulty_reserve_caps_donation(self, algo):
        """The reserve keeps p2pool enough hashrate to hold a PPLNS share (VIP)."""
        # window = 2160*10 = 21600s; min_p2pool = 120e6/21600 * 2 ~ 11_111 H/s.
        frac = algo._max_donation_fraction(46_300, 21600, POOL_STATS_DIFF)
        assert frac == pytest.approx(1 - 11_111 / 46_300, rel=0.02)

    def test_falls_back_to_flat_cap_without_difficulty(self, algo):
        assert algo._max_donation_fraction(46_300, 21600, POOL_STATS) == algo.max_donation_fraction

    def test_reserve_never_exceeds_hard_cap(self, algo):
        # Huge hashrate, tiny difficulty -> sparable ~1.0, clamped to the hard cap.
        frac = algo._max_donation_fraction(10_000_000, 21600, {"difficulty": 1_000})
        assert frac == algo.max_donation_fraction

    def test_loop_clamped_to_reserve(self, algo):
        """The integrator can never push the donated fraction past the reserve."""
        algo.donation_level = "mega"  # unsustainable target -> loop pushes up hard
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            for _ in range(50):
                algo.get_decision(
                    46_300,
                    46_300,
                    POOL_STATS_DIFF,
                    P2P_MAIN,
                    {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                    RECENT_SHARES,
                )
            cap = algo._max_donation_fraction(46_300, 21600, POOL_STATS_DIFF)
            assert algo.donation_fraction <= cap + 1e-9
